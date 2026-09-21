import CoreBluetooth
import Foundation
import RemoteProtocol

/// Advertises over BLE and replays what a paired iPhone sends as key presses.
public final class RemoteServer: NSObject, @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case stopped
        case advertising
        case poweredOff
        case unauthorized
        case unsupported
        case failed(String)
    }

    /// Called on the main queue.
    public var onStatus: ((Status) -> Void)?
    /// Called on the main queue.
    public var onEvent: ((KeyEvent) -> Void)?
    /// Called on the main queue when the device list or its connection state changes.
    public var onDevices: (([PairedDevice]) -> Void)?

    private let queue = DispatchQueue(label: "remote.server")
    private let serviceName: String
    private let injector = KeyInjector()
    private let store: PairedDeviceStore

    private var manager: CBPeripheralManager?
    private var control: CBMutableCharacteristic?
    private var connected: [UUID: CBCentral] = [:]
    /// Names of devices that have shown up but are not approved yet.
    private var pending: [UUID: String] = [:]
    private var isRunning = false

    public init(serviceName: String = RemoteService.defaultName, defaults: UserDefaults = .standard) {
        self.serviceName = serviceName
        self.store = PairedDeviceStore(defaults: defaults)
        super.init()
    }

    public func start() {
        queue.async {
            guard self.manager == nil else { return }
            self.isRunning = true
            // Building the manager is what prompts for Bluetooth permission.
            self.manager = CBPeripheralManager(delegate: self, queue: self.queue)
        }
    }

    public func stop() {
        queue.async {
            self.isRunning = false
            self.manager?.stopAdvertising()
            self.manager?.removeAllServices()
            self.manager = nil
            self.control = nil
            self.connected.removeAll()
            self.pending.removeAll()
            self.report(.stopped)
            self.reportDevices()
        }
    }

    /// Let a device through. Its key presses are dropped until this happens.
    public func approve(_ id: UUID) {
        queue.async {
            let name = self.pending[id] ?? self.store.name(for: id) ?? "Unknown device"
            self.store.approve(id, name: name)
            self.pending.removeValue(forKey: id)
            self.push(.approved, to: id)
            self.reportDevices()
        }
    }

    /// Drop a device. It has to be approved again before it can send anything.
    public func forget(_ id: UUID) {
        queue.async {
            self.store.forget(id)
            self.pending.removeValue(forKey: id)
            self.push(.pending, to: id)
            self.reportDevices()
        }
    }

    private func publish() {
        guard let manager, isRunning else { return }

        // No EncryptionRequired permissions: macOS will not bond in the peripheral
        // role, so the iPhone's reads and writes come back "encryption insufficient"
        // and it never gets a pairing prompt. The approval list below is the gate.
        let keyEvent = CBMutableCharacteristic(
            type: RemoteService.keyEventUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let control = CBMutableCharacteristic(
            type: RemoteService.controlUUID,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )

        let service = CBMutableService(type: RemoteService.uuid, primary: true)
        service.characteristics = [keyEvent, control]

        self.control = control
        manager.removeAllServices()
        manager.add(service)
    }

    private func approval(for id: UUID) -> ApprovalState {
        store.isApproved(id) ? .approved : .pending
    }

    private func push(_ state: ApprovalState, to id: UUID) {
        guard let manager, let control, let central = connected[id] else { return }
        manager.updateValue(state.encoded, for: control, onSubscribedCentrals: [central])
    }

    private func note(_ central: CBCentral, name: String? = nil) {
        connected[central.identifier] = central
        let id = central.identifier

        if let name {
            if store.isApproved(id) {
                store.rename(id, to: name)
            } else {
                pending[id] = name
            }
        } else if !store.isApproved(id), pending[id] == nil {
            pending[id] = "Unknown device"
        }
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    private func reportDevices() {
        var devices = store.approved.map { id, name in
            PairedDevice(id: id, name: name, isApproved: true, isConnected: connected[id] != nil)
        }
        devices += pending.map { id, name in
            PairedDevice(id: id, name: name, isApproved: false, isConnected: connected[id] != nil)
        }
        // Waiting devices first: they are the ones needing a decision.
        devices.sort { ($0.isApproved ? 1 : 0, $0.name) < ($1.isApproved ? 1 : 0, $1.name) }

        DispatchQueue.main.async { self.onDevices?(devices) }
    }
}

extension RemoteServer: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn: publish()
        case .poweredOff: report(.poweredOff)
        case .unauthorized: report(.unauthorized)
        case .unsupported: report(.unsupported)
        default: break
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            report(.failed(error.localizedDescription))
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [RemoteService.uuid],
            CBAdvertisementDataLocalNameKey: serviceName,
        ])
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            report(.failed(error.localizedDescription))
        } else {
            report(.advertising)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == RemoteService.controlUUID else { return }
        note(central)
        push(approval(for: central.identifier), to: central.identifier)
        reportDevices()
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == RemoteService.controlUUID else { return }
        connected.removeValue(forKey: central.identifier)
        reportDevices()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == RemoteService.controlUUID else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        note(request.central)
        request.value = approval(for: request.central.identifier).encoded
        peripheral.respond(to: request, withResult: .success)
        reportDevices()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        var result = CBATTError.Code.success

        for request in requests {
            if request.characteristic.uuid == RemoteService.controlUUID {
                let name = request.value
                    .flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                note(request.central, name: name?.isEmpty == false ? name : nil)
                reportDevices()
            } else if request.characteristic.uuid == RemoteService.keyEventUUID {
                note(request.central)
                guard store.isApproved(request.central.identifier) else {
                    result = .insufficientAuthorization
                    reportDevices()
                    continue
                }
                if let value = request.value, let event = KeyEvent(wire: value) {
                    injector.post(event)
                    DispatchQueue.main.async { self.onEvent?(event) }
                }
            } else {
                result = .requestNotSupported
            }
        }

        // Core Bluetooth wants exactly one response per batch, on the first request.
        if let first = requests.first {
            peripheral.respond(to: first, withResult: result)
        }
    }
}
