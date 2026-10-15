import AppKit

/// A split view that reports when the user has dragged its divider, so that
/// position can be told apart from ones set by layout.
final class SidebarSplitView: NSSplitView {

    /// Called after the user lets go of the divider.
    var onDividerDragged: (() -> Void)?
    private(set) var isDraggingDivider = false
    private var isSettingSidebarWidth = false

    override func mouseDown(with event: NSEvent) {
        isDraggingDivider = true
        super.mouseDown(with: event)
        isDraggingDivider = false
        onDividerDragged?()
    }

    /// Moves the divider without re-entering when the move itself triggers
    /// another resize notification.
    func setSidebarWidth(_ width: CGFloat) {
        if !isSettingSidebarWidth {
            isSettingSidebarWidth = true
            setPosition(width, ofDividerAt: 0)
            isSettingSidebarWidth = false
        }
    }
}
