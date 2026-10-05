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

    let queue = DispatchQueue(label: "remote.client")
    private let deviceName: String
    private let defaults: UserDefaults
    private let trust: PeerTrustStore
    private let makeCentral: (any BluetoothCentralDelegate, DispatchQueue) -> any BluetoothCentral
    private let schedule: ((TimeInterval, @escaping @Sendable () -> Void) -> Void)?
    private var manager: (any BluetoothCentral)?
    private var peripheral: (any BluetoothPeripheral)?
    private var secureInput: CBCharacteristic?
    private var secureControl: CBCharacteristic?
    private var stage: Stage = .idle
    private var isRunning = false
    private var forgetBlocked = false
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
    public convenience init(
        deviceName: String = RemoteClient.localDeviceName,
        defaults: UserDefaults = .standard,
        keyStore: (any SecureKeyStore)?
    ) {
        self.init(
            deviceName: deviceName, defaults: defaults, keyStore: keyStore,
            makeCentral: { CoreBluetoothCentral(delegate: $0, queue: $1) }, schedule: nil
        )
    }

    /// `schedule` runs work on the client's queue after a delay; `nil` uses real time.
    init(
        deviceName: String,
        defaults: UserDefaults,
        keyStore: (any SecureKeyStore)?,
        makeCentral: @escaping (any BluetoothCentralDelegate, DispatchQueue) -> any BluetoothCentral,
        schedule: ((TimeInterval, @escaping @Sendable () -> Void) -> Void)?
    ) {
        self.deviceName = deviceName
        self.defaults = defaults
        trust = PeerTrustStore(store: keyStore ?? KeychainSecureKeyStore(
            service: "com.altay.lazyremote.client.security"
        ))
        self.makeCentral = makeCentral
        self.schedule = schedule
        super.init()
    }

    public func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard !forgetBlocked else {
            report(.failed("Could not forget this Mac securely. Retry Forget Mac before reconnecting."))
            return
        }
        guard manager == nil else { return }
        isRunning = true
        stage = .idle
        manager = makeCentral(self, queue)
    }

    public func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func stopOnQueue() {
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
                if restart { self.startOnQueue() }
            } catch {
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
                self.after(30) {
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
                after(30) {
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
                after(30) {
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
            if !jobs.isEmpty || (stage == .ready && (abs(pendingX) >= 1 || abs(pendingY) >= 1)) { pump() }
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
        finishText(false)
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
        after(seconds) {
            guard self.generation == generation, self.stageTimer == token,
                  self.stage != .ready, self.stage != .idle, self.stage != .failed else { return }
            self.fail("Secure connection timed out. Reconnect and check approval on the Mac.")
        }
    }

    private func failSecurity(_ error: Error) {
        if error as? SecureError == .identityChanged {
            fail("This Mac's identity changed. Verify the Mac, then use Forget Mac to pair again.")
        } else {
            fail("Secure connection failed. Update both apps and reconnect; verify the Mac before using Forget Mac.")
        }
    }

    private func fail(_ message: String) {
        guard stage != .failed else { return }
        resetConnection()
        stage = .failed
        if manager?.state == .poweredOn { manager?.stopScan() }
        report(.failed(message))
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
    }

    private func scan() {
        guard isRunning, stage == .idle, let manager, manager.state == .poweredOn else { return }
        if let saved = defaults.string(forKey: Self.lastPeripheralKey),
           let id = UUID(uuidString: saved),
           let known = manager.retrievePeripherals(withIdentifiers: [id]).first {
            connect(to: known)
            return
        }
        report(.scanning)
        manager.scanForPeripherals(withServices: [RemoteService.uuid])
    }

    private func after(_ seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        if let schedule {
            schedule(seconds, work)
        } else {
            queue.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private func connect(to peripheral: any BluetoothPeripheral) {
        resetConnection()
        self.peripheral = peripheral
        peripheral.delegate = self
        stage = .connecting
        report(.connecting(Self.describe(peripheral)))
        manager?.connect(peripheral)
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

    private static func describe(_ peripheral: any BluetoothPeripheral) -> String {
        peripheral.name ?? RemoteService.defaultName
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }
}

extension RemoteClient: BluetoothCentralDelegate {
    func centralDidUpdateState(_ central: any BluetoothCentral) {
        guard central === manager else { return }
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

    func central(_ central: any BluetoothCentral, didDiscover peripheral: any BluetoothPeripheral) {
        guard central === manager, isRunning, stage == .idle else { return }
        central.stopScan()
        connect(to: peripheral)
    }

    func central(_ central: any BluetoothCentral, didConnect peripheral: any BluetoothPeripheral) {
        guard central === manager, peripheral === self.peripheral, stage == .connecting else { return }
        defaults.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)
        stage = .services
        armStageTimeout()
        peripheral.discoverServices([RemoteService.uuid])
    }

    func central(_ central: any BluetoothCentral, didFailToConnect peripheral: any BluetoothPeripheral) {
        guard central === manager, peripheral === self.peripheral, stage == .connecting else { return }
        self.peripheral = nil
        resetConnection()
        scan()
    }

    func central(_ central: any BluetoothCentral, didDisconnect peripheral: any BluetoothPeripheral) {
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
        guard error == nil, characteristic.isNotifying else {
            fail("Secure notifications failed. Reconnect to the Mac.")
            return
        }
        guard stage == .subscribing else { return }
        do {
            let identity = try trust.identity()
            let pin = try trust.peer(for: peripheral.identifier)?.publicKey
            let handshake = SecureHandshake(identity: identity, role: .client, pinnedPeer: pin)
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
                after(remaining) {
                    guard self.generation == generation, self.receiveTimer == token else { return }
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
            fail("Access was revoked on the Mac. Ask its owner to approve access, then use Forget Mac to pair again.")
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
