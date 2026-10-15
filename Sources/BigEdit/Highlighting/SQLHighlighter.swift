import Foundation

/// A SQL highlighter for the common dialects: standard SQL, PostgreSQL, MySQL
/// and SQLite. It tokenizes one row at a time; a `/* */` comment, a string or
/// a dollar-quoted body still open at the end of a row is carried into the next.
///
/// Recognises `--` and `/* */` comments, single-quoted strings (with doubled
/// quotes, and backslash escapes as MySQL dumps write them), PostgreSQL
/// dollar-quoted bodies, quoted identifiers, keywords and type names in any
/// case, the literals `NULL`, `TRUE` and `FALSE`, numbers, bind parameters and
/// variables, and operators.
enum SQLHighlighter {

    /// Stateful entry: `startState` says whether the row begins inside a
    /// comment, a string or a dollar-quoted body. Returns the row's tokens and
    /// its end state.
    static func tokens(_ text: String, startState: HighlightState) -> ([Token], HighlightState) {
        var scan = SQLRowScan(text)
        scan.run(from: startState)
        return (scan.tokens, scan.state)
    }

    /// The tokens of a row that starts outside any comment or string.
    static func tokens(_ text: String) -> [Token] {
        return tokens(text, startState: .normal).0
    }

    static func endState(_ text: String, start: HighlightState) -> HighlightState {
        return tokens(text, startState: start).1
    }
}

/// The scan of one row, kept as a value so each construct gets a small
/// method of its own.
private struct SQLRowScan {

    private static let singleQuote = unichar(UInt8(ascii: "'"))
    private static let doubleQuote = unichar(UInt8(ascii: "\""))
    private static let backtick = unichar(UInt8(ascii: "`"))
    private static let dollar = unichar(UInt8(ascii: "$"))
    private static let at = unichar(UInt8(ascii: "@"))
    private static let colon = unichar(UInt8(ascii: ":"))
    private static let dot = unichar(UInt8(ascii: "."))
    private static let backslash = RowScanner.backslash

    private static let literals: Set<String> = ["NULL", "TRUE", "FALSE"]

    private static let keywords: Set<String> = [
        "ADD", "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "AUTO_INCREMENT",
        "AUTOINCREMENT", "BEGIN", "BETWEEN", "BY", "CASCADE", "CASE", "CHECK",
        "COLLATE", "COLUMN", "COMMENT", "COMMIT", "CONFLICT", "CONSTRAINT",
        "COPY", "CREATE", "CROSS", "DATABASE", "DECLARE", "DEFAULT", "DELETE",
        "DESC", "DISTINCT", "DO", "DROP", "EACH", "ELSE", "END", "ENGINE",
        "ESCAPE", "EXCEPT", "EXECUTE", "EXISTS", "EXPLAIN", "EXTENSION", "FETCH",
        "FOR", "FOREIGN", "FROM", "FULL", "FUNCTION", "GRANT", "GROUP", "HAVING",
        "IF", "IGNORE", "ILIKE", "IN", "INDEX", "INNER", "INSERT", "INTERSECT",
        "INTO", "IS", "JOIN", "KEY", "LANGUAGE", "LATERAL", "LEFT", "LIKE",
        "LIMIT", "LOCK", "NATURAL", "NOT", "NOTHING", "OFFSET", "ON", "OR",
        "ORDER", "OUTER", "OVER", "OWNER", "PARTITION", "PRIMARY", "PROCEDURE",
        "REFERENCES", "RENAME", "REPLACE", "RESTRICT", "RETURN", "RETURNING",
        "RETURNS", "REVOKE", "RIGHT", "ROLLBACK", "ROW", "SAVEPOINT", "SCHEMA",
        "SELECT", "SEQUENCE", "SET", "SHOW", "TABLE", "TABLES", "TEMPORARY",
        "THEN", "TO", "TRANSACTION", "TRIGGER", "TRUNCATE", "TYPE", "UNION",
        "UNIQUE", "UNLOCK", "UPDATE", "USE", "USING", "VALUES", "VIEW", "WHEN",
        "WHERE", "WINDOW", "WITH",
        "BIGINT", "BIGSERIAL", "BINARY", "BIT", "BLOB", "BOOL", "BOOLEAN",
        "BYTEA", "CHAR", "CHARACTER", "CHARSET", "DATE", "DATETIME", "DECIMAL",
        "DOUBLE", "ENUM", "FLOAT", "INT", "INTEGER", "INTERVAL", "JSON",
        "JSONB", "LONGBLOB", "LONGTEXT", "MEDIUMINT", "MEDIUMTEXT", "NUMERIC",
        "PRECISION", "REAL", "SERIAL", "SMALLINT", "TEXT", "TIME", "TIMESTAMP",
        "TIMESTAMPTZ", "TINYINT", "TINYTEXT", "UNSIGNED", "UUID", "VARBINARY",
        "VARCHAR", "ZONE"
    ]

    private let scanner: RowScanner
    private(set) var tokens: [Token] = []
    private(set) var state = HighlightState.normal
    private var index = 0

    init(_ text: String) {
        scanner = RowScanner(text)
    }

    mutating func run(from startState: HighlightState) {
        switch startState {
        case .blockComment:
            scanBlockComment(tokenStart: 0, contentStart: 0)
        case .singleQuotedString:
            scanString(tokenStart: 0, contentStart: 0)
        case .dollarQuotedString(let delimiter):
            scanDollarQuoted(delimiter: delimiter, tokenStart: 0, contentStart: 0)
        default:
            break
        }
        while index < scanner.length {
            scanNext()
        }
    }

    // MARK: - Dispatch

    private mutating func scanNext() {
        let character = scanner.character(at: index)
        if RowScanner.isWhitespace(character) {
            index += 1
        } else if scanner.matches("--", at: index) {
            tokens.add(.comment, index..<scanner.length)
            index = scanner.length
        } else if scanner.matches("/*", at: index) {
            scanBlockComment(tokenStart: index, contentStart: index + 2)
        } else if character == SQLRowScan.singleQuote {
            scanString(tokenStart: index, contentStart: index + 1)
        } else if character == SQLRowScan.doubleQuote || character == SQLRowScan.backtick {
            scanQuotedIdentifier(quote: character)
        } else if character == SQLRowScan.dollar {
            scanDollar()
        } else if character == SQLRowScan.at || character == SQLRowScan.colon {
            scanVariable()
        } else if RowScanner.isDigit(character) {
            scanNumber()
        } else if SQLRowScan.isWordStart(character) {
            scanWord()
        } else {
            scanOperator()
        }
    }

    // MARK: - Comments and strings

    /// `tokenStart` is the `/*`, or 0 on a row that continues the comment.
    private mutating func scanBlockComment(tokenStart: Int, contentStart: Int) {
        let close = scanner.indexAfter("*/", from: contentStart)
        let end = close ?? scanner.length
        tokens.add(.comment, tokenStart..<end)
        if close == nil {
            state = .blockComment
        }
        index = end
    }

    /// A doubled quote closes the string and opens the next one at once,
    /// which colours the same as one string.
    private mutating func scanString(tokenStart: Int, contentStart: Int) {
        var position = contentStart
        var closed = false
        while position < scanner.length && !closed {
            let character = scanner.character(at: position)
            if character == SQLRowScan.backslash {
                position += 2
            } else {
                closed = character == SQLRowScan.singleQuote
                position += 1
            }
        }
        let end = min(position, scanner.length)
        tokens.add(.string, tokenStart..<end)
        if !closed {
            state = .singleQuotedString
        }
        index = end
    }

    private mutating func scanQuotedIdentifier(quote: unichar) {
        let end = scanner.endOfQuotedString(from: index, quote: quote, escaping: false)
        tokens.add(.variable, index..<end)
        index = end
    }

    /// `$1` is a parameter and `$tag$` opens a body that runs to the next
    /// `$tag$`; any other `$` is an operator.
    private mutating func scanDollar() {
        let next = scanner.character(at: index + 1)
        let tagEnd = scanner.endOfRun(from: index + 1, while: RowScanner.isIdentifierCharacter)
        if RowScanner.isDigit(next) {
            tokens.add(.variable, index..<tagEnd)
            index = tagEnd
        } else if scanner.has(SQLRowScan.dollar, at: tagEnd) {
            let delimiter = scanner.source.substring(with: NSRange(location: index, length: tagEnd + 1 - index))
            scanDollarQuoted(delimiter: delimiter, tokenStart: index, contentStart: tagEnd + 1)
        } else {
            scanOperator()
        }
    }

    /// `tokenStart` is the opening delimiter, or 0 on a row that continues the body.
    private mutating func scanDollarQuoted(delimiter: String, tokenStart: Int, contentStart: Int) {
        let close = scanner.indexAfter(delimiter, from: contentStart)
        let end = close ?? scanner.length
        tokens.add(.string, tokenStart..<end)
        if close == nil {
            state = .dollarQuotedString(delimiter: delimiter)
        }
        index = end
    }

    // MARK: - Names and numbers

    /// `@name`, `@@name` and `:name`; the `::` of a cast is an operator.
    private mutating func scanVariable() {
        let isAt = scanner.character(at: index) == SQLRowScan.at
        let isCast = !isAt && scanner.has(SQLRowScan.colon, at: index - 1)
        let nameStart = isAt && scanner.has(SQLRowScan.at, at: index + 1) ? index + 2 : index + 1
        let nameEnd = scanner.endOfRun(from: nameStart, while: RowScanner.isIdentifierCharacter)
        if !isCast && SQLRowScan.isWordStart(scanner.character(at: nameStart)) {
            tokens.add(.variable, index..<nameEnd)
            index = nameEnd
        } else {
            scanOperator()
        }
    }

    private mutating func scanNumber() {
        let end = scanner.endOfRun(from: index) {
            RowScanner.isIdentifierCharacter($0) || $0 == SQLRowScan.dot
        }
        tokens.add(.number, index..<end)
        index = end
    }

    /// A keyword after a `.` is a column or table name, not a keyword.
    private mutating func scanWord() {
        let start = index
        let end = scanner.endOfRun(from: start, while: RowScanner.isIdentifierCharacter)
        let word = scanner.source.substring(with: NSRange(location: start, length: end - start)).uppercased()
        let isQualified = scanner.has(SQLRowScan.dot, at: start - 1)
        if !isQualified && SQLRowScan.literals.contains(word) {
            tokens.add(.literal, start..<end)
        } else if !isQualified && SQLRowScan.keywords.contains(word) {
            tokens.add(.keyword, start..<end)
        }
        index = end
    }

    private mutating func scanOperator() {
        if SQLRowScan.isOperator(scanner.character(at: index)) {
            tokens.add(.punctuation, index..<index + 1)
        }
        index += 1
    }

    // MARK: - Character classes

    private static func isWordStart(_ character: unichar) -> Bool {
        return RowScanner.isIdentifierCharacter(character) && !RowScanner.isDigit(character)
    }

    private static func isOperator(_ character: unichar) -> Bool {
        return "()[]{},;.=<>!+-*/%|&^~?:@$".utf16.contains(character)
    }
}
