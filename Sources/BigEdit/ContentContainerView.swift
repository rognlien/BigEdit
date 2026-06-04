import AppKit

/// Hosts the active document's `DocumentView` on the right side of the split
/// view. Swapping the mounted view is how switching documents works; the split
/// view's resizing flows into the mounted view via autoresizing.
final class ContentContainerView: NSView {

    private weak var activeView: NSView?

    /// Mounts `view` as the sole content, removing whatever was there before.
    /// Pass `nil` to show the empty state (no document open).
    func setActiveView(_ view: NSView?) {
        if activeView === view {
            return
        }
        activeView?.removeFromSuperview()
        activeView = view
        if let view {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        if activeView == nil {
            drawEmptyState()
        }
    }

    /// A muted hint shown when no document is open.
    private func drawEmptyState() {
        let message = "No document open — press ⌘O to open a file"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let size = message.size(withAttributes: attributes)
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        message.draw(at: origin, withAttributes: attributes)
    }
}
