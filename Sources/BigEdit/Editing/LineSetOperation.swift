import Foundation

/// How two lists of lines are matched against each other.
///
/// A line is reduced to a *key* before it is compared: optionally trimmed,
/// optionally case-folded, and optionally cut down to the first match of a
/// regular expression (its first capture group when it has one). Two lines
/// with the same key are the same item. The default options compare whole
/// lines exactly, which is what `comm` and `grep -Fxf` do.
struct LineMatchOptions: Equatable {

    /// Ignore leading and trailing whitespace.
    var trimsWhitespace = false

    /// Ignore the difference between upper- and lower-case letters.
    var ignoresCase = false

    /// Compare by the first match of this pattern — or by its first capture
    /// group, when it has one — instead of by the whole line. A line the
    /// pattern does not match has an empty key.
    var keyPattern: String?

    init(trimsWhitespace: Bool = false, ignoresCase: Bool = false, keyPattern: String? = nil) {
        self.trimsWhitespace = trimsWhitespace
        self.ignoresCase = ignoresCase
        self.keyPattern = keyPattern
    }
}

/// Turns lines into the keys they are compared by. Compiles the key pattern
/// once, so it is built once per operation rather than once per line.
struct LineKeyMaker {

    private let options: LineMatchOptions
    private let expression: NSRegularExpression?

    /// Throws `LineProcessor.ProcessingError.invalidPattern` when the key
    /// pattern does not compile.
    init(options: LineMatchOptions) throws {
        self.options = options
        if let pattern = options.keyPattern, !pattern.isEmpty {
            guard let compiled = try? NSRegularExpression(pattern: pattern) else {
                throw LineProcessor.ProcessingError.invalidPattern(pattern)
            }
            expression = compiled
        } else {
            expression = nil
        }
    }

    /// The key `line` is compared by.
    func key(for line: String) -> String {
        var key = line
        if let expression {
            key = LineKeyMaker.firstMatch(of: expression, in: key) ?? ""
        }
        if options.trimsWhitespace {
            key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if options.ignoresCase {
            key = key.lowercased()
        }
        return key
    }

    /// The text of the first match, or of the first capture group when there
    /// is one — the same rule the sort key uses.
    static func firstMatch(of expression: NSRegularExpression, in line: String) -> String? {
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
}

/// A set operation between the document's lines and another list.
enum SetOperationKind: Int, Equatable, CaseIterable {

    /// The document with every line that is also in the other list removed.
    case subtract

    /// Only the document's lines that are also in the other list.
    case intersect

    /// The document, followed by the other list's lines it did not have.
    case union

    /// The document's lines not in the other list, followed by the other
    /// list's lines not in the document.
    case symmetricDifference

    var title: String {
        switch self {
        case .subtract: return "Remove lines that are in another list"
        case .intersect: return "Keep only lines that are in another list"
        case .union: return "Add the lines another list has that this one lacks"
        case .symmetricDifference: return "Keep lines that are in only one of the two lists"
        }
    }

    /// Whether the result keeps only lines of the document, in order, so it
    /// can be produced by a single streaming pass that holds only the other
    /// list. Union and symmetric difference also append lines from the other
    /// list, which means knowing every key the document has.
    var isFilter: Bool {
        self == .subtract || self == .intersect
    }
}

/// Applies set operations to lines.
///
/// The document side streams: `subtract` and `intersect` look at each line
/// once and decide, holding only the other list's keys. So the other list
/// has to fit in memory, but the document does not — which is what lets a
/// known-ID list be removed from a log far larger than the Process Lines
/// ceiling (see `LineFilterWriter`). Union and symmetric difference need the
/// document's keys too, and stay under the ceiling.
///
/// Duplicates in the document are kept as they are: subtracting a list from
/// `a a b` leaves both `a`s when `a` is not in the list, as `grep -vFxf`
/// would. Lines appended from the other list are added once each, since
/// "the lines this list lacks" names each missing item, not each repeat.
enum LineSetOperation {

    /// The keys of `lines`, for membership tests.
    static func keySet(of lines: [String], keyMaker: LineKeyMaker) -> Set<String> {
        var keys = Set<String>()
        keys.reserveCapacity(lines.count)
        for line in lines {
            keys.insert(keyMaker.key(for: line))
        }
        return keys
    }

    /// `kind` applied to `lines` against `other`, or `nil` when cancelled.
    static func apply(_ kind: SetOperationKind, to lines: [String], other: [String],
                      options: LineMatchOptions,
                      isCancelled: () -> Bool = { false }) throws -> [String]? {
        let keyMaker = try LineKeyMaker(options: options)
        let otherKeys = keySet(of: other, keyMaker: keyMaker)
        var result: [String]? = nil
        var kept: [String] = []
        var cancelled = false

        switch kind {
        case .subtract, .intersect:
            let keepMembers = kind == .intersect
            kept.reserveCapacity(keepMembers ? 0 : lines.count)
            for line in lines {
                if isCancelled() {
                    cancelled = true
                    break
                }
                if otherKeys.contains(keyMaker.key(for: line)) == keepMembers {
                    kept.append(line)
                }
            }
        case .union, .symmetricDifference:
            let ownKeys = keySet(of: lines, keyMaker: keyMaker)
            if kind == .union {
                kept = lines
            } else {
                for line in lines {
                    if isCancelled() {
                        cancelled = true
                        break
                    }
                    if !otherKeys.contains(keyMaker.key(for: line)) {
                        kept.append(line)
                    }
                }
            }
            var appended = Set<String>()
            for line in other where !cancelled {
                if isCancelled() {
                    cancelled = true
                    break
                }
                let key = keyMaker.key(for: line)
                if !ownKeys.contains(key) && appended.insert(key).inserted {
                    kept.append(line)
                }
            }
        }

        if !cancelled {
            result = kept
        }
        return result
    }

    /// A predicate deciding, line by line, whether a line of the document
    /// survives `kind` against `other` — the streaming form of `subtract`
    /// and `intersect`. `nil` for the kinds that are not filters.
    static func filter(for kind: SetOperationKind, other: [String],
                       options: LineMatchOptions) throws -> ((String) -> Bool)? {
        guard kind.isFilter else {
            return nil
        }
        let keyMaker = try LineKeyMaker(options: options)
        let otherKeys = keySet(of: other, keyMaker: keyMaker)
        let keepMembers = kind == .intersect
        return { line in otherKeys.contains(keyMaker.key(for: line)) == keepMembers }
    }
}
