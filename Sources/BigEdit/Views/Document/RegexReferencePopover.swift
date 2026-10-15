import AppKit

/// A short reference card for the regular-expression syntax the find bar
/// understands (ICU, the engine behind `NSRegularExpression`), shown as a
/// popover beside the search field.
enum RegexReferencePopover {

    /// The rows of the card: syntax and what it means.
    static let entries: [(syntax: String, meaning: String)] = [
        (".", "any character except a line break (any character with Dot Matches Newline)"),
        ("\\d  \\w  \\s", "a digit, a word character, whitespace; \\D \\W \\S for the opposite"),
        ("[abc]  [^abc]  [a-z]", "one of these characters; not one of them; a range"),
        ("^  $", "start and end of a line"),
        ("\\b", "a word boundary"),
        ("*  +  ?", "zero or more, one or more, zero or one of what precedes"),
        ("{3}  {2,5}  {2,}", "exactly 3, between 2 and 5, at least 2"),
        ("*?  +?  ??", "the same, matching as little as possible"),
        ("(abc)", "a group, numbered from 1 — $1 in the replacement"),
        ("(?<name>abc)", "a named group — ${name} in the replacement"),
        ("(?:abc)", "a group that does not capture"),
        ("a|b", "either"),
        ("(?=abc)  (?!abc)", "followed by, not followed by (lookahead)"),
        ("(?<=abc)  (?<!abc)", "preceded by, not preceded by (lookbehind)"),
        ("\\.  \\(  \\\\", "a literal dot, parenthesis, backslash"),
        ("\\Q…\\E", "everything between taken literally"),
        ("\\t  \\n  \\r", "tab, line feed, carriage return"),
        ("\\u00E9  \\x{1F600}", "a character by code point"),
        ("\\p{L}  \\p{Nd}", "a Unicode letter, a decimal digit"),
        ("(?i)", "ignore case from here on, within the pattern"),
        ("$0", "in the replacement: the whole match")
    ]

    /// Shows the card anchored to `view`, in a popover that closes when
    /// the user clicks elsewhere.
    @discardableResult
    static func show(relativeTo view: NSView) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSViewController()
        controller.view = makeCard()
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        return popover
    }

    /// The card as a view: two columns, syntax in monospace.
    static func makeCard() -> NSView {
        let syntaxFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let meaningFont = NSFont.systemFont(ofSize: 11)
        let rowHeight: CGFloat = 18
        let padding: CGFloat = 14
        let gap: CGFloat = 12
        let syntaxWidth = entries.map { ($0.syntax as NSString).size(withAttributes: [.font: syntaxFont]).width }
            .max() ?? 100
        let meaningWidth: CGFloat = 360
        let height = padding * 2 + rowHeight * CGFloat(entries.count + 1)
        let width = padding * 2 + syntaxWidth + gap + meaningWidth
        let card = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let title = NSTextField(labelWithString: "Regular Expressions")
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.frame = NSRect(x: padding, y: height - padding - rowHeight, width: width - 2 * padding,
                             height: rowHeight)
        card.addSubview(title)

        for (index, entry) in entries.enumerated() {
            let y = height - padding - rowHeight * CGFloat(index + 2)
            let syntax = NSTextField(labelWithString: entry.syntax)
            syntax.font = syntaxFont
            syntax.frame = NSRect(x: padding, y: y, width: syntaxWidth, height: rowHeight)
            card.addSubview(syntax)
            let meaning = NSTextField(labelWithString: entry.meaning)
            meaning.font = meaningFont
            meaning.textColor = .secondaryLabelColor
            meaning.lineBreakMode = .byTruncatingTail
            meaning.frame = NSRect(x: padding + syntaxWidth + gap, y: y, width: meaningWidth, height: rowHeight)
            card.addSubview(meaning)
        }
        return card
    }
}
