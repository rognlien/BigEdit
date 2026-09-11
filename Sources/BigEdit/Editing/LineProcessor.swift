import Foundation

/// A transformation applied to every line of a document.
///
/// These are whole-document operations: unlike everything else in BigEdit they
/// cannot be answered from the viewport, because deduplicating or sorting means
/// looking at every line. What that costs is stated per case below, and the
/// caller is expected to run them off the main thread with a way to cancel.
enum LineOperation: Equatable {

    /// Keeps the first occurrence of each line and drops later repeats.
    /// Holds one 128-bit fingerprint per distinct line.
    case removeDuplicateLines

    /// Drops every line containing `pattern`. Streams; holds nothing.
    case removeLinesContaining(pattern: String, caseSensitive: Bool)

    /// Keeps only lines containing `pattern`. Streams; holds nothing.
    case keepLinesContaining(pattern: String, caseSensitive: Bool)

    /// Sorts the lines. `natural` compares runs of digits by value, so `file9`
    /// sorts before `file10`. With `keyPattern`, lines are ordered by the first
    /// match of that regular expression rather than by the whole line. Holds
    /// every line.
    case sortLines(natural: Bool, keyPattern: String?)

    /// Replaces every match of `pattern` within each line. `replacement` may
    /// use `$1`-style group references. Streams; holds nothing.
    case replaceWithinLines(pattern: String, replacement: String)
}

/// Applies a `LineOperation` to a document's lines.
///
/// The transformation is a pure function of the lines, so it can be tested
/// against `sort`, `uniq`, `grep` and `sed` without any UI or file handling.
enum LineProcessor {

    enum ProcessingError: Error, Equatable {
        case invalidPattern(String)
    }

    /// Applies `operation`, returning the new lines.
    ///
    /// `isCancelled` is consulted per line so a long run can be stopped; when
    /// it returns true the result so far is discarded and `nil` comes back.
    static func apply(_ operation: LineOperation, to lines: [String],
                      isCancelled: () -> Bool = { false }) throws -> [String]? {
        var result: [String]?
        switch operation {
        case .removeDuplicateLines:
            result = removeDuplicates(in: lines, isCancelled: isCancelled)
        case .removeLinesContaining(let pattern, let caseSensitive):
            result = filter(lines, containing: pattern, caseSensitive: caseSensitive,
                            keepMatches: false, isCancelled: isCancelled)
        case .keepLinesContaining(let pattern, let caseSensitive):
            result = filter(lines, containing: pattern, caseSensitive: caseSensitive,
                            keepMatches: true, isCancelled: isCancelled)
        case .sortLines(let natural, let keyPattern):
            result = try sort(lines, natural: natural, keyPattern: keyPattern,
                              isCancelled: isCancelled)
        case .replaceWithinLines(let pattern, let replacement):
            result = try replace(in: lines, pattern: pattern, replacement: replacement,
                                 isCancelled: isCancelled)
        }
        return result
    }

    // MARK: - Duplicates

    private static func removeDuplicates(in lines: [String],
                                         isCancelled: () -> Bool) -> [String]? {
        var result: [String]? = nil
        var kept: [String] = []
        var seen = Set<String>()
        var cancelled = false
        kept.reserveCapacity(lines.count)
        for line in lines {
            if isCancelled() {
                cancelled = true
                break
            }
            if seen.insert(line).inserted {
                kept.append(line)
            }
        }
        if !cancelled {
            result = kept
        }
        return result
    }

    // MARK: - Filtering

    private static func filter(_ lines: [String], containing pattern: String,
                               caseSensitive: Bool, keepMatches: Bool,
                               isCancelled: () -> Bool) -> [String]? {
        var result: [String]? = nil
        var kept: [String] = []
        var cancelled = false
        let needle = caseSensitive ? pattern : pattern.lowercased()
        for line in lines {
            if isCancelled() {
                cancelled = true
                break
            }
            let haystack = caseSensitive ? line : line.lowercased()
            // An empty pattern matches every line, which is what a plain
            // substring search does.
            let matches = needle.isEmpty || haystack.contains(needle)
            if matches == keepMatches {
                kept.append(line)
            }
        }
        if !cancelled {
            result = kept
        }
        return result
    }

    // MARK: - Sorting

    private static func sort(_ lines: [String], natural: Bool, keyPattern: String?,
                             isCancelled: () -> Bool) throws -> [String]? {
        var result: [String]? = nil
        var keys: [String] = []
        keys.reserveCapacity(lines.count)

        if let keyPattern, !keyPattern.isEmpty {
            guard let expression = try? NSRegularExpression(pattern: keyPattern) else {
                throw ProcessingError.invalidPattern(keyPattern)
            }
            for line in lines {
                keys.append(firstMatch(of: expression, in: line) ?? "")
            }
        } else {
            keys = lines
        }

        // Sort indices so each line's key is computed once rather than per
        // comparison — and so ties can fall back to the original position.
        // Swift's sort is not stable, so without that tiebreak lines sharing a
        // key (which is the normal case for a key pattern) would come out in an
        // arbitrary order.
        var order = Array(lines.indices)
        var cancelled = false
        order.sort { left, right in
            if isCancelled() {
                cancelled = true
            }
            let leftKey = keys[left]
            let rightKey = keys[right]
            if leftKey == rightKey {
                return left < right
            }
            return natural
                ? naturalPrecedes(leftKey, rightKey)
                : leftKey < rightKey
        }
        if !cancelled {
            result = order.map { lines[$0] }
        }
        return result
    }

    /// The text of the first match, or the first capture group when there is
    /// one — so a key pattern can point at part of the line.
    private static func firstMatch(of expression: NSRegularExpression,
                                   in line: String) -> String? {
        var key: String?
        let range = NSRange(line.startIndex..., in: line)
        if let match = expression.firstMatch(in: line, range: range) {
            let wanted = match.numberOfRanges > 1 ? 1 : 0
            if let matchRange = Range(match.range(at: wanted), in: line) {
                key = String(line[matchRange])
            }
        }
        return key
    }

    /// Compares two strings treating runs of digits as numbers, so `file9`
    /// comes before `file10` rather than after it.
    static func naturalPrecedes(_ left: String, _ right: String) -> Bool {
        var result = false
        var leftIndex = left.startIndex
        var rightIndex = right.startIndex

        while leftIndex < left.endIndex && rightIndex < right.endIndex {
            let leftCharacter = left[leftIndex]
            let rightCharacter = right[rightIndex]

            if leftCharacter.isNumber && rightCharacter.isNumber {
                let leftRun = digitRun(in: left, from: leftIndex)
                let rightRun = digitRun(in: right, from: rightIndex)
                let leftValue = left[leftIndex..<leftRun]
                let rightValue = right[rightIndex..<rightRun]
                // Compare by value, falling back to text for runs too long to
                // hold in an Int.
                let leftNumber = Int(leftValue)
                let rightNumber = Int(rightValue)
                if let leftNumber, let rightNumber, leftNumber != rightNumber {
                    return leftNumber < rightNumber
                }
                if leftNumber == nil || rightNumber == nil,
                   leftValue.count != rightValue.count {
                    return leftValue.count < rightValue.count
                }
                leftIndex = leftRun
                rightIndex = rightRun
            } else if leftCharacter != rightCharacter {
                return leftCharacter < rightCharacter
            } else {
                leftIndex = left.index(after: leftIndex)
                rightIndex = right.index(after: rightIndex)
            }
        }
        // One is a prefix of the other: the shorter sorts first.
        if leftIndex == left.endIndex && rightIndex != right.endIndex {
            result = true
        }
        return result
    }

    /// The index just past the run of digits starting at `start`.
    private static func digitRun(in text: String, from start: String.Index) -> String.Index {
        var index = start
        while index < text.endIndex && text[index].isNumber {
            index = text.index(after: index)
        }
        return index
    }

    // MARK: - Regular expression replacement

    private static func replace(in lines: [String], pattern: String, replacement: String,
                                isCancelled: () -> Bool) throws -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            throw ProcessingError.invalidPattern(pattern)
        }
        var result: [String]? = nil
        var rewritten: [String] = []
        var cancelled = false
        rewritten.reserveCapacity(lines.count)
        for line in lines {
            if isCancelled() {
                cancelled = true
                break
            }
            let range = NSRange(line.startIndex..., in: line)
            rewritten.append(expression.stringByReplacingMatches(
                in: line, range: range, withTemplate: replacement))
        }
        if !cancelled {
            result = rewritten
        }
        return result
    }
}
