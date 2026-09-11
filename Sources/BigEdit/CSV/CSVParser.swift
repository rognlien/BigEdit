import Foundation

/// Splits a single delimited row into its fields.
///
/// Quoted fields are understood, so a field containing the delimiter stays one
/// field, and a doubled quote inside a quoted field reads as a literal quote.
/// The surrounding quotes are stripped: the aligned table shows the field's
/// value, not its encoding.
///
/// A quoted field that spans a newline is deliberately *not* joined across
/// rows. BigEdit's rows are physical lines — that is what keeps the line index
/// independent of the file's size — so such a field renders as separate rows.
enum CSVParser {

    /// The fields of `line`, always at least one (an empty line is one empty
    /// field).
    static func fields(in line: String, dialect: CSVDialect) -> [String] {
        var fields: [String] = []
        var current = ""
        var insideQuotes = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if let quote = dialect.quote, character == quote {
                let next = line.index(after: index)
                if insideQuotes, next < line.endIndex, line[next] == quote {
                    current.append(quote)     // a doubled quote is one literal
                    index = next
                } else if insideQuotes {
                    insideQuotes = false
                } else if current.isEmpty {
                    insideQuotes = true        // only opens at the field's start
                } else {
                    current.append(character)  // a stray quote mid-field is literal
                }
            } else if character == dialect.delimiter && !insideQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        fields.append(current)

        if dialect.trimsFieldWhitespace {
            fields = fields.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return fields
    }

    /// The byte range of each raw field in `line` (a line without its ending,
    /// in `encoding`), delimiters excluded and quotes included — the same
    /// split as `fields(in:)`, kept in terms of the file's bytes so a drawn
    /// cell can be traced back to them. Always at least one range.
    static func fieldByteRanges(in line: [UInt8], dialect: CSVDialect,
                                encoding: TextEncoding) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let delimiter = encoding.encode(String(dialect.delimiter)) ?? []
        let quote = dialect.quote.flatMap { encoding.encode(String($0)) } ?? []
        var fieldStart = 0
        var insideQuotes = false
        var index = 0

        while index < line.count {
            if !quote.isEmpty, line[index...].starts(with: quote) {
                let next = index + quote.count
                if insideQuotes, line[next...].starts(with: quote) {
                    index = next                            // a doubled quote is one literal
                } else if insideQuotes {
                    insideQuotes = false
                } else if index == fieldStart {
                    insideQuotes = true                     // only opens at the field's start
                }
                index += quote.count
            } else if !delimiter.isEmpty, !insideQuotes, line[index...].starts(with: delimiter) {
                ranges.append(fieldStart..<index)
                index += delimiter.count
                fieldStart = index
            } else {
                index += 1
            }
        }
        ranges.append(fieldStart..<line.count)
        return ranges
    }
}
