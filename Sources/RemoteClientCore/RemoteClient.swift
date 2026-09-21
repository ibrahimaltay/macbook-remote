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

    private let queue = DispatchQueue(label: "remote.client")
    private let deviceName: String
    private let defaults: UserDefaults

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var keyEvent: CBCharacteristic?
    private var approval: ApprovalState = .pending
    private var isRunning = false

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
            self.manager = nil
            self.report(.stopped)
        }
    }

    public func send(_ event: KeyEvent) {
        queue.async {
            guard self.approval == .approved,
                  let peripheral = self.peripheral,
                  let keyEvent = self.keyEvent,
                  peripheral.state == .connected
            else { return }

            // Without-response skips the ACK round trip. Fall back when the queue is
            // full so a press is never silently dropped.
            let type: CBCharacteristicWriteType =
                peripheral.canSendWriteWithoutResponse ? .withoutResponse : .withResponse
            peripheral.writeValue(event.encoded, for: keyEvent, type: type)
        }
    }

    /// A normal tap: press and release.
    public func tap(_ command: Command) {
        send(KeyEvent(command: command, isDown: true))
        send(KeyEvent(command: command, isDown: false))
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
}
