import RemoteProtocol
import SwiftUI

struct ControlRow: View {
    let model: RemoteViewModel

    var body: some View {
        HStack(spacing: 14) {
            // The 2pt gaps let the background show through as the split line.
            tile {
                HStack(spacing: 2) {
                    ControlSegment(command: .left, symbol: "chevron.left", model: model)
                    ControlSegment(command: .right, symbol: "chevron.right", model: model)
                }
            }
            tile {
                ControlSegment(
                    command: .mid, symbol: "playpause.fill", model: model,
                    fill: Color(.systemGray4)
                )
            }
            tile {
                VStack(spacing: 2) {
                    ControlSegment(command: .up, symbol: "chevron.up", model: model)
                    ControlSegment(command: .down, symbol: "chevron.down", model: model)
                }
            }
        }
        .frame(height: 110)
        .opacity(model.isConnected ? 1 : 0.35)
        .animation(.easeOut(duration: 0.2), value: model.isConnected)
    }

    private func tile(@ViewBuilder content: () -> some View) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct ControlSegment: View {
    let command: Command
    let symbol: String
    let model: RemoteViewModel
    var fill = Color(.systemGray5)

    @State private var isPressed = false

    var body: some View {
        Rectangle()
            .fill(isPressed ? Color.accentColor : fill)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(isPressed ? Color.white : Color.primary)
            }
            .contentShape(.rect)
            // A drag gesture with no minimum distance gives us press and release
            // separately, which is what press-and-hold needs.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        model.press(command)
                    }
                    .onEnded { _ in
                        isPressed = false
                        model.release(command)
                    }
            )
            .disabled(!model.isConnected)
    }
}
