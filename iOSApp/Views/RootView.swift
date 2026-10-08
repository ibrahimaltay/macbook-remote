import SwiftUI

struct RootView: View {
    let model: RemoteViewModel

    @State private var confirmsForget = false
    @State private var inputBarHeight: CGFloat = 0
    @FocusState private var isTyping: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                TrackpadView(model: model)
                ControlRow(model: model)
                    .padding(.horizontal, 20)
            }
            .padding(.bottom, inputBarHeight)
            .overlay {
                if isTyping { scrim }
            }
            .animation(.easeOut(duration: 0.2), value: isTyping)
            // The keyboard covers the controls instead of squeezing them.
            .ignoresSafeArea(.keyboard, edges: .bottom)

            TextInputBar(model: model, isFocused: $isTyping)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    inputBarHeight = $0
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        // The controls reach the bottom edge, where a sideways drag would otherwise
        // flick iOS into another app mid-gesture.
        .defersSystemGestures(on: .bottom)
    }

    /// Fires on touch-down so a stray touch while typing only dismisses the
    /// keyboard and never reaches the trackpad or a key.
    private var scrim: some View {
        Color.black.opacity(0.4)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in isTyping = false })
            .transition(.opacity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            StatusLabel(model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Reconnect", systemImage: "arrow.clockwise") {
                    model.reconnect()
                }
                Button("Forget Mac", systemImage: "trash", role: .destructive) {
                    confirmsForget = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Connection options")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .confirmationDialog("Forget this Mac?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget Mac", role: .destructive) { model.forgetMac() }
        } message: {
            Text("The saved Mac identity will be removed. Only reconnect to a Mac you trust.")
        }
    }
}

struct StatusLabel: View {
    let model: RemoteViewModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isConnected ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
