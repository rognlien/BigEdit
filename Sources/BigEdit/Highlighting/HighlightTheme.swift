import AppKit

/// How one token kind is drawn. Every field is optional so a kind can change
/// the colour, the weight, or the decoration on its own, and an overlapping
/// token only overrides the attributes it sets.
struct TokenStyle {
    var color: NSColor?
    var isBold = false
    var isStruckThrough = false
}

/// Maps token kinds to their appearance and styles a row from its tokens.
struct HighlightTheme {

    static let standard = HighlightTheme(styles: [
        .punctuation: TokenStyle(color: .secondaryLabelColor),
        .comment: TokenStyle(color: .systemGreen),
        .string: TokenStyle(color: .systemRed),
        .number: TokenStyle(color: .systemPurple),
        .literal: TokenStyle(color: .systemTeal),
        .key: TokenStyle(color: .systemBlue),
        .tag: TokenStyle(color: .systemBlue),
        .attributeName: TokenStyle(color: .systemPurple),
        .attributeValue: TokenStyle(color: .systemRed),
        .declaration: TokenStyle(color: .systemTeal),
        .anchor: TokenStyle(color: .systemOrange),
        .heading: TokenStyle(color: .systemBlue, isBold: true),
        .code: TokenStyle(color: .systemBrown),
        .emphasis: TokenStyle(color: .systemOrange),
        .strong: TokenStyle(isBold: true),
        .strikethrough: TokenStyle(isStruckThrough: true),
        .linkText: TokenStyle(color: .systemTeal),
        .url: TokenStyle(color: .systemPurple),
        .blockquote: TokenStyle(color: .secondaryLabelColor)
    ])

    let styles: [TokenKind: TokenStyle]

    func style(for kind: TokenKind) -> TokenStyle {
        return styles[kind] ?? TokenStyle()
    }

    /// `text` in the default colour with each token's style layered on in order.
    func attributedRow(_ text: String, tokens: [Token], font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString.plainRow(text, font: font)
        var boldFont: NSFont?
        for token in tokens {
            let style = style(for: token.kind)
            if let color = style.color {
                result.setColor(color, in: token.range)
            }
            if style.isBold {
                let bold = boldFont ?? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                boldFont = bold
                result.setFont(bold, in: token.range)
            }
            if style.isStruckThrough {
                result.setStrikethrough(in: token.range)
            }
        }
        return result
    }
}
