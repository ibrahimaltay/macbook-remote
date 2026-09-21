import CoreGraphics
import RemoteProtocol

/// Turns trackpad messages into real mouse events on this Mac.
/// Unchecked because `CGEventSource` is not marked `Sendable`, but is only read from here.
public struct PointerInjector: @unchecked Sendable {
    private let source: CGEventSource?

    public init() {
        source = CGEventSource(stateID: .hidSystemState)
    }

    public func post(_ event: PointerEvent) {
        switch event {
        case .move(let dx, let dy):
            move(dx: CGFloat(dx), dy: CGFloat(dy))
        case .click(let button, let count):
            click(button, count: count)
        }
    }

    /// Where the cursor is right now, which is the only way to turn a delta into the
    /// absolute position a mouse event needs.
    private var location: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func move(dx: CGFloat, dy: CGFloat) {
        let target = Self.clamp(CGPoint(x: location.x + dx, y: location.y + dy))
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left
        ) else { return }

        // Games and 3D tools read these fields rather than the cursor position.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.post(tap: .cghidEventTap)
    }

    private func click(_ button: MouseButton, count: UInt8) {
        let position = location
        let types: (down: CGEventType, up: CGEventType) = button == .right
            ? (.rightMouseDown, .rightMouseUp)
            : (.leftMouseDown, .leftMouseUp)
        let cgButton: CGMouseButton = button == .right ? .right : .left

        // A double click is two press/release pairs whose click state counts up.
        // Two plain clicks, however fast, stay two single clicks to AppKit.
        for state in 1...max(Int(count), 1) {
            for type in [types.down, types.up] {
                guard let event = CGEvent(
                    mouseEventSource: source,
                    mouseType: type,
                    mouseCursorPosition: position,
                    mouseButton: cgButton
                ) else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(state))
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// Keeps a fast flick from pushing the cursor off into nowhere. `CGDisplayBounds`
    /// already shares the top-left origin mouse events use, unlike `NSScreen.frame`.
    private static func clamp(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return point }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let screens = ids.prefix(Int(count)).map(CGDisplayBounds)

        if screens.contains(where: { $0.contains(point) }) { return point }

        let bounds = screens.reduce(CGRect.null) { $0.union($1) }
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
    }
}
