import AppKit

/// A thin footer under the document: caret position / selection on the left,
/// line endings and detected encoding on the right.
final class StatusBar: NSView {

    static let preferredHeight: CGFloat = 22

    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [leftLabel, rightLabel] {
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        rightLabel.alignment = .right
    }

    required init?(coder: NSCoder) {
        fatalError("StatusBar is created programmatically")
    }

    func setLeft(_ text: String) { leftLabel.stringValue = text }
    func setRight(_ text: String) { rightLabel.stringValue = text }

    override func layout() {
        super.layout()
        let padding: CGFloat = 10
        let height: CGFloat = 14
        let y = (bounds.height - height) / 2
        let half = max(0, (bounds.width - 3 * padding) / 2)
        leftLabel.frame = NSRect(x: padding, y: y, width: half, height: height)
        rightLabel.frame = NSRect(x: padding + half + padding, y: y, width: half, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        line.line(to: NSPoint(x: bounds.width, y: bounds.height - 0.5))
        line.stroke()
    }
}
