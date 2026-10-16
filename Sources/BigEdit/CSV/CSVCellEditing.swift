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

    /// The edit that clears the cells `range` covers in `text` — whole
    /// lines, from a line's start — as a spreadsheet clears selected cells:
    /// their content goes, every delimiter, quote and line ending stays, so
    /// each row keeps its cells. The caret lands where the cleared text
    /// began. Nil when the range covers no cell content.
    static func clearing(_ range: Range<Int>, in text: [UInt8], dialect: CSVDialect,
                         encoding: TextEncoding) -> CSVCellEdit? {
        let removals = valueRanges(in: text, dialect: dialect, encoding: encoding)
            .map { $0.clamped(to: range) }
            .filter { !$0.isEmpty }
        var result: CSVCellEdit?
        if let first = removals.first, let last = removals.last {
            let kept = zip(removals, removals.dropFirst()).flatMap { text[$0.upperBound..<$1.lowerBound] }
            result = CSVCellEdit(range: first.lowerBound..<last.upperBound, bytes: kept, bytesAfterCaret: kept.count)
        }
        return result
    }

    /// The value of every field on every line of `text`.
    private static func valueRanges(in text: [UInt8], dialect: CSVDialect, encoding: TextEncoding) -> [Range<Int>] {
        let quote = quoteBytes(of: dialect, encoding: encoding)
        var ranges: [Range<Int>] = []
        var lineStart = 0
        while lineStart <= text.count {
            let newline = text[lineStart...].firstIndex(of: 0x0A) ?? text.count
            let lineEnd = newline > lineStart && text[newline - 1] == 0x0D ? newline - 1 : newline
            let line = Array(text[lineStart..<lineEnd])
            for field in CSVParser.fieldByteRanges(in: line, dialect: dialect, encoding: encoding) {
                let value = fieldValueRange(of: Array(line[field]), quote: quote)
                let start = lineStart + field.lowerBound
                ranges.append((start + value.lowerBound)..<(start + value.upperBound))
            }
            lineStart = newline + 1
        }
        return ranges
    }

    /// What Backspace (`backward`) or Forward Delete removes at `caret` in
    /// the raw `field`: a character of its value, or a doubled quote as one.
    /// Nil at the value's edge, which a delete stops at rather than remove a
    /// quote or the delimiter beyond it.
    static func deletion(backward: Bool, at caret: Int, inField field: [UInt8],
                         dialect: CSVDialect, encoding: TextEncoding) -> Range<Int>? {
        let units = characterUnits(of: field, quote: quoteBytes(of: dialect, encoding: encoding),
                                   isSingleByte: encoding.isSingleByte)
        return backward ? units.last { $0.lowerBound < caret } : units.first { $0.upperBound > caret }
    }

    /// The field's value cut into what one delete removes: a character, or
    /// inside a quoted field a doubled quote.
    private static func characterUnits(of field: [UInt8], quote: [UInt8], isSingleByte: Bool) -> [Range<Int>] {
        let isQuoted = !quote.isEmpty && field.starts(with: quote)
        let value = isQuoted ? valueRange(of: field, quote: quote) : 0..<field.count
        let doubledQuote = quote + quote
        var units: [Range<Int>] = []
        var index = value.lowerBound
        while index < value.upperBound {
            var end = index + 1
            if isQuoted, index + doubledQuote.count <= value.upperBound, field[index...].starts(with: doubledQuote) {
                end = index + doubledQuote.count
            } else {
                while !isSingleByte, end < value.upperBound, field[end] & 0xC0 == 0x80 {
                    end += 1
                }
            }
            units.append(index..<end)
            index = end
        }
        return units
    }

    /// Whether `text` would end the field it is typed into unless quoted.
    static func needsQuoting(_ text: [UInt8], dialect: CSVDialect, encoding: TextEncoding) -> Bool {
        let delimiter = encoding.encode(String(dialect.delimiter)) ?? []
        let quote = quoteBytes(of: dialect, encoding: encoding)
        return text.contains(0x0A) || text.contains(0x0D)
            || (!delimiter.isEmpty && text.contains(delimiter))
            || (!quote.isEmpty && text.contains(quote))
    }

    /// The bytes of a raw `field` that hold its value: all of an unquoted
    /// one, the inside of a quoted one.
    private static func fieldValueRange(of field: [UInt8], quote: [UInt8]) -> Range<Int> {
        let isQuoted = !quote.isEmpty && field.starts(with: quote)
        return isQuoted ? valueRange(of: field, quote: quote) : 0..<field.count
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
