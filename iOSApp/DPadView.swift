import RemoteProtocol
import SwiftUI

struct DPadView: View {
    let model: RemoteViewModel

    var body: some View {
        VStack(spacing: 0) {
            StatusLabel(model: model)

            Spacer()

            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
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
            .padding(.bottom, 32)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var spacer: some View {
        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
    }
}

private struct StatusLabel: View {
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

private struct DPadButton: View {
    let command: Command
    let symbol: String
    let model: RemoteViewModel

    @State private var isPressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(isPressed ? Color.accentColor : Color(.secondarySystemBackground))
            .frame(width: 100, height: 100)
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
