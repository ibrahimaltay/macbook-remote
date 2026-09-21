import RemoteClientCore
import RemoteProtocol
import SwiftUI
import UIKit

@MainActor
@Observable
final class RemoteViewModel {
    private(set) var status: RemoteClient.Status = .stopped

    private let client = RemoteClient()
    private let haptics = UIImpactFeedbackGenerator(style: .rigid)

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    var statusText: String {
        switch status {
        case .stopped: "Off"
        case .poweredOff: "Turn on Bluetooth"
        case .unauthorized: "Allow Bluetooth in Settings"
        case .unsupported: "Bluetooth not supported"
        case .scanning: "Looking for your Mac…"
        case .connecting(let name): "Connecting to \(name)…"
        case .awaitingApproval(let name): "Allow this iPhone on \(name)"
        case .connected(let name): name
        }
    }

    init() {
        client.onStatus = { [weak self] status in
            // RemoteClient always reports on the main queue.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.status = status
                UIApplication.shared.isIdleTimerDisabled = self.isConnected
            }
        }
        haptics.prepare()
    }

    func start() {
        client.start()
    }

    func stop() {
        client.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func press(_ command: Command) {
        haptics.impactOccurred()
        client.send(KeyEvent(command: command, isDown: true))
    }

    func release(_ command: Command) {
        client.send(KeyEvent(command: command, isDown: false))
    }

    func moveCursor(by translation: CGPoint, velocity: CGPoint) {
        guard isConnected else { return }
        let gain = Self.gain(forSpeed: hypot(velocity.x, velocity.y))
        client.move(dx: translation.x * gain, dy: translation.y * gain)
    }

    func click(_ button: MouseButton, count: UInt8) {
        guard isConnected else { return }
        haptics.impactOccurred()
        client.click(button, count: count)
    }

    /// Pointer ballistics: near 1:1 when the finger is slow so you can aim, several
    /// times that on a flick so one swipe crosses the whole display.
    private static func gain(forSpeed speed: Double) -> Double {
        min(1 + speed / 1000 * 3.5, 4.5)
    }
}
