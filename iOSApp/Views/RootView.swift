import SwiftUI

struct RootView: View {
    let model: RemoteViewModel

    @State private var confirmsForget = false
    @State private var inputBarHeight: CGFloat = 0
    // shortcut: the phone can't see Spotlight, so this assumes it closes with the keyboard.
    @State private var isSpotlight = false
    @FocusState private var isTyping: Bool
    @AppStorage("remoteFab.docked") private var isRemoteDocked = false
    @State private var isDPadOpen = false
    @State private var dockCenter = CGPoint.zero
    @State private var headerBottom: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("root")).maxY } action: {
                        headerBottom = $0
                    }
                TrackpadView(model: model)
            }
            .padding(.bottom, inputBarHeight)
            .overlay {
                if isTyping { scrim }
            }
            .animation(.easeOut(duration: 0.2), value: isTyping)
            // The keyboard covers the controls instead of squeezing them.
            .ignoresSafeArea(.keyboard, edges: .bottom)

            TextInputBar(model: model, isFocused: $isTyping, isSpotlight: isSpotlight)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    inputBarHeight = $0
                }

            // Spotlight always focuses the text field, so this hides it then too.
            if !isTyping {
                FloatingRemoteButton(
                    model: model, isDocked: $isRemoteDocked, dock: dockCenter,
                    headerBottom: headerBottom, inputBarHeight: inputBarHeight
                ) {
                    withAnimation(.easeOut(duration: 0.2)) { isDPadOpen = true }
                }
            }

            if isDPadOpen {
                DPadOverlay(model: model, isPresented: $isDPadOpen)
                    .transition(.opacity)
            }
        }
        .onChange(of: isTyping) { _, typing in
            if !typing { isSpotlight = false }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named("root"))
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
            if isRemoteDocked {
                // FloatingRemoteButton draws itself over this slot.
                Color.clear.frame(width: 32, height: 32)
            }
            Button {
                model.tap(.spotlight)
                isSpotlight = true
                isTyping = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 32, height: 32)
            }
            .disabled(!model.isConnected)
            .accessibilityLabel("Spotlight Search")
            .onGeometryChange(for: CGPoint.self) {
                let frame = $0.frame(in: .named("root"))
                // One 32pt slot plus the 12pt stack spacing to the left.
                return CGPoint(x: frame.minX - 12 - 16, y: frame.midY)
            } action: {
                dockCenter = $0
            }
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
