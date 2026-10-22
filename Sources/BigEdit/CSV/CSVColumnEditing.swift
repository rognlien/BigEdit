import Foundation

/// A column added to or removed from every row of a table.
enum CSVColumnChange: Equatable {
    /// An empty column inserted before `column`, as wide as `widthOf`.
    case insertion(before: Int, widthOf: Int)
    case removal(of: Int)
}

/// Rewrites a delimited file's bytes a column at a time. Each line keeps
/// every byte but the delimiter and field the change adds or removes, so
/// the encoding, quoting and line endings pass through untouched.
enum CSVColumnEditing {

    /// `bytes` with `change` applied to every line, or nil when cancelled.
    /// A line too short to reach the column, and an empty line, are left
    /// as they are.
    static func applying(_ change: CSVColumnChange, to bytes: [UInt8], dialect: CSVDialect,
                         encoding: TextEncoding, isCancelled: () -> Bool = { false }) -> [UInt8]? {
        var result: [UInt8]? = []
        result?.reserveCapacity(bytes.count + bytes.count / 8)
        let delimiter = encoding.encode(String(dialect.delimiter)) ?? []
        var lineStart = 0
        var lineCount = 0
        while lineStart < bytes.count, result != nil {
            let newline = bytes[lineStart...].firstIndex(of: 0x0A) ?? bytes.count
            let contentEnd = newline > lineStart && bytes[newline - 1] == 0x0D ? newline - 1 : newline
            let line = Array(bytes[lineStart..<contentEnd])
            result?.append(contentsOf: editedLine(line, change: change, delimiter: delimiter,
                                                  dialect: dialect, encoding: encoding))
            result?.append(contentsOf: bytes[contentEnd..<min(newline + 1, bytes.count)])
            lineStart = newline + 1
            lineCount += 1
            if lineCount % 4096 == 0 && isCancelled() {
                result = nil
            }
        }
        return result
    }

    private static func editedLine(_ line: [UInt8], change: CSVColumnChange, delimiter: [UInt8],
                                   dialect: CSVDialect, encoding: TextEncoding) -> [UInt8] {
        var result = line
        if !line.isEmpty {
            let fields = CSVParser.fieldByteRanges(in: line, dialect: dialect, encoding: encoding)
            switch change {
            case .insertion(let column, _):
                if let offset = insertionOffset(before: column, fields: fields) {
                    result.insert(contentsOf: delimiter, at: offset)
                }
            case .removal(let column):
                if let range = removedRange(of: column, fields: fields) {
                    result.removeSubrange(range)
                }
            }
        }
        return result
    }

    /// Where a delimiter goes to put an empty field before `column`: at the
    /// start of that field, or at the line's end when the line's last field
    /// is the one before it.
    private static func insertionOffset(before column: Int, fields: [Range<Int>]) -> Int? {
        var result: Int?
        if column < fields.count {
            result = fields[column].lowerBound
        } else if column == fields.count, let last = fields.last {
            result = last.upperBound
        }
        return result
    }

    /// The bytes that remove `column`'s field and one delimiter beside it:
    /// the one after it, or for the last field the one before. A line of
    /// one field keeps it, emptied.
    private static func removedRange(of column: Int, fields: [Range<Int>]) -> Range<Int>? {
        var result: Range<Int>?
        if column + 1 < fields.count {
            result = fields[column].lowerBound..<fields[column + 1].lowerBound
        } else if column < fields.count && column > 0 {
            result = fields[column - 1].upperBound..<fields[column].upperBound
        } else if column == 0 && fields.count == 1 {
            result = fields[0]
        }
        return result
    }
}
