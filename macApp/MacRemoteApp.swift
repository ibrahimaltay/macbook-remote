import SwiftUI

@main
struct MacRemoteApp: App {
    @State private var model = ServerViewModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(model: model)
        } label: {
            Image(systemName: model.iconName)
                .opacity(model.isEnabled ? 1 : 0.4)
        }
        .menuBarExtraStyle(.menu)
    }
}
