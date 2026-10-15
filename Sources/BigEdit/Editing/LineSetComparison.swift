import Foundation

/// Two lists of lines compared as sets: what only the first has, what only
/// the second has, and what both have.
///
/// This is `comm` without the sorting: each list keeps its own order, and
/// each item appears once per list however often it repeats, so the three
/// results answer "which items differ" rather than "which lines differ".
/// Lines are matched by the same keys the set operations use, so two CSV
/// exports can be compared on one column.
struct LineSetComparison: Equatable {

    /// Lines of the first list whose key the second list does not have.
    let onlyInFirst: [String]

    /// Lines of the second list whose key the first list does not have.
    let onlyInSecond: [String]

    /// Lines of the first list whose key the second list also has.
    let inBoth: [String]

    /// Compares `first` with `second`, or returns `nil` when cancelled.
    /// Throws `LineProcessor.ProcessingError.invalidPattern` for a key
    /// pattern that does not compile.
    static func compare(_ first: [String], _ second: [String],
                        options: LineMatchOptions = LineMatchOptions(),
                        isCancelled: () -> Bool = { false }) throws -> LineSetComparison? {
        let keyMaker = try LineKeyMaker(options: options)
        let firstKeys = LineSetOperation.keySet(of: first, keyMaker: keyMaker)
        let secondKeys = LineSetOperation.keySet(of: second, keyMaker: keyMaker)

        var onlyInFirst: [String] = []
        var onlyInSecond: [String] = []
        var inBoth: [String] = []
        var seen = Set<String>()

        for line in first {
            if isCancelled() {
                return nil
            }
            let key = keyMaker.key(for: line)
            if seen.insert(key).inserted {
                if secondKeys.contains(key) {
                    inBoth.append(line)
                } else {
                    onlyInFirst.append(line)
                }
            }
        }
        seen.removeAll(keepingCapacity: true)
        for line in second {
            if isCancelled() {
                return nil
            }
            let key = keyMaker.key(for: line)
            if seen.insert(key).inserted && !firstKeys.contains(key) {
                onlyInSecond.append(line)
            }
        }
        return LineSetComparison(onlyInFirst: onlyInFirst, onlyInSecond: onlyInSecond, inBoth: inBoth)
    }
}
