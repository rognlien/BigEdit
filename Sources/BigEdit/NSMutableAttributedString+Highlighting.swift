import AppKit

/// The attribute operations every syntax highlighter performs on a row.
extension NSMutableAttributedString {

    /// A row in the default text colour, ready to be coloured token by token.
    static func plainRow(_ text: String, font: NSFont) -> NSMutableAttributedString {
        return NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.textColor]
        )
    }

    /// Colours `range`, given in UTF-16 offsets. An empty range is a no-op.
    func setColor(_ color: NSColor, in range: Range<Int>) {
        addHighlightAttribute(.foregroundColor, value: color, in: range)
    }

    /// Sets the font over `range`, given in UTF-16 offsets. An empty range is a no-op.
    func setFont(_ font: NSFont, in range: Range<Int>) {
        addHighlightAttribute(.font, value: font, in: range)
    }

    private func addHighlightAttribute(_ key: NSAttributedString.Key, value: Any, in range: Range<Int>) {
        if !range.isEmpty {
            addAttribute(key, value: value, range: NSRange(location: range.lowerBound, length: range.count))
        }
    }
}
