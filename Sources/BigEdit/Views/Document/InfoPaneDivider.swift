import AppKit

/// A thin draggable strip on the info pane's leading edge, used to resize it.
/// It draws nothing (the info pane draws its own separator line) and shows the
/// horizontal-resize cursor; drags are reported via `onDrag`.
final class InfoPaneDivider: NSView {

    var onDrag: ((NSPoint) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        onDrag?(event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow)
    }
}
