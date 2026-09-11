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
}
