import SwiftUI

struct TextInputBar: View {
    let model: RemoteViewModel
    @FocusState.Binding var isFocused: Bool
    var isSpotlight = false

    @State private var draft = ""
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(text: $draft, prompt: prompt, axis: .vertical) {}
                .lineLimit(1...5)
                .focused($isFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    Color(.systemGray5),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )

            backspaceButton

            enterButton

            if isFocused {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(canSend ? Color.accentColor : Color(.systemGray4)))
                }
                .disabled(!canSend)
            }
        }
        // Floats above the field so a status change never resizes the controls.
        .overlay(alignment: .topTrailing) {
            confirmation
                .alignmentGuide(.top) { $0[.bottom] + 8 }
        }
        .animation(.easeOut(duration: 0.2), value: isFocused)
        .animation(.easeOut(duration: 0.2), value: canSend)
        .animation(.easeOut(duration: 0.2), value: model.textStatus)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onChange(of: isFocused) { _, focused in
            if !focused { stopDeleting() }
        }
        .onChange(of: model.textStatus) { _, status in
            if status == .sent { draft = "" }
        }
        .onDisappear(perform: stopDeleting)
    }

    private var prompt: Text {
        isSpotlight
            ? Text("\(Image(systemName: "magnifyingglass")) Spotlight Search")
            : Text("Type to send…")
    }

    private func send() {
        model.send(text: draft)
        isFocused = false
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

    private var enterButton: some View {
        Button(action: { model.tap(.enter) }) {
            Image(systemName: "return")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color(.systemGray5)))
        }
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
        model.isConnected && model.textStatus != .sending
            && draft.utf8.count <= 4096
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var confirmation: some View {
        switch model.textStatus {
        case .failed:
            label("Not confirmed", symbol: "exclamationmark.triangle", tint: .red)
        case .sent, .sending, nil:
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
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .transition(.opacity)
    }
}
