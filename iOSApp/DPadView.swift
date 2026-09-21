import RemoteProtocol
import SwiftUI

struct DPadView: View {
    static let buttonSize: CGFloat = 100
    static let spacing: CGFloat = 14

    let model: RemoteViewModel

    var body: some View {
        Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
            GridRow {
                spacer
                DPadButton(command: .up, symbol: "chevron.up", model: model)
                spacer
            }
            GridRow {
                DPadButton(command: .left, symbol: "chevron.left", model: model)
                DPadButton(command: .mid, symbol: "playpause.fill", model: model)
                DPadButton(command: .right, symbol: "chevron.right", model: model)
            }
            GridRow {
                spacer
                DPadButton(command: .down, symbol: "chevron.down", model: model)
                spacer
            }
        }
        .opacity(model.isConnected ? 1 : 0.35)
        .animation(.easeOut(duration: 0.2), value: model.isConnected)
        .padding(.bottom, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var spacer: some View {
        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
    }
}

private struct DPadButton: View {
    let command: Command
    let symbol: String
    let model: RemoteViewModel

    @State private var isPressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(isPressed ? Color.accentColor : Color(.systemGray5))
            .frame(width: DPadView.buttonSize, height: DPadView.buttonSize)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(isPressed ? Color.white : Color.primary)
            }
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
