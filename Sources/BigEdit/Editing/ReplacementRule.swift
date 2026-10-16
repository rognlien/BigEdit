import Foundation

/// A deferred find-and-replace rule: every occurrence of `pattern` is shown —
/// and eventually written — as `replacement`.
///
/// Both sides are newline-free. That restriction is what keeps Stage 1 simple:
/// the document's line count and visual-row structure are unchanged, so only
/// line *content* differs and the whole scroll/index model stays valid.
struct ReplacementRule: Equatable {

    let pattern: String
    let replacement: String

    /// The encoding both sides are written in — the document's own.
    let encoding: TextEncoding

    /// The bytes searched for and spliced in, in `encoding`.
    let patternBytes: [UInt8]
    let replacementBytes: [UInt8]

    /// Creates a rule, or returns `nil` if it is not valid for Stage 1: the
    /// pattern must be non-empty, neither side may contain a newline, and
    /// both must be representable in `encoding`.
    init?(pattern: String, replacement: String, encoding: TextEncoding = .utf8) {
        guard !pattern.isEmpty,
              !pattern.contains("\n"),
              !replacement.contains("\n"),
              let patternBytes = encoding.encode(pattern),
              let replacementBytes = encoding.encode(replacement) else {
            return nil
        }
        self.pattern = pattern
        self.replacement = replacement
        self.encoding = encoding
        self.patternBytes = patternBytes
        self.replacementBytes = replacementBytes
    }
}
