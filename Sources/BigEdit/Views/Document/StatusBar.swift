import AppKit

/// A thin footer under the document: caret position / selection on the left,
/// line endings and detected encoding on the right, and the language the
/// document is coloured as, which opens a menu to choose another.
final class StatusBar: NSView, NSMenuDelegate {

    static let preferredHeight: CGFloat = 22

    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")
    private let languageButton = NSPopUpButton(frame: .zero, pullsDown: true)

    /// The items of the language menu, built each time it opens.
    var languageMenuItems: (() -> [NSMenuItem])?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [leftLabel, rightLabel] {
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        rightLabel.alignment = .right
        configureLanguageButton()
    }

    private func configureLanguageButton() {
        languageButton.isBordered = false
        languageButton.controlSize = .small
        languageButton.font = NSFont.systemFont(ofSize: 11)
        languageButton.contentTintColor = .secondaryLabelColor
        languageButton.toolTip = "Syntax Coloring"
        languageButton.menu?.delegate = self
        languageButton.addItem(withTitle: "")
        addSubview(languageButton)
    }

    required init?(coder: NSCoder) {
        fatalError("StatusBar is created programmatically")
    }

    func setLeft(_ text: String) { leftLabel.stringValue = text }
    func setRight(_ text: String) { rightLabel.stringValue = text }

    func setLanguage(_ name: String) {
        languageButton.item(at: 0)?.title = name
        needsLayout = true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let title = languageButton.item(at: 0)?.title ?? ""
        menu.removeAllItems()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        languageMenuItems?().forEach(menu.addItem)
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 10
        let height: CGFloat = 14
        let y = (bounds.height - height) / 2
        languageButton.sizeToFit()
        let buttonWidth = languageButton.frame.width
        let buttonX = bounds.width - padding / 2 - buttonWidth
        languageButton.frame = NSRect(x: buttonX, y: (bounds.height - languageButton.frame.height) / 2,
                                      width: buttonWidth, height: languageButton.frame.height)
        let half = max(0, (buttonX - 3 * padding) / 2)
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
