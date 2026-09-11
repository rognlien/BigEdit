import AppKit

/// A right-side inspector that shows the open document's stats. Values are
/// updated externally via the setters as indexing and the stats scan publish
/// progress.
final class InfoPane: NSView {

    static let preferredWidth: CGFloat = 240

    private let titleLabel = NSTextField(labelWithString: "Info")

    private let nameRow = InfoRow(title: "Name")
    private let pathRow = InfoRow(title: "Path")
    private let typeRow = InfoRow(title: "Type")
    private let sizeRow = InfoRow(title: "Size")
    private let linesRow = InfoRow(title: "Lines")
    private let wordsRow = InfoRow(title: "Words")
    private let charactersRow = InfoRow(title: "Characters")

    private var rows: [InfoRow] {
        [nameRow, pathRow, typeRow, sizeRow, linesRow, wordsRow, charactersRow]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        addSubview(titleLabel)
        for row in rows {
            addSubview(row.labelField)
            addSubview(row.valueField)
        }
        layoutChildren()
    }

    required init?(coder: NSCoder) {
        fatalError("InfoPane is created programmatically")
    }

    // MARK: - Setters

    func setName(_ value: String) { nameRow.set(value) }
    func setPath(_ value: String) { pathRow.set(value) }
    func setType(_ value: String) { typeRow.set(value) }
    func setSize(_ value: String) { sizeRow.set(value) }
    func setLines(_ value: String) { linesRow.set(value) }
    func setWords(_ value: String) { wordsRow.set(value) }
    func setCharacters(_ value: String) { charactersRow.set(value) }

    func clear() {
        for row in rows {
            row.set("—")
        }
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChildren()
    }

    private func layoutChildren() {
        let horizontalPadding: CGFloat = 16
        let topInset: CGFloat = 18
        let titleHeight: CGFloat = 18
        let labelHeight: CGFloat = 14
        let valueHeight: CGFloat = 18
        let labelToValueGap: CGFloat = 2
        let rowSpacing: CGFloat = 14
        let valueWidth = max(0, bounds.width - 2 * horizontalPadding)

        // Title sits at the top of the pane (the view is not flipped).
        let titleY = bounds.height - topInset - titleHeight
        titleLabel.frame = NSRect(
            x: horizontalPadding, y: titleY,
            width: valueWidth, height: titleHeight
        )

        var rowTop = titleY - rowSpacing
        for row in rows {
            let labelY = rowTop - labelHeight
            let valueY = labelY - labelToValueGap - valueHeight
            row.labelField.frame = NSRect(
                x: horizontalPadding, y: labelY,
                width: valueWidth, height: labelHeight
            )
            row.valueField.frame = NSRect(
                x: horizontalPadding, y: valueY,
                width: valueWidth, height: valueHeight
            )
            rowTop = valueY - rowSpacing
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // Left edge separator marks the boundary with the document area.
        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: 0.5, y: 0))
        separator.line(to: NSPoint(x: 0.5, y: bounds.height))
        separator.stroke()
    }
}

/// One key / value pair shown in the info pane.
final class InfoRow {
    let labelField: NSTextField
    let valueField: NSTextField

    init(title: String) {
        labelField = NSTextField(labelWithString: title)
        labelField.font = NSFont.systemFont(ofSize: 11)
        labelField.textColor = .secondaryLabelColor

        valueField = NSTextField(labelWithString: "—")
        valueField.font = NSFont.systemFont(ofSize: 13)
        valueField.textColor = .labelColor
        valueField.lineBreakMode = .byTruncatingMiddle
        valueField.isSelectable = true
    }

    func set(_ value: String) {
        valueField.stringValue = value
    }
}
