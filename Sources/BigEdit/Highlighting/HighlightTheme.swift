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

    /// Colours from Xcode's default light and dark themes, each with at
    /// least 4.5:1 contrast against the editor background in its appearance.
    static let standard = HighlightTheme(styles: [
        .punctuation: TokenStyle(color: SyntaxColor.punctuation),
        .comment: TokenStyle(color: SyntaxColor.comment),
        .string: TokenStyle(color: SyntaxColor.string),
        .number: TokenStyle(color: SyntaxColor.number),
        .literal: TokenStyle(color: SyntaxColor.keyword),
        .keyword: TokenStyle(color: SyntaxColor.keyword),
        .variable: TokenStyle(color: SyntaxColor.name),
        .key: TokenStyle(color: SyntaxColor.name),
        .tag: TokenStyle(color: SyntaxColor.name),
        .attributeName: TokenStyle(color: SyntaxColor.attribute),
        .attributeValue: TokenStyle(color: SyntaxColor.string),
        .declaration: TokenStyle(color: SyntaxColor.declaration),
        .anchor: TokenStyle(color: SyntaxColor.declaration),
        .heading: TokenStyle(color: SyntaxColor.name, isBold: true),
        .code: TokenStyle(color: SyntaxColor.attribute),
        .emphasis: TokenStyle(color: SyntaxColor.keyword),
        .strong: TokenStyle(isBold: true),
        .strikethrough: TokenStyle(isStruckThrough: true),
        .linkText: TokenStyle(color: SyntaxColor.linkText),
        .url: TokenStyle(color: SyntaxColor.url),
        .blockquote: TokenStyle(color: SyntaxColor.comment)
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

/// The syntax colours, each resolving to its light or dark variant from the
/// appearance it is drawn in.
enum SyntaxColor {
    static let punctuation = dynamic(light: 0x6E6E73, dark: 0x98989D)
    static let comment = dynamic(light: 0x5D6C79, dark: 0x8A99A6)
    static let string = dynamic(light: 0xC41A16, dark: 0xFC6A5D)
    static let number = dynamic(light: 0x1C00CF, dark: 0xD0BF69)
    static let keyword = dynamic(light: 0x9B2393, dark: 0xFC5FA3)
    static let name = dynamic(light: 0x0F68A0, dark: 0x41A1C0)
    static let attribute = dynamic(light: 0x815F03, dark: 0xBF8555)
    static let declaration = dynamic(light: 0x643820, dark: 0xFD8F3F)
    static let linkText = dynamic(light: 0x0B4F79, dark: 0x5DD8FF)
    static let url = dynamic(light: 0x0E0EFF, dark: 0x6E9BFF)

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
