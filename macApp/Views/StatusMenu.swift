import AppKit
import SwiftUI

struct StatusMenu: View {
    @Bindable var model: ServerViewModel

    var body: some View {
        Text(model.statusText)
        if model.isEnabled {
            Text(model.clientText)
        }

        Divider()

        Toggle("Enabled", isOn: $model.isEnabled)
            .keyboardShortcut("e")

        if model.isEnabled {
            if !model.pendingDevices.isEmpty {
                Divider()
                Text("Waiting for approval")
                ForEach(model.pendingDevices) { device in
                    Button("Allow \(device.name) (\(device.shortID))") {
                        model.approve(device)
                    }
                }
            }

            if !model.approvedDevices.isEmpty {
                Divider()
                Menu("Paired Devices") {
                    ForEach(model.approvedDevices) { device in
                        Button("Remove \(device.name)\(device.isConnected ? " (connected)" : "")") {
                            model.forget(device)
                        }
                    }
                }
            }
        }

        if !model.isAccessibilityTrusted {
            Divider()
            Text("Accessibility access required")
            Button("Open Accessibility Settings…") {
                model.openAccessibilitySettings()
            }
        }

        Divider()

        Toggle("Launch at Login", isOn: $model.launchesAtLogin)
            .disabled(!model.canLaunchAtLogin)

        Divider()

        Button("About LazyRemote") {
            model.showAbout()
        }
        Button("Quit LazyRemote") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
