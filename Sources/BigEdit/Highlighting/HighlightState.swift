import Foundation

/// The carried syntax state at a row boundary, so multi-row constructs colour
/// every row, not just the one where they open. Its meaning is interpreted by
/// the active highlighter (e.g. `.blockComment` is `/* */` for JSON and
/// `<!-- -->` for XML).
enum HighlightState: Equatable {
    case normal
    case blockComment
    case fencedCode
    case blockScalar(indent: Int)
    case singleQuotedString
    case doubleQuotedString
    case hereDocument(delimiter: String, stripsTabs: Bool, expands: Bool)
    case dollarQuotedString(delimiter: String)
}
