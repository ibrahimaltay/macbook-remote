import SwiftUI

struct TextPageView: View {
    let model: RemoteViewModel
    let isActive: Bool

    @State private var draft = ""
    @State private var repeatTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)

            confirmation

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Type to send…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(
                        Color(.systemGray5),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )

                backspaceButton

                Button(action: { model.send(text: draft) }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(canSend ? Color.accentColor : Color(.systemGray4)))
                }
                .disabled(!canSend)
            }
        }
        .animation(.easeOut(duration: 0.2), value: canSend)
        .animation(.easeOut(duration: 0.2), value: model.textStatus)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onChange(of: isActive) { _, active in
            isFocused = active
            if !active { stopDeleting() }
        }
        .onChange(of: model.textStatus) { _, status in
            if status == .sent { draft = "" }
        }
        .onDisappear(perform: stopDeleting)
    }

    /// Deletes on the Mac, not in the draft above it — the system keyboard already
    /// has its own backspace for that.
    private var backspaceButton: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isDeleting ? Color.white : Color.primary)
            .frame(width: 42, height: 42)
            .background(Circle().fill(isDeleting ? Color.accentColor : Color(.systemGray5)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in startDeleting() }
                    .onEnded { _ in stopDeleting() }
            )
            .disabled(!model.isConnected)
    }

    private var isDeleting: Bool { repeatTask != nil }

    private func startDeleting() {
        guard repeatTask == nil else { return }
        model.tap(.backspace)

        repeatTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            while !Task.isCancelled {
                model.tap(.backspace, feedback: false)
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func stopDeleting() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    private var canSend: Bool {
        model.isConnected && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var confirmation: some View {
        switch model.textStatus {
        case .sent:
            label("Sent", symbol: "checkmark", tint: .secondary)
        case .failed:
            label("Not sent", symbol: "exclamationmark.triangle", tint: .red)
        case .sending, nil:
            EmptyView()
        }
    }

    private func label(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .transition(.opacity)
    }
}
