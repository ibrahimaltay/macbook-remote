import RemoteProtocol
import SwiftUI
import UIKit

struct TrackpadView: View {
    let model: RemoteViewModel

    var body: some View {
        TrackpadSurface(model: model)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(alignment: .bottom) {
                // The right-click gesture is deliberately not the Mac's, so say so.
                Text("Tap to click · Two-finger double-tap to right-click")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(model.isConnected ? 1 : 0.35)
            .animation(.easeOut(duration: 0.2), value: model.isConnected)
            // Stops exactly where the paging edge strips begin, so neither steals
            // the other's touches.
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
    }
}

/// SwiftUI gestures cannot count fingers, so the pad has to be UIKit.
private struct TrackpadSurface: UIViewRepresentable {
    let model: RemoteViewModel

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator

        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan))
        pan.maximumNumberOfTouches = 1 // so a two-finger gesture never drags the cursor
        view.addGestureRecognizer(pan)

        let click = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.click))
        view.addGestureRecognizer(click)

        let rightClick = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.rightClick))
        rightClick.numberOfTouchesRequired = 2
        rightClick.numberOfTapsRequired = 2
        view.addGestureRecognizer(rightClick)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let model: RemoteViewModel
        private var lastClick: (time: TimeInterval, point: CGPoint)?

        private static let doubleClickInterval: TimeInterval = 0.4
        private static let doubleClickSlop: CGFloat = 40

        init(model: RemoteViewModel) {
            self.model = model
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            model.moveCursor(by: translation, velocity: recognizer.velocity(in: view))
        }

        @objc func click(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            let now = ProcessInfo.processInfo.systemUptime

            // Send the click now and let the count say it was the second one, the way a
            // real trackpad does. Waiting to see if a second tap lands would put a
            // quarter of a second on every single click.
            let isSecond = lastClick.map {
                now - $0.time < Self.doubleClickInterval
                    && hypot(point.x - $0.point.x, point.y - $0.point.y) < Self.doubleClickSlop
            } ?? false

            lastClick = isSecond ? nil : (now, point)
            model.click(.left, count: isSecond ? 2 : 1)
        }

        @objc func rightClick(_ recognizer: UITapGestureRecognizer) {
            model.click(.right, count: 1)
        }
    }
}
