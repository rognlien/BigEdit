import Foundation

/// What a run of characters in a row means to the active highlighter. The
/// kinds are shared across languages so one theme can style them all; each
/// language uses the kinds that fit it and ignores the rest.
enum TokenKind {
    case punctuation
    case comment
    case string
    case number
    case literal
    case key
    case tag
    case attributeName
    case attributeValue
    case declaration
    case anchor
    case heading
    case code
    case emphasis
    case strong
    case strikethrough
    case linkText
    case url
    case blockquote
}

/// One styled run in a row. `range` is in UTF-16 offsets. Tokens may overlap:
/// they are applied in order, so where two overlap the later one's attributes
/// win for the attributes it sets.
struct Token: Equatable {
    let kind: TokenKind
    let range: Range<Int>

    /// The same token moved `offset` characters to the right.
    func shifted(by offset: Int) -> Token {
        return Token(kind: kind, range: (range.lowerBound + offset)..<(range.upperBound + offset))
    }
}

extension Array where Element == Token {
    /// Appends a token, dropping empty ranges so lists stay free of no-ops.
    mutating func add(_ kind: TokenKind, _ range: Range<Int>) {
        if !range.isEmpty {
            append(Token(kind: kind, range: range))
        }
    }
}
