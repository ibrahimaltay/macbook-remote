import SwiftUI

/// AssistiveTouch-style button that opens the D-pad. Positions are in the "root"
/// coordinate space, which this layer shares with `RootView`.
struct FloatingRemoteButton: View {
    let model: RemoteViewModel
    @Binding var isDocked: Bool
    /// Center of the header slot.
    let dock: CGPoint
    let headerBottom: CGFloat
    let inputBarHeight: CGFloat
    let open: () -> Void

    // Fractions of the layer size, so the spot survives size and device changes.
    @AppStorage("remoteFab.x") private var fractionX = 357.0 / 393
    @AppStorage("remoteFab.y") private var fractionY = 0.66
    @State private var dragOrigin: CGPoint?
    @State private var dragPosition: CGPoint?
    @State private var isNearDock = false

    private static let floatingSize: CGFloat = 58
    private static let edgeInset: CGFloat = 41

    var body: some View {
        GeometryReader { geo in
            let docked = isDocked && dragPosition == nil
            let center = dragPosition ?? (docked ? dock : snapped(
                CGPoint(x: fractionX * geo.size.width, y: fractionY * geo.size.height), in: geo.size
            ))

            if dragPosition != nil {
                dockTarget.position(dock)
            }
            button(docked: docked)
                .position(center)
                .gesture(drag(from: center, in: geo.size))
        }
        .ignoresSafeArea(.keyboard)
    }

    private func button(docked: Bool) -> some View {
        let size = docked ? 32 : Self.floatingSize
        return Image(systemName: "appletvremote.gen4")
            .font(.system(size: docked ? 22 : 28))
            .foregroundStyle(docked ? Color.accentColor : Color.primary)
            .frame(width: size, height: size)
            .background {
                if !docked {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Color(.systemGray6).opacity(0.86)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
                }
            }
            .contentShape(Circle())
            .opacity(model.isConnected ? 1 : 0.5)
            .accessibilityLabel("Remote")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if model.isConnected { open() } }
    }

    private var dockTarget: some View {
        Circle()
            .strokeBorder(
                isNearDock ? Color.accentColor : Color.secondary.opacity(0.6),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
            .background(Circle().fill(isNearDock ? Color.accentColor.opacity(0.18) : .clear))
            .frame(width: 36, height: 36)
            .allowsHitTesting(false)
    }

    /// Under 5pt of travel is a tap; anything more drags 1:1, then docks or snaps to an edge.
    private func drag(from center: CGPoint, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
            .onChanged { value in
                let t = value.translation
                if dragOrigin == nil {
                    guard hypot(t.width, t.height) >= 5 else { return }
                    dragOrigin = center
                }
                guard let origin = dragOrigin else { return }
                let radius = Self.floatingSize / 2
                let p = CGPoint(
                    x: min(max(origin.x + t.width, radius), size.width - radius),
                    y: min(max(origin.y + t.height, radius), size.height - radius)
                )
                dragPosition = p
                isNearDock = p.y < headerBottom || hypot(p.x - dock.x, p.y - dock.y) < 60
            }
            .onEnded { _ in
                guard let p = dragPosition else {
                    if model.isConnected { open() }
                    return
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if isNearDock {
                        isDocked = true
                    } else {
                        isDocked = false
                        let s = snapped(p, in: size)
                        fractionX = s.x / size.width
                        fractionY = s.y / size.height
                    }
                    dragOrigin = nil
                    dragPosition = nil
                    isNearDock = false
                }
            }
    }

    /// Nearest side edge, between the header and the input bar.
    private func snapped(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let inset = Self.edgeInset
        return CGPoint(
            x: p.x < size.width / 2 ? inset : size.width - inset,
            y: min(max(p.y, headerBottom + inset), size.height - inputBarHeight - inset)
        )
    }
}
