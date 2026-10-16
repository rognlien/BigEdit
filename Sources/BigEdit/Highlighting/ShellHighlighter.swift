import Foundation

/// A shell-script highlighter for sh, bash, zsh and ksh. It tokenizes one row
/// at a time; a quoted string or a here-document still open at the end of a
/// row is carried into the next.
///
/// Recognises `#` comments (the `#!` line among them), single, double and
/// `$'…'` quoted strings, parameter expansions (`$name`, `${…}`, `$1`, `$?`),
/// command substitution, reserved words and the declaring builtins where a
/// command can start, assignments, function definitions, numbers, operators
/// and redirections, and here-documents.
enum ShellHighlighter: Highlighter {

    /// Whether the row begins inside a string or a here-document.
    enum State: Hashable {
        case normal
        case singleQuotedString
        case doubleQuotedString
        case hereDocument(delimiter: String, stripsTabs: Bool, expands: Bool)
    }

    static let initialState = State.normal

    /// Stateful entry: `startState` says whether the row begins inside a
    /// string or a here-document. Returns the row's tokens and its end state.
    static func tokens(_ text: String, startState: ShellHighlighter.State) -> ([Token], ShellHighlighter.State) {
        var scan = ShellRowScan(text)
        scan.run(from: startState)
        return (scan.tokens, scan.state)
    }

    /// The tokens of a row that starts outside any string or here-document.
    static func tokens(_ text: String) -> [Token] {
        return tokens(text, startState: .normal).0
    }

    static func endState(_ text: String, start: ShellHighlighter.State) -> ShellHighlighter.State {
        return tokens(text, startState: start).1
    }
}

/// The scan of one row, kept as a value so each construct gets a small
/// method of its own.
private struct ShellRowScan {

    /// What the next bare word is, judging by the words before it.
    private enum Expectation {
        case command
        case argument
        case functionName
        case loopVariable
    }

    private static let hash = unichar(UInt8(ascii: "#"))
    private static let singleQuote = unichar(UInt8(ascii: "'"))
    private static let doubleQuote = unichar(UInt8(ascii: "\""))
    private static let dollar = unichar(UInt8(ascii: "$"))
    private static let backtick = unichar(UInt8(ascii: "`"))
    private static let openBrace = unichar(UInt8(ascii: "{"))
    private static let openParenthesis = unichar(UInt8(ascii: "("))
    private static let dash = unichar(UInt8(ascii: "-"))
    private static let backslash = RowScanner.backslash

    /// Reserved words, and the builtins that declare or leave, coloured where
    /// a command can start.
    private static let keywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "select",
        "while", "until", "do", "done", "function", "time", "coproc",
        "local", "export", "declare", "readonly", "typeset", "unset",
        "return", "exit", "break", "continue"
    ]
    private static let groupingWords: Set<String> = ["{", "}", "[[", "]]", "!"]
    private static let specialParameters: Set<unichar> = Set("@*#?$!-".utf16)
    private static let commandSeparators: Set<unichar> = Set("|&;()".utf16)

    private let scanner: RowScanner
    private(set) var tokens: [Token] = []
    private(set) var state = ShellHighlighter.State.normal
    private var index = 0
    private var expectation = Expectation.command
    private var expectsIn = false
    private var pendingHereDocument: ShellHighlighter.State?

    init(_ text: String) {
        scanner = RowScanner(text)
    }

    mutating func run(from startState: ShellHighlighter.State) {
        switch startState {
        case .hereDocument(let delimiter, let stripsTabs, let expands):
            continueHereDocument(delimiter: delimiter, stripsTabs: stripsTabs, expands: expands)
        case .singleQuotedString:
            scanSingleQuoted(tokenStart: 0, contentStart: 0)
        case .doubleQuotedString:
            scanDoubleQuoted(tokenStart: 0, contentStart: 0)
        default:
            break
        }
        while index < scanner.length {
            scanNext()
        }
        if state == .normal, let pendingHereDocument {
            state = pendingHereDocument
        }
    }

    // MARK: - Dispatch

    private mutating func scanNext() {
        let character = scanner.character(at: index)
        if RowScanner.isWhitespace(character) {
            index += 1
        } else if character == ShellRowScan.hash && isWordStart {
            tokens.add(.comment, index..<scanner.length)
            index = scanner.length
        } else if character == ShellRowScan.singleQuote {
            scanSingleQuoted(tokenStart: index, contentStart: index + 1)
        } else if character == ShellRowScan.doubleQuote {
            scanDoubleQuoted(tokenStart: index, contentStart: index + 1)
        } else if character == ShellRowScan.dollar {
            scanDollar()
        } else if character == ShellRowScan.backslash {
            index = min(index + 2, scanner.length)
            expectation = .argument
        } else if character == ShellRowScan.backtick {
            tokens.add(.punctuation, index..<index + 1)
            index += 1
            expectation = .command
        } else if ShellRowScan.isOperator(character) {
            scanOperator()
        } else {
            scanWord()
        }
    }

    /// A `#` starts a comment only at the start of a word.
    private var isWordStart: Bool {
        let previous = scanner.character(at: index - 1)
        return index == 0 || RowScanner.isWhitespace(previous) || ShellRowScan.isOperator(previous)
    }

    // MARK: - Strings

    /// `tokenStart` is the opening quote, or 0 on a row that continues the string.
    private mutating func scanSingleQuoted(tokenStart: Int, contentStart: Int) {
        let close = scanner.indexAfter("'", from: contentStart)
        let end = close ?? scanner.length
        tokens.add(.string, tokenStart..<end)
        if close == nil {
            state = .singleQuotedString
        }
        index = end
        expectation = .argument
    }

    /// Expansions inside the string are coloured on top of it.
    private mutating func scanDoubleQuoted(tokenStart: Int, contentStart: Int) {
        var position = contentStart
        var closed = false
        var expansions: [Token] = []
        while position < scanner.length && !closed {
            let character = scanner.character(at: position)
            if character == ShellRowScan.backslash {
                position += 2
            } else if character == ShellRowScan.doubleQuote {
                closed = true
                position += 1
            } else if character == ShellRowScan.dollar {
                let end = endOfExpansion(from: position)
                expansions.add(.variable, position..<end)
                position = max(end, position + 1)
            } else {
                position += 1
            }
        }
        let end = min(position, scanner.length)
        tokens.add(.string, tokenStart..<end)
        tokens.append(contentsOf: expansions)
        if !closed {
            state = .doubleQuotedString
        }
        index = end
        expectation = .argument
    }

    // MARK: - Expansions

    private mutating func scanDollar() {
        let next = scanner.character(at: index + 1)
        if next == ShellRowScan.singleQuote {
            let end = scanner.endOfQuotedString(from: index + 1, quote: next, escaping: true)
            tokens.add(.string, index..<end)
            index = end
            expectation = .argument
        } else if next == ShellRowScan.doubleQuote {
            scanDoubleQuoted(tokenStart: index, contentStart: index + 2)
        } else if next == ShellRowScan.openParenthesis {
            scanCommandSubstitution()
        } else {
            let end = endOfExpansion(from: index)
            tokens.add(.variable, index..<end)
            index = max(end, index + 1)
            expectation = .argument
        }
    }

    /// `$(` and `$((` open a command that is scanned like any other.
    private mutating func scanCommandSubstitution() {
        let isArithmetic = scanner.has(ShellRowScan.openParenthesis, at: index + 2)
        let end = index + (isArithmetic ? 3 : 2)
        tokens.add(.punctuation, index..<end)
        index = end
        expectation = .command
    }

    /// The index just past the parameter expansion whose `$` is at `start`,
    /// or `start` itself when the `$` begins none.
    private func endOfExpansion(from start: Int) -> Int {
        let next = scanner.character(at: start + 1)
        var end = start
        if next == ShellRowScan.openBrace {
            end = scanner.indexAfter("}", from: start + 2) ?? scanner.length
        } else if RowScanner.isIdentifierCharacter(next) && !RowScanner.isDigit(next) {
            end = scanner.endOfRun(from: start + 1, while: RowScanner.isIdentifierCharacter)
        } else if RowScanner.isDigit(next) || ShellRowScan.specialParameters.contains(next) {
            end = start + 2
        }
        return end
    }

    // MARK: - Operators and here-documents

    private mutating func scanOperator() {
        if scanner.matches("<<<", at: index) {
            tokens.add(.punctuation, index..<index + 3)
            index += 3
            expectation = .argument
        } else if scanner.matches("<<", at: index) {
            scanHereDocumentOperator()
        } else {
            let end = scanner.endOfRun(from: index, while: ShellRowScan.isOperator)
            let run = scanner.source.substring(with: NSRange(location: index, length: end - index))
            let separates = run.utf16.contains { ShellRowScan.commandSeparators.contains($0) }
            tokens.add(.punctuation, index..<end)
            index = end
            expectation = separates ? .command : .argument
        }
    }

    /// `<<WORD`, `<<-WORD`, `<<'WORD'` or `<<"WORD"`: the rows after this one,
    /// up to a row holding just the word, are the document.
    private mutating func scanHereDocumentOperator() {
        var position = index + 2
        let stripsTabs = scanner.has(ShellRowScan.dash, at: position)
        if stripsTabs {
            position += 1
        }
        tokens.add(.punctuation, index..<position)
        let delimiterStart = scanner.skipWhitespace(from: position)
        let (delimiter, delimiterEnd, isQuoted) = hereDocumentDelimiter(at: delimiterStart)
        if !delimiter.isEmpty {
            tokens.add(.string, delimiterStart..<delimiterEnd)
            pendingHereDocument = pendingHereDocument
                ?? .hereDocument(delimiter: delimiter, stripsTabs: stripsTabs, expands: !isQuoted)
        }
        index = max(delimiterEnd, position)
        expectation = .argument
    }

    /// The delimiter word at `start` with any quoting removed, where it ends,
    /// and whether it was quoted or escaped, which turns off expansion.
    private func hereDocumentDelimiter(at start: Int) -> (String, Int, Bool) {
        let opening = scanner.character(at: start)
        let isQuoted = opening == ShellRowScan.singleQuote || opening == ShellRowScan.doubleQuote
        let isEscaped = opening == ShellRowScan.backslash
        let wordStart = isEscaped ? start + 1 : start
        let end = isQuoted
            ? scanner.endOfQuotedString(from: start, quote: opening, escaping: false)
            : scanner.endOfRun(from: wordStart) { !RowScanner.isWhitespace($0) && !ShellRowScan.isOperator($0) }
        let wordRange = isQuoted
            ? NSRange(location: start + 1, length: max(end - start - 2, 0))
            : NSRange(location: wordStart, length: end - wordStart)
        return (scanner.source.substring(with: wordRange), end, isQuoted || isEscaped)
    }

    /// A row of the document, or the row that ends it. Unless the delimiter
    /// was quoted, the shell expands parameters in the document.
    private mutating func continueHereDocument(delimiter: String, stripsTabs: Bool, expands: Bool) {
        let text = scanner.source as String
        let candidate = stripsTabs ? String(text.drop { $0 == "\t" }) : text
        let ends = candidate == delimiter
        tokens.add(.string, 0..<scanner.length)
        if expands && !ends {
            addExpansions()
        }
        state = ends ? .normal : .hereDocument(delimiter: delimiter, stripsTabs: stripsTabs, expands: expands)
        index = scanner.length
    }

    private mutating func addExpansions() {
        var position = 0
        while position < scanner.length {
            let character = scanner.character(at: position)
            if character == ShellRowScan.backslash {
                position += 2
            } else if character == ShellRowScan.dollar {
                let end = endOfExpansion(from: position)
                tokens.add(.variable, position..<end)
                position = max(end, position + 1)
            } else {
                position += 1
            }
        }
    }

    // MARK: - Words

    private mutating func scanWord() {
        let start = index
        let end = scanner.endOfRun(from: start, while: ShellRowScan.isWordCharacter)
        let word = scanner.source.substring(with: NSRange(location: start, length: end - start))
        index = end
        classify(word, range: start..<end)
    }

    private mutating func classify(_ word: String, range: Range<Int>) {
        let isCommand = expectation == .command
        if word.utf16.allSatisfy(RowScanner.isDigit) {
            tokens.add(.number, range)
            expectation = .argument
        } else if isCommand, let nameLength = assignmentNameLength(word) {
            tokens.add(.variable, range.lowerBound..<range.lowerBound + nameLength)
        } else if isCommand && ShellRowScan.keywords.contains(word) {
            tokens.add(.keyword, range)
            expectWordAfter(keyword: word)
        } else if expectsIn && word == "in" {
            tokens.add(.keyword, range)
            expectsIn = false
            expectation = .argument
        } else if ShellRowScan.groupingWords.contains(word) {
            tokens.add(.punctuation, range)
            expectation = .command
        } else {
            classifyName(range: range)
        }
    }

    /// A function's name, a loop's variable, or a plain word.
    private mutating func classifyName(range: Range<Int>) {
        let definesFunction = expectation == .command
            && scanner.matches("()", at: scanner.skipWhitespace(from: range.upperBound))
        if definesFunction || expectation == .functionName {
            tokens.add(.declaration, range)
        } else if expectation == .loopVariable {
            tokens.add(.variable, range)
        }
        expectation = .argument
    }

    private mutating func expectWordAfter(keyword: String) {
        switch keyword {
        case "for", "select":
            expectation = .loopVariable
            expectsIn = true
        case "case":
            expectation = .argument
            expectsIn = true
        case "function":
            expectation = .functionName
        default:
            expectation = .command
        }
    }

    /// The length of `NAME` in `NAME=value` or `NAME+=value`, or nil when the
    /// word is not an assignment.
    private func assignmentNameLength(_ word: String) -> Int? {
        let characters = Array(word.utf16)
        let nameLength = characters.prefix { RowScanner.isIdentifierCharacter($0) }.count
        let rest = word.utf16.dropFirst(nameLength)
        let assigns = rest.starts(with: "=".utf16) || rest.starts(with: "+=".utf16)
        let isName = nameLength > 0 && !RowScanner.isDigit(characters[0])
        return isName && assigns ? nameLength : nil
    }

    // MARK: - Character classes

    private static func isOperator(_ character: unichar) -> Bool {
        return "|&;<>()".utf16.contains(character)
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        let isQuoting = character == singleQuote || character == doubleQuote
            || character == backslash || character == backtick
        return !RowScanner.isWhitespace(character) && !isOperator(character)
            && !isQuoting && character != dollar
    }
}
