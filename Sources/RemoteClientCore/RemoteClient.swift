import CoreBluetooth
import Foundation
import RemoteProtocol

#if canImport(UIKit)
import UIKit
#endif

/// Finds the Mac over BLE, stays connected to it, and sends button presses.
/// Shared by the iPhone app and the `remotectl send` test command.
public final class RemoteClient: NSObject, @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case stopped
        case poweredOff
        case unauthorized
        case unsupported
        case scanning
        case connecting(String)
        case awaitingApproval(String)
        case connected(String)
    }

    /// Called on the main queue.
    public var onStatus: ((Status) -> Void)?
    /// Called on the main queue once every chunk of a typed message has been
    /// acknowledged, or as soon as one fails.
    public var onTextDelivered: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "remote.client")
    private let deviceName: String
    private let defaults: UserDefaults

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var keyEvent: CBCharacteristic?
    private var approval: ApprovalState = .pending
    private var isRunning = false
    /// Cursor movement waiting for the radio, kept fractional so slow, careful
    /// movements are not lost to rounding.
    private var pendingX = 0.0
    private var pendingY = 0.0
    /// Chunks of the message being typed that have not been acknowledged yet.
    private var pendingTextWrites = 0
    private var textWriteFailed = false

    private static let lastPeripheralKey = "lastPeripheral"

    public init(deviceName: String = RemoteClient.localDeviceName, defaults: UserDefaults = .standard) {
        self.deviceName = deviceName
        self.defaults = defaults
        super.init()
    }

    /// Safe to call again after `stop()`, which is what returning to the foreground does.
    public func start() {
        queue.async {
            guard self.manager == nil else { return }
            self.isRunning = true
            // Building the manager is what prompts for Bluetooth permission.
            self.manager = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    public func stop() {
        queue.async {
            self.isRunning = false
            if self.manager?.state == .poweredOn {
                self.manager?.stopScan()
            }
            if let peripheral = self.peripheral {
                self.manager?.cancelPeripheralConnection(peripheral)
            }
            self.peripheral = nil
            self.keyEvent = nil
            self.approval = .pending
            self.pendingX = 0
            self.pendingY = 0
            self.manager = nil
            self.report(.stopped)
        }
    }

    public func send(_ event: KeyEvent) {
        queue.async {
            guard let target = self.target else { return }

            // Without-response skips the ACK round trip. Fall back when the queue is
            // full so a press is never silently dropped.
            let type: CBCharacteristicWriteType =
                target.peripheral.canSendWriteWithoutResponse ? .withoutResponse : .withResponse
            target.peripheral.writeValue(event.encoded, for: target.characteristic, type: type)
        }
    }

    /// A normal tap: press and release.
    public func tap(_ command: Command) {
        send(KeyEvent(command: command, isDown: true))
        send(KeyEvent(command: command, isDown: false))
    }

    // MARK: - Pointer

    /// Moves the cursor. Deltas pile up until the radio is ready rather than queueing
    /// writes, so the cursor lands where the finger is now instead of replaying a
    /// backlog a second behind it.
    public func move(dx: Double, dy: Double) {
        queue.async {
            self.pendingX += dx
            self.pendingY += dy
            self.flushMove()
        }
    }

    public func click(_ button: MouseButton, count: UInt8) {
        queue.async {
            self.flushMove() // a click must not overtake the movement that aimed it
            guard let target = self.target else { return }

            let type: CBCharacteristicWriteType =
                target.peripheral.canSendWriteWithoutResponse ? .withoutResponse : .withResponse
            target.peripheral.writeValue(
                PointerEvent.click(button: button, count: count).encoded,
                for: target.characteristic,
                type: type
            )
        }
    }

    private func flushMove() {
        guard let target, target.peripheral.canSendWriteWithoutResponse else { return }
        let dx = pendingX.rounded(.towardZero)
        let dy = pendingY.rounded(.towardZero)
        guard dx != 0 || dy != 0 else { return }
        pendingX -= dx
        pendingY -= dy

        let event = PointerEvent.move(dx: Int16(clamping: Int(dx)), dy: Int16(clamping: Int(dy)))
        target.peripheral.writeValue(event.encoded, for: target.characteristic, type: .withoutResponse)
    }

    /// Everything needed to write, or nil when the link is not usable yet.
    private var target: (peripheral: CBPeripheral, characteristic: CBCharacteristic)? {
        guard approval == .approved,
              let peripheral,
              let keyEvent,
              peripheral.state == .connected
        else { return nil }
        return (peripheral, keyEvent)
    }

    // MARK: - Text

    /// Types text on the Mac. Split across writes to fit the MTU, and acknowledged
    /// rather than fire-and-forget, because a lost chunk would corrupt the message.
    public func send(text: String) {
        queue.async {
            let bytes = Data(text.utf8)
            guard !bytes.isEmpty, let target = self.target else {
                self.reportText(delivered: false)
                return
            }

            let room = target.peripheral.maximumWriteValueLength(for: .withResponse)
            let limit = max(room - TextChunk.headerSize, 1)

            self.pendingTextWrites = 0
            self.textWriteFailed = false

            var index = bytes.startIndex
            while index < bytes.endIndex {
                let end = bytes.index(index, offsetBy: limit, limitedBy: bytes.endIndex) ?? bytes.endIndex
                let chunk = TextChunk(isFinal: end == bytes.endIndex, bytes: Data(bytes[index..<end]))
                self.pendingTextWrites += 1
                target.peripheral.writeValue(chunk.encoded, for: target.characteristic, type: .withResponse)
                index = end
            }
        }
    }

    private func reportText(delivered: Bool) {
        DispatchQueue.main.async { self.onTextDelivered?(delivered) }
    }

    // MARK: - Discovery

    private func scan() {
        guard isRunning, let manager, manager.state == .poweredOn else { return }

        // Going straight back to the known Mac skips discovery entirely.
        if let saved = defaults.string(forKey: Self.lastPeripheralKey),
           let id = UUID(uuidString: saved),
           let known = manager.retrievePeripherals(withIdentifiers: [id]).first {
            connect(to: known)
            return
        }

        report(.scanning)
        manager.scanForPeripherals(withServices: [RemoteService.uuid])
    }

    // MARK: - Connection

    private func connect(to peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        approval = .pending
        report(.connecting(Self.describe(peripheral)))
        // No timeout on this: it completes whenever the Mac comes back in range,
        // which is why there is no retry loop here.
        manager?.connect(peripheral)
    }

    // MARK: - Helpers

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
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    private func reportApproval(for peripheral: CBPeripheral) {
        report(approval == .approved ? .connected(Self.describe(peripheral)) : .awaitingApproval(Self.describe(peripheral)))
    }
}

extension RemoteClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: scan()
        case .poweredOff: report(.poweredOff)
        case .unauthorized: report(.unauthorized)
        case .unsupported: report(.unsupported)
        default: break
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        connect(to: peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        defaults.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)
        peripheral.discoverServices([RemoteService.uuid])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        keyEvent = nil
        approval = .pending
        scan()
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        keyEvent = nil
        approval = .pending
        pendingX = 0
        pendingY = 0
        guard isRunning else { return }
        connect(to: peripheral)
    }
}

extension RemoteClient: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == RemoteService.uuid }) else { return }
        peripheral.discoverCharacteristics(
            [RemoteService.keyEventUUID, RemoteService.controlUUID],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == RemoteService.keyEventUUID {
                keyEvent = characteristic
            } else if characteristic.uuid == RemoteService.controlUUID {
                // Both of these need an encrypted link, so they are what triggers
                // pairing, before any key press is attempted.
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
                peripheral.writeValue(Data(deviceName.utf8), for: characteristic, type: .withResponse)
            }
        }
        reportApproval(for: peripheral)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            print("[remote] read/notify failed on \(characteristic.uuid): \(error.localizedDescription)")
        }
        guard characteristic.uuid == RemoteService.controlUUID, let value = characteristic.value else { return }
        approval = ApprovalState(wire: value)
        reportApproval(for: peripheral)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            print("[remote] write failed on \(characteristic.uuid): \(error.localizedDescription)")
        }
        guard characteristic.uuid == RemoteService.keyEventUUID, pendingTextWrites > 0 else { return }

        // Acknowledgements arrive in write order, so counting them down is enough to
        // know the last chunk landed. A key press that happened to fall back to a
        // write-with-response could nudge the count early, which only ever makes the
        // confirmation appear a chunk sooner.
        pendingTextWrites -= 1
        textWriteFailed = textWriteFailed || error != nil
        if pendingTextWrites == 0 {
            reportText(delivered: !textWriteFailed)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            print("[remote] subscribe failed on \(characteristic.uuid): \(error.localizedDescription)")
        }
    }

    /// Already on `queue`, like every other delegate callback here.
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushMove()
    }
}
