import Foundation

/// A replacement within a delimited field or line, with where the caret
/// lands: `bytesAfterCaret` of `bytes` follow it, such as a closing quote.
struct CSVCellEdit: Equatable {
    let range: Range<Int>
    let bytes: [UInt8]
    let bytesAfterCaret: Int

    /// The same edit with its range moved by `distance`.
    func shifted(by distance: Int) -> CSVCellEdit {
        CSVCellEdit(range: (range.lowerBound + distance)..<(range.upperBound + distance),
                    bytes: bytes, bytesAfterCaret: bytesAfterCaret)
    }
}

/// Edits that keep a delimited row's cells intact: text typed into a field
/// stays in it, quoted when it holds a delimiter, a quote or a line break.
enum CSVCellEditing {

    /// The edit that puts `text` in place of `range` (field-relative) of the
    /// raw `field`, or nil when the text cannot stay in the field because
    /// the dialect has no quote character to wrap it in.
    static func insertion(of text: [UInt8], replacing range: Range<Int>, inField field: [UInt8],
                          dialect: CSVDialect, encoding: TextEncoding) -> CSVCellEdit? {
        let quote = quoteBytes(of: dialect, encoding: encoding)
        var result: CSVCellEdit?
        if !quote.isEmpty && field.starts(with: quote) {
            let value = valueRange(of: field, quote: quote)
            let inside = range.clamped(to: value)
            result = CSVCellEdit(range: inside, bytes: doublingQuotes(in: text, quote: quote), bytesAfterCaret: 0)
        } else if !needsQuoting(text, dialect: dialect, encoding: encoding) {
            result = CSVCellEdit(range: range, bytes: text, bytesAfterCaret: 0)
        } else if !quote.isEmpty {
            result = quotedField(field, inserting: text, replacing: range, quote: quote)
        }
        return result
    }

    /// The whole field rewritten as a quoted one with `text` in place of
    /// `range`, the caret left just after the text.
    private static func quotedField(_ field: [UInt8], inserting text: [UInt8], replacing range: Range<Int>,
                                    quote: [UInt8]) -> CSVCellEdit {
        let before = doublingQuotes(in: Array(field[..<range.lowerBound]) + text, quote: quote)
        let after = doublingQuotes(in: Array(field[range.upperBound...]), quote: quote) + quote
        return CSVCellEdit(range: 0..<field.count, bytes: quote + before + after,
                           bytesAfterCaret: after.count)
    }

    /// Whether `text` would end the field it is typed into unless quoted.
    static func needsQuoting(_ text: [UInt8], dialect: CSVDialect, encoding: TextEncoding) -> Bool {
        let delimiter = encoding.encode(String(dialect.delimiter)) ?? []
        let quote = quoteBytes(of: dialect, encoding: encoding)
        return text.contains(0x0A) || text.contains(0x0D)
            || (!delimiter.isEmpty && text.contains(delimiter))
            || (!quote.isEmpty && text.contains(quote))
    }

    /// The bytes of a quoted `field` between its quotes.
    static func valueRange(of field: [UInt8], quote: [UInt8]) -> Range<Int> {
        let start = quote.count
        let isClosed = field.count >= start + quote.count && field.suffix(quote.count).elementsEqual(quote)
        return start..<max(start, isClosed ? field.count - quote.count : field.count)
    }

    static func quoteBytes(of dialect: CSVDialect, encoding: TextEncoding) -> [UInt8] {
        dialect.quote.flatMap { encoding.encode(String($0)) } ?? []
    }

    private static func doublingQuotes(in bytes: [UInt8], quote: [UInt8]) -> [UInt8] {
        quote.isEmpty ? bytes : bytes.replacing(quote, with: quote + quote)
    }
}
