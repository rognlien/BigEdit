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

    /// The UTF-8 bytes searched for and spliced in.
    let patternBytes: [UInt8]
    let replacementBytes: [UInt8]

    /// Creates a rule, or returns `nil` if it is not valid for Stage 1: the
    /// pattern must be non-empty and neither side may contain a newline.
    init?(pattern: String, replacement: String) {
        guard !pattern.isEmpty,
              !pattern.contains("\n"),
              !replacement.contains("\n") else {
            return nil
        }
        self.pattern = pattern
        self.replacement = replacement
        self.patternBytes = Array(pattern.utf8)
        self.replacementBytes = Array(replacement.utf8)
    }

    /// The byte-length change each occurrence produces (negative if shrinking).
    var lengthDelta: Int {
        replacementBytes.count - patternBytes.count
    }
}
