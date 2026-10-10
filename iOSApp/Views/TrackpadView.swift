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

        // One recognizer for all finger counts, so fingers landing mid-gesture can switch modes.
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan))
        pan.maximumNumberOfTouches = 3
        pan.delegate = coordinator
        view.addGestureRecognizer(pan)

        let drag = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.drag))
        drag.minimumPressDuration = model.gestures.dragHoldSeconds
        drag.allowableMovement = 10
        drag.delegate = coordinator
        view.addGestureRecognizer(drag)

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
        coordinator.endDrag()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private enum PanMode {
            case cursor
            case scroll
            case swipe
            /// Scrolling or a swipe ended while fingers stay down; they must not drag the cursor.
            case spent
        }

        private let model: RemoteViewModel
        private var lastClick: (time: TimeInterval, point: CGPoint, count: UInt8)?
        private var panMode = PanMode.cursor
        private var swipeTravel = CGPoint.zero
        private var isDragging = false
        private var scrollVelocity = CGPoint.zero
        private var momentum: ScrollMomentum?
        private var displayLink: CADisplayLink?

        private static let multiClickInterval: TimeInterval = 0.4
        private static let multiClickSlop: CGFloat = 40

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
                // While dragging, extra fingers must not turn the drag into a scroll or swipe.
                let fingers = isDragging ? 1 : recognizer.numberOfTouches
                if fingers >= 3, panMode == .cursor || panMode == .scroll {
                    if panMode == .scroll { endScroll(coasting: false) }
                    panMode = .swipe
                    swipeTravel = .zero
                    return
                }
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
                case .swipe:
                    swipeTravel.x += translation.x
                    swipeTravel.y += translation.y
                    if let direction = swipeDirection() {
                        panMode = .spent
                        model.swipe(direction)
                    }
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

        /// Nil until the fingers have travelled far enough along one axis.
        private func swipeDirection() -> SwipeDirection? {
            let (x, y) = (swipeTravel.x, swipeTravel.y)
            guard max(abs(x), abs(y)) >= model.gestures.swipeDistance else { return nil }
            if abs(x) > abs(y) { return x < 0 ? .left : .right }
            return y < 0 ? .up : .down
        }

        @objc func drag(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                isDragging = true
                model.beginDrag()
            case .ended, .cancelled, .failed:
                endDrag()
            default:
                break
            }
        }

        func endDrag() {
            guard isDragging else { return }
            isDragging = false
            model.endDrag()
        }

        /// The pan keeps moving the cursor during a drag; taps stay exclusive so a drop never clicks.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            (gestureRecognizer is UILongPressGestureRecognizer && other is UIPanGestureRecognizer)
                || (gestureRecognizer is UIPanGestureRecognizer && other is UILongPressGestureRecognizer)
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

            // Send the click now and let the count say it was the second or third one, the
            // way a real trackpad does. Waiting to see if another tap lands would put a
            // quarter of a second on every single click.
            let count: UInt8 = lastClick.flatMap {
                now - $0.time < Self.multiClickInterval
                    && hypot(point.x - $0.point.x, point.y - $0.point.y) < Self.multiClickSlop
                    && $0.count < 3 ? $0.count + 1 : nil
            } ?? 1

            lastClick = (now, point, count)
            model.click(.left, count: count)
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
