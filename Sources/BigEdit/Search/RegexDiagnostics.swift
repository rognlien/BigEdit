import Foundation

/// Says what is wrong with a regular expression, in words.
///
/// `NSRegularExpression` only reports that a pattern is invalid, not why, so
/// the usual mistakes are found here first: an unclosed group or class, a
/// quantifier with nothing before it, a backslash at the end. Anything else
/// the engine rejects is reported as invalid without a reason.
enum RegexDiagnostics {

    /// A one-line description of the problem, or `nil` when `pattern`
    /// compiles. An empty pattern is not a problem — it just finds nothing.
    static func problem(in pattern: String,
                        options: NSRegularExpression.Options = []) -> String? {
        if pattern.isEmpty {
            return nil
        }
        if (try? NSRegularExpression(pattern: pattern, options: options)) != nil {
            return nil
        }
        return describe(pattern) ?? "Invalid pattern"
    }

    /// Walks the pattern once looking for the common structural mistakes.
    private static func describe(_ pattern: String) -> String? {
        var depth = 0
        var inClass = false
        var previous: Character?
        var escaped = false
        var position = 0

        for character in pattern {
            position += 1
            if escaped {
                escaped = false
                previous = character
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "[":
                if !inClass {
                    inClass = true
                }
            case "]":
                inClass = false
            case "(" where !inClass:
                depth += 1
            case ")" where !inClass:
                depth -= 1
                if depth < 0 {
                    return "Unmatched “)” at position \(position)"
                }
            case "*", "+", "?", "{":
                // A `where` on a multi-pattern case binds only to the last
                // pattern, so the class check is a statement here.
                if !inClass && (previous == nil || previous == "(" || previous == "|") {
                    return "Nothing to repeat before “\(character)” at position \(position)"
                }
            default:
                break
            }
            previous = character
        }
        if escaped {
            return "A backslash at the end has nothing to escape"
        }
        if inClass {
            return "Unclosed “[” character class"
        }
        if depth > 0 {
            return depth == 1 ? "Unclosed “(” group" : "\(depth) unclosed “(” groups"
        }
        if let braces = badBraces(in: pattern) {
            return braces
        }
        return nil
    }

    /// `{n,m}` with the numbers the wrong way round, which ICU rejects.
    private static func badBraces(in pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: "\\{(\\d+),(\\d+)\\}") else {
            return nil
        }
        let range = NSRange(pattern.startIndex..., in: pattern)
        for match in expression.matches(in: pattern, range: range) {
            if let low = Range(match.range(at: 1), in: pattern), let high = Range(match.range(at: 2), in: pattern),
               let lowValue = Int(pattern[low]), let highValue = Int(pattern[high]), lowValue > highValue {
                return "“{\(lowValue),\(highValue)}” has its bounds the wrong way round"
            }
        }
        return nil
    }
}

/// What a replacement template produces for one match.
enum ReplacementPreview {

    /// `template` expanded for the whole of `matchedText` as a match of
    /// `pattern` — what Replace All would put in its place. `nil` when the
    /// pattern does not compile or does not match the text as a whole,
    /// which happens for lookarounds that depended on the surroundings.
    static func expansion(of template: String, for matchedText: String, pattern: String,
                          options: NSRegularExpression.Options) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let whole = NSRange(location: 0, length: matchedText.utf16.count)
        guard let match = expression.firstMatch(in: matchedText, range: whole),
              match.range == whole else {
            return nil
        }
        return expression.replacementString(for: match, in: matchedText, offset: 0, template: template)
    }
}
