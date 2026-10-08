import CoreBluetooth
import Foundation
import RemoteProtocol
import RemoteSecurity

#if canImport(UIKit)
import UIKit
#endif

public final class RemoteClient: NSObject, @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case stopped
        case poweredOff
        case unauthorized
        case unsupported
        case scanning
        case connecting(String)
        case securing(String)
        case awaitingApproval(String)
        case connected(String)
        case failed(String)
    }

    /// Called on the main queue.
    public var onStatus: ((Status) -> Void)?
    /// Called on the main queue after the encrypted injection result, or failure.
    public var onTextDelivered: ((Bool) -> Void)?

    private enum Stage {
        case idle, connecting, services, characteristics, subscribing
        case serverHello, serverFinish, approval, ready, failed
    }

    private enum Payload {
        case handshake(Data, SecureFrameKind)
        case message(SecureMessage)
    }

    private struct Job {
        let token: UUID
        let payload: Payload
        let control: Bool
        let type: CBCharacteristicWriteType
        let frameCount: Int
        let byteCount: Int
    }

    private struct WriteRecord {
        let id: UInt64
        let frames: [Data]
        let characteristic: CBCharacteristic
        let type: CBCharacteristicWriteType
        var index = 0
    }

    private let queue = DispatchQueue(label: "remote.client")
    private let log = RemoteLog(category: "client")
    private let deviceName: String
    private let defaults: UserDefaults
    private let trust: PeerTrustStore
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var secureInput: CBCharacteristic?
    private var secureControl: CBCharacteristic?
    private var stage: Stage = .idle
    private var isRunning = false
    private var forgetBlocked = false
    private var skipSavedPeripheral = false
    private var handshake: SecureHandshake?
    private var session: SecureSession?
    private var peerPublicKey: Data?
    private var assembler = SecureFrameAssembler()
    private var generation = UUID()
    private var stageTimer = UUID()
    private var receiveTimer = UUID()
    private var receiveStarted: TimeInterval?
    private var nextID: UInt64 = 1
    private var lastReceivedID: UInt64?
    private var jobs: [Job] = []
    private var record: WriteRecord?
    private var writeOutstanding = false
    private var queuedFrames = 0
    private var queuedBytes = 0
    private var pendingX = 0.0
    private var pendingY = 0.0
    private var pendingScrollX = 0.0
    private var pendingScrollY = 0.0
    private var scrollPhase = ScrollPhase.changed
    private var textDelivery = TextDeliveryTracker()
    private var pendingTextID: UInt64? { textDelivery.pendingID }
    private var textTimer = UUID()

    private static let lastPeripheralKey = "lastPeripheral"
    private static let maximumFrames = 2048
    private static let maximumBytes = 64 * 1024
    private static let updateRequired = "Update LazyRemote on both devices to use a secure connection."

    #if canImport(UIKit)
    @MainActor
    #endif
    public convenience init(
        deviceName: String = RemoteClient.localDeviceName,
        defaults: UserDefaults = .standard
    ) {
        self.init(deviceName: deviceName, defaults: defaults, keyStore: nil)
    }

    #if canImport(UIKit)
    @MainActor
    #endif
    public init(
        deviceName: String = RemoteClient.localDeviceName,
        defaults: UserDefaults = .standard,
        keyStore: (any SecureKeyStore)?
    ) {
        self.deviceName = deviceName
        self.defaults = defaults
        trust = PeerTrustStore(store: keyStore ?? KeychainSecureKeyStore(
            service: "com.altay.lazyremote.client.security"
        ))
        super.init()
    }

    public func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard !forgetBlocked else {
            log.error("start refused: previous Forget Mac failed")
            report(.failed("Could not forget this Mac securely. Retry Forget Mac before reconnecting."))
            return
        }
        guard manager == nil else {
            log.info("start ignored: already running")
            return
        }
        log.info("start")
        isRunning = true
        stage = .idle
        manager = CBCentralManager(delegate: self, queue: queue)
    }

    public func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func stopOnQueue() {
        log.info("stop stage=\(stage)")
        isRunning = false
        if manager?.state == .poweredOn { manager?.stopScan() }
        let previous = peripheral
        peripheral = nil
        resetConnection()
        if let previous { manager?.cancelPeripheralConnection(previous) }
        manager = nil
        report(.stopped)
    }

    /// Asynchronously stops, forgets only the selected Mac's trust and transport,
    /// and restarts if running. The private identity is retained. Deletion failure
    /// leaves the client stopped and reports `.failed`; retry this method to recover.
    public func forgetMac() {
        queue.async {
            let restart = self.isRunning
            let selected = self.peripheral?.identifier
                ?? self.defaults.string(forKey: Self.lastPeripheralKey).flatMap(UUID.init(uuidString:))
            self.stopOnQueue()
            do {
                if let selected, let peer = try self.trust.peer(for: selected) {
                    try self.trust.forget(peer.id)
                }
                self.defaults.removeObject(forKey: Self.lastPeripheralKey)
                self.forgetBlocked = false
                self.log.info("forgetMac succeeded mac=\(selected.map(RemoteLog.id) ?? "none") restart=\(restart)")
                if restart { self.startOnQueue() }
            } catch {
                self.log.error("forgetMac failed: \(RemoteLog.describe(error))")
                self.forgetBlocked = true
                self.stage = .failed
                self.report(.failed("Could not forget this Mac securely. Retry Forget Mac before reconnecting."))
            }
        }
    }

    public func send(_ event: KeyEvent) {
        queue.async { self.enqueueInput(.key(event)) }
    }

    public func tap(_ command: Command) {
        send(KeyEvent(command: command, isDown: true))
        send(KeyEvent(command: command, isDown: false))
    }

    public func move(dx: Double, dy: Double) {
        queue.async {
            guard self.stage == .ready, dx.isFinite, dy.isFinite else { return }
            self.pendingX = max(-32768, min(32767, self.pendingX + dx))
            self.pendingY = max(-32768, min(32767, self.pendingY + dy))
            self.pump()
        }
    }

    public func click(_ button: MouseButton, count: UInt8) {
        queue.async { self.enqueueInput(.pointer(.click(button: button, count: count))) }
    }

    /// `changed` and `momentum` deltas are coalesced and sent like cursor moves. The
    /// other phases are sent reliably, since a lost one leaves an app stuck mid-scroll.
    public func scroll(dx: Double, dy: Double, phase: ScrollPhase) {
        queue.async {
            guard self.stage == .ready, dx.isFinite, dy.isFinite else { return }
            switch phase {
            case .changed, .momentum:
                self.scrollPhase = phase
                self.pendingScrollX = max(-32768, min(32767, self.pendingScrollX + dx))
                self.pendingScrollY = max(-32768, min(32767, self.pendingScrollY + dy))
                self.pump()
            case .began, .ended, .momentumBegan, .momentumEnded:
                let x = max(-32768, min(32767, dx)).rounded(.towardZero)
                let y = max(-32768, min(32767, dy)).rounded(.towardZero)
                // Flushes the deltas still pending under the previous phase first.
                self.enqueueInput(.pointer(.scroll(dx: Int16(x), dy: Int16(y), phase: phase)))
                self.pendingScrollX = 0
                self.pendingScrollY = 0
            }
        }
    }

    public func send(text: String) {
        queue.async {
            guard self.stage == .ready, !text.isEmpty, text.utf8.count <= 4096,
                  self.pendingTextID == nil else {
                self.reportText(delivered: false)
                return
            }
            do {
                let id = try self.allocateID()
                try self.textDelivery.begin(id)
                let token = UUID()
                self.textTimer = token
                let generation = self.generation
                self.queue.asyncAfter(deadline: .now() + 30) {
                    guard self.generation == generation, self.textTimer == token,
                          self.pendingTextID == id else { return }
                    self.fail("Text delivery timed out. Reconnect to the Mac before trying again.")
                }
                self.enqueueInput(.text(id: id, value: text))
            } catch { self.failSecurity(error) }
        }
    }

    private func enqueueInput(_ message: SecureMessage) {
        guard stage == .ready else { return }
        do {
            try captureMove()
            try captureScroll()
            try enqueue(.message(message), control: false, type: .withResponse)
            pump()
        } catch { failSecurity(error) }
    }

    private func captureMove() throws {
        let dx = pendingX.rounded(.towardZero)
        let dy = pendingY.rounded(.towardZero)
        guard dx != 0 || dy != 0 else { return }
        try enqueue(.message(.pointer(.move(dx: Int16(dx), dy: Int16(dy)))),
                    control: false, type: .withoutResponse)
        pendingX -= dx
        pendingY -= dy
    }

    private func captureScroll() throws {
        let dx = pendingScrollX.rounded(.towardZero)
        let dy = pendingScrollY.rounded(.towardZero)
        guard dx != 0 || dy != 0 else { return }
        try enqueue(.message(.pointer(.scroll(dx: Int16(dx), dy: Int16(dy), phase: scrollPhase))),
                    control: false, type: .withoutResponse)
        pendingScrollX -= dx
        pendingScrollY -= dy
    }

    private func allocateID() throws -> UInt64 {
        guard nextID < UInt64.max else { throw SecureError.sequenceExhausted }
        let id = nextID
        nextID += 1
        return id
    }

    private func enqueue(_ payload: Payload, control: Bool, type: CBCharacteristicWriteType) throws {
        guard let peripheral else { throw SecureError.wrongPhase }
        let size: Int
        switch payload {
        case .handshake(let data, _): size = data.count
        case .message(let message): size = try message.encoded().count + 28
        }
        let mtu = peripheral.maximumWriteValueLength(for: type)
        guard mtu >= 20 else { throw SecureWireError.malformed }
        let frames = (size + mtu - 17) / (mtu - 16)
        let bytes = size + frames * 16
        guard queuedFrames + frames <= Self.maximumFrames,
              queuedBytes + bytes <= Self.maximumBytes else { throw SecureWireError.oversized }
                let token = UUID()
                jobs.append(Job(token: token, payload: payload, control: control, type: type,
                    frameCount: frames, byteCount: bytes))
        queuedFrames += frames
        queuedBytes += bytes
                let generation = self.generation
                queue.asyncAfter(deadline: .now() + 30) {
            guard self.generation == generation,
                self.jobs.contains(where: { $0.token == token }) else { return }
            self.fail("Secure write queue timed out. Reconnect to the Mac.")
                }
    }

    private func pump() {
        guard let peripheral, peripheral.state == .connected, stage != .failed,
              !writeOutstanding else { return }
        do {
            if record == nil {
                if jobs.isEmpty, stage == .ready, peripheral.canSendWriteWithoutResponse {
                    try captureMove()
                    try captureScroll()
                }
                guard let job = jobs.first else { return }
                if job.type == .withoutResponse, !peripheral.canSendWriteWithoutResponse { return }
                guard let characteristic = job.control ? secureControl : secureInput else {
                    throw SecureError.wrongPhase
                }
                let data: Data
                let kind: SecureFrameKind
                switch job.payload {
                case .handshake(let value, let frameKind):
                    data = value
                    kind = frameKind
                case .message(let message):
                    guard var session else { throw SecureError.wrongPhase }
                    data = try session.seal(message.encoded(), lane: job.control ? .clientControl : .clientInput)
                    self.session = session
                    kind = job.control ? .encryptedControl : .encryptedInput
                }
                let id = try allocateID()
                let frames = try SecureFrame.fragment(data, kind: kind, id: id,
                    mtu: peripheral.maximumWriteValueLength(for: job.type))
                let bytes = frames.reduce(0) { $0 + $1.count }
                let frameBudget = queuedFrames - job.frameCount + frames.count
                let byteBudget = queuedBytes - job.byteCount + bytes
                guard frameBudget <= Self.maximumFrames, byteBudget <= Self.maximumBytes else {
                    throw SecureWireError.oversized
                }
                queuedFrames = frameBudget
                queuedBytes = byteBudget
                jobs.removeFirst()
                record = WriteRecord(id: id, frames: frames, characteristic: characteristic, type: job.type)
                let generation = self.generation
                queue.asyncAfter(deadline: .now() + 30) {
                    guard self.generation == generation, self.record?.id == id else { return }
                    self.fail("Secure transfer timed out. Reconnect to the Mac.")
                }
            }
            while var current = record {
                if current.type == .withoutResponse, !peripheral.canSendWriteWithoutResponse { return }
                if current.type == .withResponse {
                    writeOutstanding = true
                    peripheral.writeValue(current.frames[current.index], for: current.characteristic, type: .withResponse)
                    return
                }
                peripheral.writeValue(current.frames[current.index], for: current.characteristic, type: .withoutResponse)
                queuedFrames -= 1
                queuedBytes -= current.frames[current.index].count
                current.index += 1
                record = current.index == current.frames.count ? nil : current
            }
            if !jobs.isEmpty || (stage == .ready && hasPendingDeltas) { pump() }
        } catch { failSecurity(error) }
    }

    private func resetConnection() {
        generation = UUID()
        stageTimer = UUID()
        receiveTimer = UUID()
        receiveStarted = nil
        stage = .idle
        secureInput = nil
        secureControl = nil
        handshake = nil
        session = nil
        peerPublicKey = nil
        assembler.reset()
        lastReceivedID = nil
        nextID = 1
        jobs.removeAll()
        record = nil
        writeOutstanding = false
        queuedFrames = 0
        queuedBytes = 0
        pendingX = 0
        pendingY = 0
        pendingScrollX = 0
        pendingScrollY = 0
        scrollPhase = .changed
        finishText(false)
    }

    private var hasPendingDeltas: Bool {
        [pendingX, pendingY, pendingScrollX, pendingScrollY].contains { abs($0) >= 1 }
    }

    private func finishText(_ delivered: Bool) {
        guard textDelivery.cancel() else { return }
        textTimer = UUID()
        reportText(delivered: delivered)
    }

    private func reportText(delivered: Bool) {
        DispatchQueue.main.async { self.onTextDelivered?(delivered) }
    }

    private func armStageTimeout(_ seconds: TimeInterval = 10) {
        let token = UUID()
        stageTimer = token
        let generation = self.generation
        queue.asyncAfter(deadline: .now() + seconds) {
            guard self.generation == generation, self.stageTimer == token,
                  self.stage != .ready, self.stage != .idle, self.stage != .failed else { return }
            self.log.error("stage timeout after \(Int(seconds))s in stage=\(self.stage)")
            self.fail("Secure connection timed out. Reconnect and check approval on the Mac.")
        }
    }

    private func failSecurity(_ error: Error) {
        log.error("security failure in stage=\(stage): \(RemoteLog.describe(error))")
        if error as? SecureError == .identityChanged {
            fail("This Mac's identity changed. Verify the Mac, then use Forget Mac to pair again.")
        } else {
            fail("Secure connection failed. Update both apps and reconnect; verify the Mac before using Forget Mac.")
        }
    }

    private func fail(_ message: String) {
        guard stage != .failed else { return }
        log.error("fail in stage=\(stage) mac=\(peripheral.map { RemoteLog.id($0.identifier) } ?? "none"): \(message)")
        resetConnection()
        stage = .failed
        if manager?.state == .poweredOn { manager?.stopScan() }
        report(.failed(message))
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
    }

    private func scan() {
        guard isRunning, stage == .idle, let manager, manager.state == .poweredOn else { return }
        let saved = defaults.string(forKey: Self.lastPeripheralKey).flatMap(UUID.init(uuidString:))
        if !skipSavedPeripheral, let saved,
           let known = manager.retrievePeripherals(withIdentifiers: [saved]).first {
            log.info("using saved mac=\(RemoteLog.id(saved))")
            connect(to: known)
            return
        }
        log.info("scanning saved=\(saved.map(RemoteLog.id) ?? "none") skipSaved=\(skipSavedPeripheral)")
        skipSavedPeripheral = false
        report(.scanning)
        manager.scanForPeripherals(withServices: [RemoteService.uuid])
    }

    private func connect(to peripheral: CBPeripheral) {
        resetConnection()
        self.peripheral = peripheral
        peripheral.delegate = self
        stage = .connecting
        log.info("connect mac=\(RemoteLog.id(peripheral.identifier)) name=\(Self.describe(peripheral)) state=\(peripheral.state.rawValue)")
        report(.connecting(Self.describe(peripheral)))
        manager?.connect(peripheral)
        let generation = self.generation
        let id = peripheral.identifier
        queue.asyncAfter(deadline: .now() + 5) {
            guard self.generation == generation, self.stage == .connecting,
                  let peripheral = self.peripheral, peripheral.identifier == id else { return }
            // Core Bluetooth never times out a pending connect; a Mac whose address rotated is only found by scanning.
            self.log.error("connect timed out after 5s mac=\(RemoteLog.id(id)); falling back to scan")
            self.manager?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            self.resetConnection()
            self.skipSavedPeripheral = true
            self.scan()
        }
    }

    #if canImport(UIKit)
    @MainActor
    #endif
    public static var localDeviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    private static func describe(_ peripheral: CBPeripheral) -> String {
        peripheral.name ?? RemoteService.defaultName
    }

    private func report(_ status: Status) {
        log.info("status \(status)")
        DispatchQueue.main.async { self.onStatus?(status) }
    }
}

extension RemoteClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        log.info("central state=\(RemoteLog.describe(central.state)) stage=\(stage)")
        switch central.state {
        case .poweredOn: scan()
        case .poweredOff, .unauthorized, .unsupported:
            let failed = stage == .failed
            peripheral = nil
            resetConnection()
            if failed { stage = .failed }
            switch central.state {
            case .poweredOff: report(.poweredOff)
            case .unauthorized: report(.unauthorized)
            default: report(.unsupported)
            }
        default:
            let failed = stage == .failed
            peripheral = nil
            resetConnection()
            if failed { stage = .failed }
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        guard central === manager, isRunning, stage == .idle else { return }
        log.info("discovered mac=\(RemoteLog.id(peripheral.identifier)) name=\(Self.describe(peripheral)) rssi=\(RSSI)")
        central.stopScan()
        connect(to: peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === manager, peripheral === self.peripheral, stage == .connecting else {
            log.info("ignored didConnect mac=\(RemoteLog.id(peripheral.identifier)) stage=\(stage)")
            return
        }
        log.info("link connected mac=\(RemoteLog.id(peripheral.identifier)); discovering services")
        defaults.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)
        stage = .services
        armStageTimeout()
        peripheral.discoverServices([RemoteService.uuid])
    }

    public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        log.error("link failed mac=\(RemoteLog.id(peripheral.identifier)) stage=\(stage) error=\(RemoteLog.describe(error))")
        guard central === manager, peripheral === self.peripheral, stage == .connecting else { return }
        self.peripheral = nil
        resetConnection()
        scan()
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        log.error("link disconnected mac=\(RemoteLog.id(peripheral.identifier)) stage=\(stage) running=\(isRunning) error=\(RemoteLog.describe(error))")
        guard central === manager, peripheral === self.peripheral else { return }
        guard stage != .failed else { return }
        resetConnection()
        guard isRunning else { return }
        connect(to: peripheral)
    }
}

extension RemoteClient: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral, stage == .services else { return }
        log.info("services found=\(peripheral.services?.map(\.uuid.uuidString) ?? []) error=\(RemoteLog.describe(error))")
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == RemoteService.uuid }) else {
            fail(Self.updateRequired)
            return
        }
        stage = .characteristics
        armStageTimeout()
        peripheral.discoverCharacteristics([RemoteService.secureInputUUID, RemoteService.secureControlUUID], for: service)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard peripheral === self.peripheral, stage == .characteristics,
              service.uuid == RemoteService.uuid else { return }
        secureInput = service.characteristics?.first { $0.uuid == RemoteService.secureInputUUID }
        secureControl = service.characteristics?.first { $0.uuid == RemoteService.secureControlUUID }
        log.info("characteristics input=\(secureInput.map { String($0.properties.rawValue) } ?? "missing") control=\(secureControl.map { String($0.properties.rawValue) } ?? "missing") error=\(RemoteLog.describe(error))")
        guard error == nil, let secureInput, let secureControl,
              secureInput.properties.contains(.write), secureInput.properties.contains(.writeWithoutResponse),
              secureControl.properties.contains(.write), secureControl.properties.contains(.notify) else {
            fail(Self.updateRequired)
            return
        }
        stage = .subscribing
        report(.securing(Self.describe(peripheral)))
        armStageTimeout()
        peripheral.setNotifyValue(true, for: secureControl)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard peripheral === self.peripheral, characteristic === secureControl, stage != .failed else { return }
        log.info("notify state notifying=\(characteristic.isNotifying) stage=\(stage) error=\(RemoteLog.describe(error))")
        guard error == nil, characteristic.isNotifying else {
            fail("Secure notifications failed. Reconnect to the Mac.")
            return
        }
        guard stage == .subscribing else { return }
        do {
            let identity = try trust.identity()
            let pin = try trust.peer(for: peripheral.identifier)?.publicKey
            let handshake = SecureHandshake(identity: identity, role: .client, pinnedPeer: pin)
            log.info("sending clientHello pinnedMac=\(pin != nil)")
            self.handshake = handshake
            stage = .serverHello
            armStageTimeout()
            try enqueue(.handshake(handshake.start(), .clientHello), control: true, type: .withResponse)
            pump()
        } catch { failSecurity(error) }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard peripheral === self.peripheral, characteristic === secureControl,
              [.serverHello, .serverFinish, .approval, .ready].contains(stage) else { return }
        guard error == nil, let value = characteristic.value else {
            log.error("notification error stage=\(stage) error=\(RemoteLog.describe(error))")
            fail("Secure notification failed. Reconnect to the Mac.")
            return
        }
        do {
            let now = ProcessInfo.processInfo.systemUptime
            if receiveStarted == nil { receiveStarted = now }
            let complete = try assembler.accept(value, now: now)
            receiveTimer = UUID()
            if let complete {
                receiveStarted = nil
                if let lastReceivedID, complete.id <= lastReceivedID { throw SecureError.replay }
                lastReceivedID = complete.id
                try receive(complete.kind, data: complete.data, from: peripheral)
            } else {
                let token = receiveTimer
                let generation = self.generation
                let remaining = min(10, max(0, 30 - (now - (receiveStarted ?? now))))
                queue.asyncAfter(deadline: .now() + remaining) {
                    guard self.generation == generation, self.receiveTimer == token else { return }
                    self.log.error("incomplete notification message timed out")
                    self.fail("Secure notification transfer timed out. Reconnect to the Mac.")
                }
                if stage == .serverHello || stage == .serverFinish { armStageTimeout() }
            }
        } catch { failSecurity(error) }
    }

    private func receive(_ kind: SecureFrameKind, data: Data, from peripheral: CBPeripheral) throws {
        if stage == .serverHello {
            guard kind == .serverHello, let handshake else { throw SecureError.wrongPhase }
            let finish = try handshake.receiveServerHello(data)
            log.info("serverHello verified; sending clientFinish")
            peerPublicKey = handshake.peerPublicKey
            stage = .serverFinish
            armStageTimeout()
            try enqueue(.handshake(finish, .clientFinish), control: true, type: .withResponse)
            pump()
            return
        }
        guard kind == .encryptedControl else { throw SecureError.wrongPhase }
        if stage == .serverFinish {
            guard let handshake else { throw SecureError.wrongPhase }
            try handshake.receiveServerFinish(data)
            session = try handshake.takeSession()
            log.info("serverFinish verified; session ready, sending device name")
            self.handshake = nil
            stage = .approval
            armStageTimeout(300)
            try enqueue(.message(.name(deviceName)), control: true, type: .withResponse)
            pump()
            return
        }
        guard var session else { throw SecureError.wrongPhase }
        let message = try SecureMessage(wire: session.open(data, lane: .serverControl))
        self.session = session
        switch message {
        case .pending, .approved, .revoked: log.info("control message \(message) stage=\(stage)")
        default: break
        }
        switch message {
        case .pending:
            guard stage == .approval else { throw SecureError.wrongPhase }
            armStageTimeout(300)
            report(.awaitingApproval(Self.describe(peripheral)))
        case .approved:
            guard stage == .approval || stage == .ready, let peerPublicKey else { throw SecureError.wrongPhase }
            _ = try trust.approve(publicKey: peerPublicKey, name: Self.describe(peripheral), transportID: peripheral.identifier)
            stage = .ready
            stageTimer = UUID()
            report(.connected(Self.describe(peripheral)))
            pump()
        case .revoked:
            fail("Access was revoked on the Mac. Use Reconnect, then ask its owner to select Allow to pair again.")
        case .textResult(let id, let success):
            guard stage == .ready else { throw SecureError.wrongPhase }
            if let delivered = textDelivery.receipt(id: id, success: success) {
                textTimer = UUID()
                reportText(delivered: delivered)
            }
        default: throw SecureError.malformedMessage
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard peripheral === self.peripheral, stage != .failed,
              writeOutstanding, var current = record,
              current.type == .withResponse, characteristic === current.characteristic else { return }
        writeOutstanding = false
        guard error == nil else {
            log.error("write failed control=\(characteristic === secureControl) stage=\(stage) error=\(RemoteLog.describe(error))")
            fail("Secure write failed. Reconnect to the Mac.")
            return
        }
        queuedFrames -= 1
        queuedBytes -= current.frames[current.index].count
        current.index += 1
        record = current.index == current.frames.count ? nil : current
        if stage == .serverHello || stage == .serverFinish { armStageTimeout() }
        pump()
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        pump()
    }
}
