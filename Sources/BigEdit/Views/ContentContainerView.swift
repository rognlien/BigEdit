import AppKit

/// Hosts the active document's `DocumentView` on the right side of the split
/// view. Swapping the mounted view is how switching documents works; the split
/// view's resizing flows into the mounted view via autoresizing.
final class ContentContainerView: NSView {

    private weak var activeView: NSView?

    /// Called with the dropped file URLs when files are dragged onto the area.
    var onOpenFiles: (([URL]) -> Void)?

    /// True while a valid file drag hovers, so we can draw a drop highlight.
    private var isDraggingOver = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("ContentContainerView is created programmatically")
    }

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
        if isDraggingOver {
            drawDropHighlight()
        }
    }

    private func drawDropHighlight() {
        let inset = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        path.lineWidth = 3
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    // MARK: - Drag & drop (open files)

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = !fileURLs(from: sender).isEmpty
        if accepted {
            isDraggingOver = true
            needsDisplay = true
        }
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDraggingOver = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDraggingOver = false
        needsDisplay = true
        let urls = fileURLs(from: sender)
        if urls.isEmpty {
            return false
        }
        onOpenFiles?(urls)
        return true
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
