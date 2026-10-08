import AppKit
import Foundation
import RemoteProtocol
import RemoteServerCore
import SwiftUI

@MainActor
@Observable
final class ServerViewModel {
    private(set) var status: RemoteServer.Status = .stopped
    private(set) var devices: [PairedDevice] = []
    private(set) var isAccessibilityTrusted = KeyInjector.isTrusted
    private(set) var isResettingTrust = false
    private(set) var trustResetError: String?

    private static let enabledKey = "serverEnabled"

    private let server = RemoteServer()
    private var enabled: Bool
    private var launchAtLogin = LaunchAtLogin.isEnabled
    private var activity: NSObjectProtocol?

    var isEnabled: Bool {
        get { enabled }
        set {
            guard newValue != enabled else { return }
            enabled = newValue
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { start() } else { stop() }
        }
    }

    var launchesAtLogin: Bool {
        get { launchAtLogin }
        set {
            LaunchAtLogin.set(newValue)
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    var canLaunchAtLogin: Bool { LaunchAtLogin.isAvailable }
    var canApproveDevices: Bool { !isResettingTrust && trustResetError == nil }

    var statusText: String {
        switch status {
        case .stopped: "Off"
        case .advertising: "Ready"
        case .poweredOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access denied"
        case .unsupported: "Bluetooth LE not supported"
        case .failed(let message): "Error: \(message)"
        }
    }

    var pendingDevices: [PairedDevice] { devices.filter { !$0.isApproved } }

    var approvedDevices: [PairedDevice] { devices.filter(\.isApproved) }

    private var connectedCount: Int {
        devices.filter { $0.isApproved && $0.isConnected }.count
    }

    var clientText: String {
        switch connectedCount {
        case 0: "No devices connected"
        case 1: "1 device connected"
        default: "\(connectedCount) devices connected"
        }
    }

    var icon: Image {
        if !isAccessibilityTrusted || trustResetError != nil { return Image(systemName: "exclamationmark.triangle.fill") }
        if case .failed = status { return Image(systemName: "exclamationmark.triangle.fill") }
        return Image(connectedCount > 0 ? "RemoteIconFill" : "RemoteIcon")
    }

    init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)

        server.onStatus = { [weak self] status in
            // RemoteServer always reports on the main queue.
            MainActor.assumeIsolated { self?.status = status }
        }
        server.onDevices = { [weak self] devices in
            MainActor.assumeIsolated { self?.devices = devices }
        }
        server.onTrustReset = { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isResettingTrust = false
                switch result {
                case .succeeded: self.trustResetError = nil
                case .failed(let message): self.trustResetError = message
                }
            }
        }

        observeSystemEvents()

        if !isAccessibilityTrusted {
            KeyInjector.requestTrust()
        }
        if enabled {
            start()
        }
    }

    func approve(_ device: PairedDevice) {
        guard canApproveDevices else { return }
        server.approve(device.id)
    }

    func forget(_ device: PairedDevice) {
        server.forget(device.id)
    }

    func forgetAllDevices() {
        guard !isResettingTrust else { return }
        isResettingTrust = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Forget all devices?"
            alert.informativeText = "All saved phone approvals will be removed and connected devices will lose access. Reconnect each phone and select Allow on this Mac to pair again. Your Mac identity and app settings will be kept."
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
            let forgetButton = alert.addButton(withTitle: "Forget All Devices")
            forgetButton.keyEquivalent = ""
            forgetButton.hasDestructiveAction = true
            NSApplication.shared.activate()
            guard alert.runModal() == .alertSecondButtonReturn else {
                self.isResettingTrust = false
                return
            }
            self.server.forgetAll()
        }
    }

    func showTrustResetError() {
        guard let trustResetError else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Pairing reset failed"
        alert.informativeText = trustResetError
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate()
        alert.runModal()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func showAbout() {
        NSApplication.shared.activate()
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    private func start() {
        // Keep the listener responsive; App Nap would otherwise stall it.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Listening for the remote"
        )
        server.start()
    }

    private func stop() {
        server.stop()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func observeSystemEvents() {
        // Sleep tears the listener down, so rebuild it rather than reporting a dead port.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                self.refreshAccessibility()
                self.server.stop()
                self.server.start()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The notification lands before the new grant takes effect.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.refreshAccessibility()
                }
            }
        }
    }

    private func refreshAccessibility() {
        isAccessibilityTrusted = KeyInjector.isTrusted
    }
}
