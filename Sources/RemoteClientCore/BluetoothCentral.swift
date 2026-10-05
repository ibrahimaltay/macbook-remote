import CoreBluetooth
import Foundation

/// The parts of `CBPeripheral` that `RemoteClient` uses outside of peripheral delegate callbacks.
protocol BluetoothPeripheral: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
    var state: CBPeripheralState { get }
    var delegate: (any CBPeripheralDelegate)? { get set }
    var canSendWriteWithoutResponse: Bool { get }
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType)
    func discoverServices(_ serviceUUIDs: [CBUUID]?)
}

extension CBPeripheral: BluetoothPeripheral {}

protocol BluetoothCentral: AnyObject {
    var state: CBManagerState { get }
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any BluetoothPeripheral]
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?)
    func stopScan()
    func connect(_ peripheral: any BluetoothPeripheral)
    func cancelPeripheralConnection(_ peripheral: any BluetoothPeripheral)
}

/// Called on the queue the central was created with.
protocol BluetoothCentralDelegate: AnyObject {
    func centralDidUpdateState(_ central: any BluetoothCentral)
    func central(_ central: any BluetoothCentral, didDiscover peripheral: any BluetoothPeripheral)
    func central(_ central: any BluetoothCentral, didConnect peripheral: any BluetoothPeripheral)
    func central(_ central: any BluetoothCentral, didFailToConnect peripheral: any BluetoothPeripheral)
    func central(_ central: any BluetoothCentral, didDisconnect peripheral: any BluetoothPeripheral)
}

final class CoreBluetoothCentral: NSObject, BluetoothCentral, CBCentralManagerDelegate {
    private weak var delegate: (any BluetoothCentralDelegate)?
    private var manager: CBCentralManager?

    init(delegate: any BluetoothCentralDelegate, queue: DispatchQueue) {
        self.delegate = delegate
        super.init()
        manager = CBCentralManager(delegate: self, queue: queue)
    }

    var state: CBManagerState { manager?.state ?? .unknown }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any BluetoothPeripheral] {
        manager?.retrievePeripherals(withIdentifiers: identifiers) ?? []
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?) {
        manager?.scanForPeripherals(withServices: serviceUUIDs)
    }

    func stopScan() {
        manager?.stopScan()
    }

    func connect(_ peripheral: any BluetoothPeripheral) {
        guard let peripheral = peripheral as? CBPeripheral else { return }
        manager?.connect(peripheral)
    }

    func cancelPeripheralConnection(_ peripheral: any BluetoothPeripheral) {
        guard let peripheral = peripheral as? CBPeripheral else { return }
        manager?.cancelPeripheralConnection(peripheral)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        delegate?.centralDidUpdateState(self)
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        delegate?.central(self, didDiscover: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        delegate?.central(self, didConnect: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        delegate?.central(self, didFailToConnect: peripheral)
    }

    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        delegate?.central(self, didDisconnect: peripheral)
    }
}
