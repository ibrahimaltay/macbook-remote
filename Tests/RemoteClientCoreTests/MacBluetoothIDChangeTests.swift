import CoreBluetooth
import Foundation
@testable import RemoteClientCore
import RemoteSecurity
import XCTest

/// TC-3a / TC-3b in test-cases.md: the Mac comes back under a new Bluetooth ID.
final class MacBluetoothIDChangeTests: XCTestCase {
    private let oldID = UUID()
    private let newID = UUID()

    func testTC3a_ForgottenOldIDFindsMacUnderNewID() {
        let air = FakeAir()
        air.advertise(FakePeripheral(id: newID, name: "MacBook A"))
        let (client, clock) = makeClient(savedMacID: oldID, air: air)

        client.start()
        clock.settle(client)

        XCTAssertEqual(air.connectAttempts, [newID])
        XCTAssertEqual(air.connected, [newID])
    }

    func testTC3b_StaleOldIDFallsBackToScanningAndFindsMacUnderNewID() {
        let air = FakeAir()
        air.remember(FakePeripheral(id: oldID, name: "MacBook A"))
        air.advertise(FakePeripheral(id: newID, name: "MacBook A"))
        let (client, clock) = makeClient(savedMacID: oldID, air: air)

        client.start()
        clock.settle(client)
        XCTAssertEqual(air.connectAttempts, [oldID])

        clock.advance(by: 15, client)

        XCTExpectFailure("TC-3b: connecting to a saved Mac has no timeout and never falls back to scanning")
        XCTAssertEqual(air.connectAttempts, [oldID, newID])
        XCTAssertEqual(air.connected, [newID])
    }

    private func makeClient(savedMacID: UUID, air: FakeAir) -> (RemoteClient, FakeClock) {
        let suite = "MacBluetoothIDChangeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set(savedMacID.uuidString, forKey: "lastPeripheral")

        let clock = FakeClock()
        let client = RemoteClient(
            deviceName: "iPhone B", defaults: defaults, keyStore: MemoryKeyStore(),
            makeCentral: { air.attach(delegate: $0, queue: $1) },
            schedule: { clock.schedule(after: $0, $1) }
        )
        addTeardownBlock { client.stop(); clock.settle(client) }
        return (client, clock)
    }
}

/// Bluetooth as the iPhone sees it: IDs iOS still remembers, and Macs currently advertising.
/// Connecting to a remembered ID that is not advertising stays pending forever, as on iOS.
private final class FakeAir: BluetoothCentral, @unchecked Sendable {
    private weak var delegate: (any BluetoothCentralDelegate)?
    private var queue: DispatchQueue?
    private var remembered: [UUID: FakePeripheral] = [:]
    private var advertising: [UUID: FakePeripheral] = [:]
    private(set) var connectAttempts: [UUID] = []
    private(set) var connected: [UUID] = []
    private(set) var isScanning = false

    let state: CBManagerState = .poweredOn

    func remember(_ peripheral: FakePeripheral) {
        remembered[peripheral.identifier] = peripheral
    }

    func advertise(_ peripheral: FakePeripheral) {
        advertising[peripheral.identifier] = peripheral
    }

    func attach(delegate: any BluetoothCentralDelegate, queue: DispatchQueue) -> any BluetoothCentral {
        self.delegate = delegate
        self.queue = queue
        queue.async { delegate.centralDidUpdateState(self) }
        return self
    }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any BluetoothPeripheral] {
        identifiers.compactMap { remembered[$0] }
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?) {
        isScanning = true
        for peripheral in advertising.values {
            queue?.async { [self] in
                guard isScanning else { return }
                delegate?.central(self, didDiscover: peripheral)
            }
        }
    }

    func stopScan() {
        isScanning = false
    }

    func connect(_ peripheral: any BluetoothPeripheral) {
        connectAttempts.append(peripheral.identifier)
        guard let peripheral = advertising[peripheral.identifier] else { return }
        queue?.async { [self] in
            peripheral.state = .connected
            connected.append(peripheral.identifier)
            delegate?.central(self, didConnect: peripheral)
        }
    }

    func cancelPeripheralConnection(_ peripheral: any BluetoothPeripheral) {
        (peripheral as? FakePeripheral)?.state = .disconnected
    }
}

private final class FakePeripheral: BluetoothPeripheral, @unchecked Sendable {
    let identifier: UUID
    let name: String?
    var state: CBPeripheralState = .disconnected
    weak var delegate: (any CBPeripheralDelegate)?
    let canSendWriteWithoutResponse = true

    init(id: UUID, name: String) {
        identifier = id
        self.name = name
    }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 182 }
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
    func discoverServices(_ serviceUUIDs: [CBUUID]?) {}
}

/// Runs the client's timers when the test moves time forward, on the client's queue.
private final class FakeClock: @unchecked Sendable {
    private var now: TimeInterval = 0
    private var tasks: [(due: TimeInterval, work: @Sendable () -> Void)] = []

    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        tasks.append((now + seconds, work))
    }

    func advance(by seconds: TimeInterval, _ client: RemoteClient) {
        let target = now + seconds
        settle(client)
        while let index = tasks.indices.filter({ tasks[$0].due <= target }).min(by: { tasks[$0].due < tasks[$1].due }) {
            let task = tasks.remove(at: index)
            now = task.due
            client.queue.sync(execute: task.work)
            settle(client)
        }
        now = target
    }

    /// Lets queued Bluetooth callbacks, and the work they queue in turn, finish.
    func settle(_ client: RemoteClient) {
        for _ in 0..<20 { client.queue.sync {} }
    }
}

private final class MemoryKeyStore: SecureKeyStore {
    private var records: [String: Data] = [:]

    func load(_ account: String) throws -> Data? { records[account] }
    func save(_ data: Data, account: String) throws { records[account] = data }
    func delete(_ account: String) throws { records.removeValue(forKey: account) }
}
