import RemoteClientCore
import RemoteProtocol
import SwiftUI
import UIKit

@MainActor
@Observable
final class RemoteViewModel {
    enum TextStatus: Equatable {
        case sending
        case sent
        case failed
    }

    private(set) var status: RemoteClient.Status = .stopped
    private(set) var textStatus: TextStatus?

    private let client = RemoteClient()
    private let tuning = TrackpadTuning.bundled
    private let haptics = UIImpactFeedbackGenerator(style: .rigid)
    private var textStatusReset: Task<Void, Never>?

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
        case .securing(let name): "Securing connection to \(name)…"
        case .failed(let message): message
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
        client.onTextDelivered = { [weak self] delivered in
            // RemoteClient always reports on the main queue.
            MainActor.assumeIsolated {
                self?.show(delivered ? .sent : .failed)
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

    func reconnect() {
        client.stop()
        client.start()
    }

    func forgetMac() {
        client.forgetMac()
    }

    func press(_ command: Command) {
        haptics.impactOccurred()
        client.send(KeyEvent(command: command, isDown: true))
    }

    func release(_ command: Command) {
        client.send(KeyEvent(command: command, isDown: false))
    }

    /// `feedback` is off while a key auto-repeats, where a buzz per press would be
    /// a continuous rumble.
    func tap(_ command: Command, feedback: Bool = true) {
        guard isConnected else { return }
        if feedback { haptics.impactOccurred() }
        client.tap(command)
    }

    func moveCursor(by translation: CGPoint, velocity: CGPoint) {
        guard isConnected else { return }
        let gain = tuning.cursor.gain(forFingerSpeed: hypot(velocity.x, velocity.y))
        client.move(dx: translation.x * gain, dy: translation.y * gain)
    }

    func scroll(by translation: CGPoint, velocity: CGPoint, phase: RemoteProtocol.ScrollPhase) {
        guard isConnected else { return }
        let delta = scrollContent(translation, fingerVelocity: velocity)
        client.scroll(dx: delta.x, dy: delta.y, phase: phase)
    }

    /// Nil when the release was too slow to coast or momentum is turned off.
    func momentum(afterReleaseAt velocity: CGPoint) -> ScrollMomentum? {
        guard isConnected else { return nil }
        let content = scrollContent(velocity, fingerVelocity: velocity)
        return ScrollMomentum(velocityX: content.x, velocityY: content.y, tuning: tuning.scroll.momentum)
    }

    /// Momentum deltas are already in Mac pixels, so no gain is applied.
    func coast(dx: Double, dy: Double, phase: RemoteProtocol.ScrollPhase) {
        client.scroll(dx: dx, dy: dy, phase: phase)
    }

    /// Finger travel in points to content travel in Mac pixels.
    private func scrollContent(_ value: CGPoint, fingerVelocity: CGPoint) -> CGPoint {
        let gain = tuning.scroll.gain.gain(forFingerSpeed: hypot(fingerVelocity.x, fingerVelocity.y))
        let sign: Double = tuning.scroll.naturalDirection ? 1 : -1
        return CGPoint(x: value.x * gain * sign, y: value.y * gain * sign)
    }

    func click(_ button: MouseButton, count: UInt8) {
        guard isConnected else { return }
        haptics.impactOccurred()
        client.click(button, count: count)
    }

    var gestures: TrackpadTuning.Gestures { tuning.gestures }

    func swipe(_ direction: SwipeDirection) {
        guard isConnected else { return }
        haptics.impactOccurred()
        client.swipe(direction)
    }

    func beginDrag() {
        guard isConnected else { return }
        haptics.impactOccurred()
        client.press(.left, isDown: true)
    }

    /// Not gated on the connection: a release must never be skipped.
    func endDrag() {
        client.press(.left, isDown: false)
    }

    func send(text: String) {
        guard textStatus != .sending else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !trimmed.isEmpty else { return }
        haptics.impactOccurred()
        show(.sending)
        client.send(text: trimmed)
    }

    private func show(_ status: TextStatus) {
        textStatus = status
        textStatusReset?.cancel()
        guard status != .sending else { return }

        textStatusReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            textStatus = nil
        }
    }
}
