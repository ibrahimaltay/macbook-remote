import RemoteProtocol
import SwiftUI

struct DPadOverlay: View {
    let model: RemoteViewModel
    @Binding var isPresented: Bool

    @State private var isShown = false

    var body: some View {
        ZStack {
            // Touch-down, like the typing scrim, so a stray touch only closes the pad.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.6))
                .ignoresSafeArea()
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in close() })
                .accessibilityHidden(true)

            VStack(spacing: 28) {
                pad
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color(.systemGray4).opacity(0.8), in: Circle())
                }
                .accessibilityLabel("Close")
            }
            .scaleEffect(isShown ? 1 : 0.92)
        }
        // The backdrop is dark in both appearances, so the pad always uses dark colors.
        .environment(\.colorScheme, .dark)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) { isShown = true }
        }
    }

    private var pad: some View {
        ZStack {
            // Swallows touches in the gaps so they don't reach the backdrop and close the pad.
            Color.clear.contentShape(Circle())
            segment(.up, "chevron.up", "Up", degrees: -90)
            segment(.right, "chevron.right", "Right", degrees: 0)
            segment(.down, "chevron.down", "Down", degrees: 90)
            segment(.left, "chevron.left", "Left", degrees: 180)
            Circle()
                .fill(Color(red: 10 / 255, green: 10 / 255, blue: 12 / 255).opacity(0.85))
                .frame(width: 130, height: 130)
            DPadKey(
                shape: Circle(), size: 116, command: .mid, symbol: "playpause.fill",
                label: "Play/Pause", fill: Color(.systemGray3), iconSize: 32, model: model
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 300, height: 300)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.5), radius: 25, y: 20)
        // Dim as one layer, or the gaps show through the center button.
        .compositingGroup()
        .opacity(model.isConnected ? 1 : 0.35)
    }

    private func segment(_ command: Command, _ symbol: String, _ label: String, degrees: Double) -> some View {
        let angle = Angle.degrees(degrees)
        return DPadKey(
            shape: Wedge(angle: angle), size: 300, command: command, symbol: symbol, label: label,
            fill: Color(.systemGray4).opacity(0.92),
            iconOffset: CGSize(width: 102 * cos(angle.radians), height: 102 * sin(angle.radians)),
            model: model
        )
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { isPresented = false }
    }
}

/// A quarter of the pad centered on `angle`, pushed outward so neighbors are 5pt apart.
private struct Wedge: Shape {
    let angle: Angle

    func path(in rect: CGRect) -> Path {
        // Shifting along the bisector by d moves each straight edge d/√2 away from its neighbor's.
        let shift = 2.5 * sqrt(2)
        let tip = CGPoint(
            x: rect.midX + shift * cos(angle.radians),
            y: rect.midY + shift * sin(angle.radians)
        )
        var path = Path()
        path.move(to: tip)
        path.addRelativeArc(
            center: tip, radius: min(rect.width, rect.height) / 2,
            startAngle: angle - .degrees(45), delta: .degrees(90)
        )
        path.closeSubpath()
        return path
    }
}

/// Press on touch-down, release on lift or when the finger leaves the shape;
/// the Mac repeats while held, same as the old control row.
private struct DPadKey<S: Shape>: View {
    let shape: S
    let size: CGFloat
    let command: Command
    let symbol: String
    let label: String
    let fill: Color
    var iconOffset = CGSize.zero
    var iconSize: CGFloat = 26
    let model: RemoteViewModel

    @State private var isPressed = false
    @State private var hasLeft = false
    // Resets on cancellation too, where onEnded never fires and a key would stay held.
    @GestureState private var isTouching = false

    var body: some View {
        shape
            .fill(isPressed ? Color.accentColor : fill)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(iconOffset)
            }
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .frame(width: size, height: size)
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTouching) { _, touching, _ in touching = true }
                    .onChanged { value in
                        guard !hasLeft else { return }
                        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
                        if !shape.path(in: bounds).contains(value.location) {
                            hasLeft = true
                            release()
                        } else if !isPressed, model.isConnected {
                            isPressed = true
                            model.press(command)
                        }
                    }
            )
            .onChange(of: isTouching) { _, touching in
                guard !touching else { return }
                hasLeft = false
                release()
            }
            .onDisappear(perform: release)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.tap(command) }
    }

    private func release() {
        guard isPressed else { return }
        isPressed = false
        model.release(command)
    }
}
