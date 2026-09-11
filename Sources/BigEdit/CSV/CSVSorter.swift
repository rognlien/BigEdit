import Foundation

/// Reorders a delimited file's lines by one of its columns.
///
/// The key is the field's text, compared naturally so `9` sorts before `10`
/// and `item9` before `item10`. Lines sharing a key keep their original
/// order, ascending or descending, so sorting by a second column refines
/// the first sort rather than scrambling it. A header row stays where it is.
enum CSVSorter {

    /// `lines` sorted by `column`, or nil when cancelled.
    ///
    /// A line with fewer fields than `column` sorts as an empty key — first
    /// ascending, last descending — rather than being dropped.
    static func sorted(_ lines: [String], byColumn column: Int, dialect: CSVDialect,
                       descending: Bool, isCancelled: () -> Bool = { false }) -> [String]? {
        var result: [String]?
        let firstDataLine = dialect.hasHeaderRow && !lines.isEmpty ? 1 : 0
        let keys = lines[firstDataLine...].map { key(of: $0, column: column, dialect: dialect) }

        // Sort indices so each key is computed once, and so ties fall back to
        // the original position: Swift's sort is not stable on its own.
        var order = Array(keys.indices)
        var cancelled = false
        order.sort { left, right in
            if isCancelled() {
                cancelled = true
            }
            return precedes(left, right, keys: keys, descending: descending)
        }
        if !cancelled {
            result = Array(lines[..<firstDataLine]) + order.map { lines[firstDataLine + $0] }
        }
        return result
    }

    private static func key(of line: String, column: Int, dialect: CSVDialect) -> String {
        let fields = CSVParser.fields(in: line, dialect: dialect)
        return column < fields.count ? fields[column] : ""
    }

    private static func precedes(_ left: Int, _ right: Int, keys: [String], descending: Bool) -> Bool {
        var result = left < right
        let leftKey = keys[left]
        let rightKey = keys[right]
        if leftKey != rightKey {
            let ascending = LineProcessor.naturalPrecedes(leftKey, rightKey)
            result = descending ? !ascending : ascending
        }
        return result
    }
}
