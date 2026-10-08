import RemoteClientCore
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
                Text("Tap to click · Two fingers to scroll · Two-finger double-tap to right-click")
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
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
    }
}

/// SwiftUI gestures cannot count fingers, so the pad has to be UIKit.
private struct TrackpadSurface: UIViewRepresentable {
    let model: RemoteViewModel

    func makeUIView(context: Context) -> UIView {
        let view = TouchDownView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        // A real trackpad stops coasting the moment a finger lands.
        view.onTouchDown = { coordinator.stopMomentum() }

        // One recognizer for both, so a second finger landing mid-drag can switch to scrolling.
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan))
        pan.maximumNumberOfTouches = 2
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

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stopMomentum()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    @MainActor
    final class Coordinator: NSObject {
        private enum PanMode {
            case cursor
            case scroll
            /// Scrolling ended while one finger stays down; it must not drag the cursor.
            case spent
        }

        private let model: RemoteViewModel
        private var lastClick: (time: TimeInterval, point: CGPoint)?
        private var panMode = PanMode.cursor
        private var scrollVelocity = CGPoint.zero
        private var momentum: ScrollMomentum?
        private var displayLink: CADisplayLink?

        private static let doubleClickInterval: TimeInterval = 0.4
        private static let doubleClickSlop: CGFloat = 40

        init(model: RemoteViewModel) {
            self.model = model
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            let velocity = recognizer.velocity(in: view)

            switch recognizer.state {
            case .began, .changed:
                let fingers = recognizer.numberOfTouches
                switch panMode {
                case .cursor where fingers >= 2:
                    // The centroid jumps when a finger lands, so this frame's delta is dropped.
                    panMode = .scroll
                    scrollVelocity = .zero
                    model.scroll(by: .zero, velocity: .zero, phase: .began)
                case .cursor:
                    model.moveCursor(by: translation, velocity: velocity)
                case .scroll where fingers < 2:
                    // Fingers rarely lift together; treat the first lift as the release.
                    panMode = .spent
                    endScroll(coasting: true)
                case .scroll:
                    scrollVelocity = velocity
                    model.scroll(by: translation, velocity: velocity, phase: .changed)
                case .spent:
                    break
                }
            case .ended, .cancelled, .failed:
                if panMode == .scroll {
                    if recognizer.state == .ended { scrollVelocity = velocity }
                    endScroll(coasting: recognizer.state == .ended)
                }
                panMode = .cursor
            default:
                break
            }
        }

        private func endScroll(coasting: Bool) {
            model.scroll(by: .zero, velocity: .zero, phase: .ended)
            guard coasting, let coast = model.momentum(afterReleaseAt: scrollVelocity) else { return }
            momentum = coast
            model.coast(dx: 0, dy: 0, phase: .momentumBegan)
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard var coast = momentum else { return }
            let step = coast.step(dt: link.targetTimestamp - link.timestamp)
            momentum = coast
            model.coast(dx: step.dx, dy: step.dy, phase: .momentum)
            if coast.isFinished { stopMomentum() }
        }

        func stopMomentum() {
            guard let displayLink else { return }
            displayLink.invalidate()
            self.displayLink = nil
            momentum = nil
            model.coast(dx: 0, dy: 0, phase: .momentumEnded)
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

private final class TouchDownView: UIView {
    var onTouchDown: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouchDown?()
        super.touchesBegan(touches, with: event)
    }
}
