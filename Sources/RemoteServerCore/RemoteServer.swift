import CoreBluetooth
import Foundation
import RemoteProtocol
import RemoteSecurity

public final class RemoteServer: NSObject, @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case stopped
        case advertising
        case poweredOff
        case unauthorized
        case unsupported
        case failed(String)
    }

    public var onStatus: ((Status) -> Void)?
    public var onEvent: ((KeyEvent) -> Void)?
    public var onDevices: (([PairedDevice]) -> Void)?

    public enum TrustResetResult: Sendable, Equatable {
        case succeeded
        case failed(String)
    }

    public var onTrustReset: ((TrustResetResult) -> Void)?
    private(set) var trustResetBlocked = false

    private final class Peer {
        let central: CBCentral
        let pendingID = UUID()
        let created = ProcessInfo.processInfo.systemUptime
        var lastActive = ProcessInfo.processInfo.systemUptime
        var handshake: SecureHandshake?
        var session: SecureSession?
        var publicKey: Data?
        var name: String?
        var trustedID: UUID?
        var approved = false
        var closing = false
        var pendingSince: TimeInterval?
        var controlAssembler = SecureFrameAssembler()
        var inputAssembler = SecureFrameAssembler()
        var controlStarted: TimeInterval?
        var controlUpdated: TimeInterval?
        var inputStarted: TimeInterval?
        var inputUpdated: TimeInterval?
        var notifications: [Data] = []
        var notificationBytes = 0
        var notificationProgress: TimeInterval?
        var frameCounter: UInt64 = 0
        var held = Set<Command>()
        var heldButtons = Set<MouseButton>()

        init(central: CBCentral) {
            self.central = central
        }
    }

    private let queue = DispatchQueue(label: "remote.server")
    private let log = RemoteLog(category: "server")
    private let serviceName: String
    private let injector = KeyInjector()
    private let pointer = PointerInjector()
    private let trust: PeerTrustStore
    private var deniedKeys = Set<Data>()
    private var deniedIDs = Set<UUID>()
    private var manager: CBPeripheralManager?
    private var control: CBMutableCharacteristic?
    private var peers: [UUID: Peer] = [:]
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var lastStatus: Status = .stopped
    private var statusBeforeTrustFailure: Status?

    public init(
        serviceName: String = RemoteService.defaultName,
        defaults: UserDefaults = .standard,
        keyStore: (any SecureKeyStore)? = nil
    ) {
        self.serviceName = serviceName
        self.trust = PeerTrustStore(store: keyStore ?? KeychainSecureKeyStore(
            service: "com.altay.lazyremote.server.security"
        ))
        super.init()
    }

    public func start() {
        queue.async { [self] in
            guard self.manager == nil else {
                self.log.info("start ignored: already running")
                return
            }
            self.log.info("start resetBlocked=\(self.trustResetBlocked)")
            self.isRunning = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.expirePeers() }
            self.timer = timer
            timer.resume()
            self.manager = CBPeripheralManager(delegate: self, queue: self.queue)
        }
    }

    public func stop() {
        queue.async {
            self.log.info("stop peers=\(self.peers.count)")
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
            self.clearPeers()
            self.manager?.stopAdvertising()
            self.manager?.removeAllServices()
            self.manager = nil
            self.control = nil
            self.report(.stopped)
            self.reportDevices()
        }
    }

    public func approve(_ id: UUID) {
        queue.async {
            guard !self.trustResetBlocked,
                  let peer = self.peers.values.first(where: { $0.pendingID == id }),
                  !peer.closing, !peer.approved, peer.session != nil,
                  let publicKey = peer.publicKey, let name = peer.name
            else {
                self.log.error("approve ignored pending=\(RemoteLog.id(id)) resetBlocked=\(self.trustResetBlocked) found=\(self.peers.values.contains { $0.pendingID == id })")
                return
            }
            guard let pendingSince = peer.pendingSince,
                ProcessInfo.processInfo.systemUptime - pendingSince < 300
            else {
                self.fail(peer, message: "Device approval expired. Reconnect the device.")
                return
            }
            do {
                let trusted = try self.trust.approve(
                    publicKey: publicKey, name: name, transportID: peer.central.identifier
                )
                self.deniedKeys.remove(publicKey)
                self.deniedIDs.remove(trusted.id)
                peer.trustedID = trusted.id
                peer.approved = true
                peer.pendingSince = nil
                try self.send(.approved, to: peer)
                self.log.info("approved phone=\(RemoteLog.id(peer.central.identifier)) trusted=\(RemoteLog.id(trusted.id))")
                self.reportDevices()
            } catch {
                self.log.error("approve failed phone=\(RemoteLog.id(peer.central.identifier)): \(RemoteLog.describe(error))")
                self.fail(peer, message: "Could not securely approve the device. Reconnect and try again.")
            }
        }
    }

    public func forget(_ id: UUID) {
        queue.async {
            self.deniedIDs.insert(id)
            var affected = self.peers.values.filter { $0.trustedID == id || $0.pendingID == id }
            var deletionFailed = false
            do {
                if let trusted = try self.trust.peers().first(where: { $0.id == id }) {
                    self.deniedKeys.insert(trusted.publicKey)
                    affected = self.peers.values.filter {
                        $0.publicKey == trusted.publicKey || $0.pendingID == id
                    }
                }
                try self.trust.forget(id)
            } catch {
                self.log.error("forget \(RemoteLog.id(id)) failed: \(RemoteLog.describe(error))")
                deletionFailed = true
            }
            self.log.info("forget \(RemoteLog.id(id)) affectedPeers=\(affected.count) persisted=\(!deletionFailed)")
            for peer in affected {
                if let publicKey = peer.publicKey { self.deniedKeys.insert(publicKey) }
                peer.approved = false
                peer.closing = true
                peer.controlAssembler.reset()
                peer.inputAssembler.reset()
                self.releaseHeld(peer)
                do {
                    if peer.session != nil {
                        try self.send(.revoked, to: peer)
                    } else {
                        self.drop(peer)
                    }
                } catch {
                    self.drop(peer)
                }
            }
            if deletionFailed {
                self.report(.failed("Could not remove saved trust. The device is blocked for this run; retry Forget."))
            }
            self.reportDevices()
        }
    }

    public func forgetAll() {
        queue.async {
            self.trustResetBlocked = true
            let affected = Array(self.peers.values)
            self.log.info("forgetAll revoking peers=\(affected.count)")
            for peer in affected { peer.closing = true }
            for peer in affected {
                peer.approved = false
                peer.pendingSince = nil
                peer.handshake = nil
                peer.controlAssembler.reset()
                peer.inputAssembler.reset()
                peer.controlStarted = nil
                peer.controlUpdated = nil
                peer.inputStarted = nil
                peer.inputUpdated = nil
                self.releaseHeld(peer)
                do {
                    if peer.session != nil {
                        try self.send(.revoked, to: peer)
                    } else {
                        self.drop(peer)
                    }
                } catch {
                    self.drop(peer)
                }
            }
            let result: TrustResetResult
            do {
                try self.trust.forgetAll()
                self.deniedKeys.removeAll()
                self.deniedIDs.removeAll()
                self.trustResetBlocked = false
                if let status = self.statusBeforeTrustFailure {
                    self.report(status)
                }
                self.log.info("forgetAll succeeded")
                result = .succeeded
            } catch {
                self.log.error("forgetAll failed; approvals blocked: \(RemoteLog.describe(error))")
                result = .failed("Could not reset saved trust. Access is blocked for this run. Retry Forget All Devices; saved approvals may return after restarting the app.")
            }
            self.reportDevices()
            DispatchQueue.main.async { self.onTrustReset?(result) }
        }
    }

    private func publish() {
        guard let manager, isRunning else { return }
        log.info("publishing service")
        let input = CBMutableCharacteristic(
            type: RemoteService.secureInputUUID,
            properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable]
        )
        let control = CBMutableCharacteristic(
            type: RemoteService.secureControlUUID,
            properties: [.write, .notify], value: nil, permissions: [.writeable]
        )
        let service = CBMutableService(type: RemoteService.uuid, primary: true)
        service.characteristics = [control, input]
        self.control = control
        manager.removeAllServices()
        manager.add(service)
        reportDevices()
    }

    private func enqueue(_ data: Data, kind: SecureFrameKind, to peer: Peer) throws {
        guard peer.frameCounter < UInt64.max else { throw SecureError.sequenceExhausted }
        let frames = try SecureFrame.fragment(
            data, kind: kind, id: peer.frameCounter, mtu: peer.central.maximumUpdateValueLength
        )
        let bytes = frames.reduce(0) { $0 + $1.count }
        guard peer.notificationBytes + bytes <= 8192 * 2,
              peer.notifications.count + frames.count <= 2048
        else { throw SecureError.oversizedMessage }
        peer.frameCounter += 1
        if peer.notifications.isEmpty {
            peer.notificationProgress = ProcessInfo.processInfo.systemUptime
        }
        peer.notifications.append(contentsOf: frames)
        peer.notificationBytes += bytes
        drain(peer)
    }

    private func send(_ message: SecureMessage, to peer: Peer) throws {
        guard var session = peer.session else { throw SecureError.wrongPhase }
        let record = try session.seal(message.encoded(), lane: .serverControl)
        peer.session = session
        try enqueue(record, kind: .encryptedControl, to: peer)
    }

    private func drain(_ peer: Peer) {
        guard let manager, let control else { return }
        while let frame = peer.notifications.first {
            guard manager.updateValue(frame, for: control, onSubscribedCentrals: [peer.central]) else {
                return
            }
            peer.notificationBytes -= frame.count
            peer.notifications.removeFirst()
            peer.notificationProgress = ProcessInfo.processInfo.systemUptime
        }
        peer.notificationProgress = nil
        if peer.closing { drop(peer) }
    }

    private func receive(_ value: Data, input: Bool, from peer: Peer) throws {
        guard !trustResetBlocked, !peer.closing, !input || peer.approved else { throw SecureError.wrongPhase }
        let now = ProcessInfo.processInfo.systemUptime
        peer.lastActive = now
        let complete: (kind: SecureFrameKind, id: UInt64, data: Data)?
        if input {
            complete = try peer.inputAssembler.accept(value, now: now)
            peer.inputStarted = complete == nil ? (peer.inputStarted ?? now) : nil
            peer.inputUpdated = complete == nil ? now : nil
        } else {
            complete = try peer.controlAssembler.accept(value, now: now)
            peer.controlStarted = complete == nil ? (peer.controlStarted ?? now) : nil
            peer.controlUpdated = complete == nil ? now : nil
        }
        guard let complete else { return }
        if input {
            guard complete.kind == .encryptedInput, var session = peer.session else {
                throw SecureError.wrongPhase
            }
            let message = try SecureInputDecoder.decode(complete.data, session: &session, approved: peer.approved)
            peer.session = session
            switch message {
            case .key(let event):
                accept(event, from: peer)
            case .pointer(.swipe(let direction)):
                injector.switchSpace(direction)
            case .pointer(.button(let button, let isDown)):
                accept(button, isDown: isDown, from: peer)
            case .pointer(let event):
                pointer.post(event, holding: heldButton)
            case .text(let id, let value):
                injector.type(value)
                try send(.textResult(id: id, success: true), to: peer)
            default:
                throw SecureError.wrongPhase
            }
            return
        }
        switch complete.kind {
        case .clientHello:
            guard peer.handshake == nil, peer.session == nil, peer.publicKey == nil else {
                throw SecureError.wrongPhase
            }
            let pinned = try trust.peer(for: peer.central.identifier)
            log.info("clientHello phone=\(RemoteLog.id(peer.central.identifier)) pinnedPhone=\(pinned != nil)")
            let handshake = SecureHandshake(
                identity: try trust.identity(), role: .server, pinnedPeer: pinned?.publicKey
            )
            let reply = try handshake.receiveClientHello(complete.data)
            peer.handshake = handshake
            peer.publicKey = handshake.peerPublicKey
            try enqueue(reply, kind: .serverHello, to: peer)
        case .clientFinish:
            guard let handshake = peer.handshake, peer.session == nil else {
                throw SecureError.wrongPhase
            }
            let reply = try handshake.receiveClientFinish(complete.data)
            log.info("clientFinish verified phone=\(RemoteLog.id(peer.central.identifier))")
            peer.session = try handshake.takeSession()
            peer.handshake = nil
            try enqueue(reply, kind: .encryptedControl, to: peer)
        case .encryptedControl:
            guard var session = peer.session, peer.name == nil, let publicKey = peer.publicKey else {
                throw SecureError.wrongPhase
            }
            let message = try SecureMessage(wire: session.open(complete.data, lane: .clientControl))
            guard case .name(let name) = message else { throw SecureError.wrongPhase }
            peer.session = session
            peer.name = name
            let known = try trust.peer(publicKey: publicKey)
            let phone = RemoteLog.id(peer.central.identifier)
            if let trusted = known,
               !deniedKeys.contains(publicKey), !deniedIDs.contains(trusted.id) {
                let updated = try trust.approve(
                    publicKey: publicKey, name: name, transportID: peer.central.identifier
                )
                peer.trustedID = updated.id
                peer.approved = true
                log.info("name received phone=\(phone) name=\(name); auto-approved trusted=\(RemoteLog.id(updated.id))")
                try send(.approved, to: peer)
            } else {
                log.info("name received phone=\(phone) name=\(name); pending approval known=\(known != nil) denied=\(deniedKeys.contains(publicKey))")
                peer.pendingSince = now
                try send(.pending, to: peer)
            }
            reportDevices()
        default:
            throw SecureError.wrongPhase
        }
    }

    private func accept(_ event: KeyEvent, from peer: Peer) {
        if event.isDown {
            peer.held.insert(event.command)
            injector.post(event)
        } else {
            guard peer.held.remove(event.command) != nil else { return }
            if !peers.values.contains(where: { $0.approved && $0.held.contains(event.command) }) {
                injector.post(event)
            }
        }
        DispatchQueue.main.async { self.onEvent?(event) }
    }

    private func accept(_ button: MouseButton, isDown: Bool, from peer: Peer) {
        if isDown {
            peer.heldButtons.insert(button)
            pointer.post(.button(button, isDown: true))
        } else {
            guard peer.heldButtons.remove(button) != nil else { return }
            if !peers.values.contains(where: { $0.approved && $0.heldButtons.contains(button) }) {
                pointer.post(.button(button, isDown: false))
            }
        }
    }

    private var heldButton: MouseButton? {
        let held = peers.values.filter(\.approved).reduce(into: Set<MouseButton>()) {
            $0.formUnion($1.heldButtons)
        }
        return held.contains(.left) ? .left : held.first
    }

    private func releaseHeld(_ peer: Peer) {
        let held = peer.held
        peer.held.removeAll()
        for command in held {
            if !peers.values.contains(where: { $0 !== peer && $0.approved && $0.held.contains(command) }) {
                injector.post(KeyEvent(command: command, isDown: false))
            }
        }
        let buttons = peer.heldButtons
        peer.heldButtons.removeAll()
        for button in buttons {
            if !peers.values.contains(where: { $0 !== peer && $0.approved && $0.heldButtons.contains(button) }) {
                pointer.post(.button(button, isDown: false))
            }
        }
    }

    private func drop(_ peer: Peer) {
        log.info("drop phone=\(RemoteLog.id(peer.central.identifier)) approved=\(peer.approved) closing=\(peer.closing) queuedNotifications=\(peer.notifications.count)")
        releaseHeld(peer)
        peers.removeValue(forKey: peer.central.identifier)
        peer.session = nil
        peer.handshake = nil
        peer.controlAssembler.reset()
        peer.inputAssembler.reset()
        peer.notifications.removeAll()
        peer.notificationBytes = 0
    }

    private func clearPeers() {
        for peer in Array(peers.values) { drop(peer) }
    }

    private func fail(_ peer: Peer, message: String = "Secure connection failed. Reconnect the device and try again.") {
        log.error("fail phone=\(RemoteLog.id(peer.central.identifier)) handshake=\(peer.handshake != nil) session=\(peer.session != nil) named=\(peer.name != nil): \(message)")
        drop(peer)
        report(.failed(message))
        reportDevices()
    }

    private func expirePeers() {
        let now = ProcessInfo.processInfo.systemUptime
        for peer in Array(peers.values) {
            let controlExpired = peer.controlUpdated.map { now - $0 >= 10 } == true
                || peer.controlStarted.map { now - $0 >= 30 } == true
            let inputExpired = peer.inputUpdated.map { now - $0 >= 10 } == true
                || peer.inputStarted.map { now - $0 >= 30 } == true
            let handshakeExpired = peer.name == nil && (now - peer.lastActive >= 10 || now - peer.created >= 30)
            let pendingExpired = peer.pendingSince.map { now - $0 >= 300 } == true
            let notificationExpired = peer.notificationProgress.map { now - $0 >= 10 } == true
            if controlExpired || inputExpired || handshakeExpired || pendingExpired || notificationExpired {
                log.error("expire phone=\(RemoteLog.id(peer.central.identifier)) control=\(controlExpired) input=\(inputExpired) handshake=\(handshakeExpired) pending=\(pendingExpired) notification=\(notificationExpired)")
                fail(peer, message: "Secure connection timed out. Reconnect the device.")
            }
        }
    }

    private func report(_ status: Status) {
        log.info("status \(status)")
        lastStatus = status
        statusBeforeTrustFailure = nil
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    private func reportDevices() {
        var devices: [PairedDevice] = []
        do {
            devices = try (trustResetBlocked ? [] : trust.peers()).map { trusted in
                PairedDevice(
                    id: trusted.id, name: trusted.name, isApproved: true,
                    isConnected: peers.values.contains { $0.trustedID == trusted.id && $0.approved && $0.session != nil }
                )
            }
        } catch {
            log.error("reading saved trust failed: \(RemoteLog.describe(error))")
            let recoveryStatus = statusBeforeTrustFailure ?? lastStatus
            report(.failed("Could not read saved device trust. New connections require secure approval."))
            statusBeforeTrustFailure = recoveryStatus
        }
        devices += peers.values.compactMap { peer in
            guard !peer.approved, !peer.closing, peer.session != nil, let name = peer.name else { return nil }
            return PairedDevice(id: peer.pendingID, name: name, isApproved: false, isConnected: false)
        }
        devices.sort { ($0.isApproved ? 1 : 0, $0.name) < ($1.isApproved ? 1 : 0, $1.name) }
        let snapshot = devices
        DispatchQueue.main.async { self.onDevices?(snapshot) }
    }
}

extension RemoteServer: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard manager === peripheral, isRunning else { return }
        log.info("peripheral state=\(RemoteLog.describe(peripheral.state)) peers=\(peers.count)")
        if peripheral.state != .poweredOn {
            clearPeers()
            control = nil
            reportDevices()
        }
        switch peripheral.state {
        case .poweredOn: publish()
        case .poweredOff: report(.poweredOff)
        case .unauthorized: report(.unauthorized)
        case .unsupported: report(.unsupported)
        default: break
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard manager === peripheral, isRunning else { return }
        guard error == nil else {
            log.error("add service failed: \(RemoteLog.describe(error))")
            clearPeers()
            report(.failed("Could not publish the secure Bluetooth service."))
            reportDevices()
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [RemoteService.uuid],
            CBAdvertisementDataLocalNameKey: serviceName,
        ])
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard manager === peripheral, isRunning else { return }
        if error != nil {
            log.error("advertising failed: \(RemoteLog.describe(error))")
            clearPeers()
            report(.failed("Could not advertise the secure Bluetooth service."))
            reportDevices()
        } else {
            report(.advertising)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard manager === peripheral, isRunning, characteristic === control else { return }
        let phone = RemoteLog.id(central.identifier)
        guard peers[central.identifier] == nil else {
            log.error("subscribe ignored phone=\(phone): previous connection still open closing=\(peers[central.identifier]?.closing == true)")
            return
        }
        guard peers.count < 8 else {
            log.error("subscribe refused phone=\(phone): too many connections")
            report(.failed("Too many Bluetooth connections. Disconnect a device and try again."))
            return
        }
        log.info("subscribed phone=\(phone) mtu=\(central.maximumUpdateValueLength) peers=\(peers.count + 1)")
        peers[central.identifier] = Peer(central: central)
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard manager === peripheral, characteristic === control else { return }
        log.info("unsubscribed phone=\(RemoteLog.id(central.identifier)) known=\(peers[central.identifier] != nil)")
        if let peer = peers[central.identifier] { drop(peer) }
        reportDevices()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        peripheral.respond(to: request, withResult: .requestNotSupported)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        var result = CBATTError.Code.success
        for request in requests {
            guard manager === peripheral, isRunning,
                  request.characteristic.uuid == RemoteService.secureControlUUID
                    || request.characteristic.uuid == RemoteService.secureInputUUID
            else {
                log.error("write rejected phone=\(RemoteLog.id(request.central.identifier)): unsupported characteristic or not running=\(isRunning)")
                result = .requestNotSupported
                if let peer = peers[request.central.identifier] { fail(peer) }
                break
            }
            guard let peer = peers[request.central.identifier], !peer.closing else {
                log.error("write rejected phone=\(RemoteLog.id(request.central.identifier)): \(peers[request.central.identifier] == nil ? "not subscribed" : "connection closing")")
                result = .insufficientAuthorization
                break
            }
            do {
                guard request.offset == 0, let value = request.value else { throw SecureError.malformedMessage }
                try receive(value, input: request.characteristic.uuid == RemoteService.secureInputUUID, from: peer)
            } catch {
                log.error("receive failed phone=\(RemoteLog.id(peer.central.identifier)) input=\(request.characteristic.uuid == RemoteService.secureInputUUID) resetBlocked=\(trustResetBlocked): \(RemoteLog.describe(error))")
                result = .insufficientAuthorization
                fail(peer)
                break
            }
        }
        peripheral.respond(to: first, withResult: result)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard manager === peripheral, isRunning else { return }
        for peer in Array(peers.values) { drain(peer) }
        reportDevices()
    }
}
