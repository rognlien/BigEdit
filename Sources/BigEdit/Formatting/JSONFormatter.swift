import Foundation

/// Pretty prints or compacts JSON as a stream: bytes go in a window at a
/// time and formatted bytes come out, with nothing held beyond a line's
/// worth of tokens and the stack of open containers.
///
/// It checks the grammar but builds no values, so strings, numbers and
/// keys come out exactly as they went in — `1.10`, `1e400`, `-0` and every
/// escape included — in their original order. Several values one after
/// another, as in JSON Lines, are each put on a line of their own.
struct JSONFormatter: StreamingFormatter {

    enum Container {
        case object
        case array
    }

    /// What the grammar allows next.
    enum Expectation {
        case topLevelValue
        case value
        case valueOrClose
        case key
        case keyOrClose
        case colon
        case separatorOrClose
    }

    enum Scanning {
        case betweenTokens
        case string(isKey: Bool, escape: StringEscape)
        case number(NumberPart)
        case literal(Literal, matched: Int)
    }

    enum StringEscape {
        case none
        case escaped
        case unicode(remaining: Int)
    }

    /// Where a number is in `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
    enum NumberPart {
        case sign
        case zero
        case integer
        case point
        case fraction
        case exponentMark
        case exponentSign
        case exponent
    }

    enum Literal {
        case trueValue
        case falseValue
        case nullValue
    }

    struct OpenContainer {
        let kind: Container
        let position: TextPosition
    }

    /// Scalar bytes are passed to the layout at least this often.
    static let scalarChunkLength = 4096

    var byteOrderMark: ByteOrderMarkReader
    var layout: JSONLayout
    var position: TextPosition
    var tokenStart: TextPosition
    var scanning = Scanning.betweenTokens
    var expectation = Expectation.topLevelValue
    var openContainers: [OpenContainer] = []
    var scalar: [UInt8] = []
    var hasValue = false
    var endsWithNewline = false

    init(style: FormattingStyle, options: FormattingOptions = FormattingOptions()) {
        layout = JSONLayout(style: style, options: options)
        position = TextPosition(encoding: options.encoding)
        byteOrderMark = ByteOrderMarkReader(encoding: options.encoding)
        tokenStart = position
    }

    mutating func feed(_ bytes: ArraySlice<UInt8>) throws {
        for byte in bytes {
            if byteOrderMark.accepts(byte, at: position.offset) {
                layout.writeUncounted(byte)
                position.skip()
            } else {
                try consume(byte)
                position.advance(past: byte)
            }
        }
        passScalar()
    }

    mutating func finish() throws {
        try finishToken()
        if let open = openContainers.last {
            throw open.position.error("\(open.kind == .object ? "“{”" : "“[”") is never closed")
        }
        layout.finish(endingWithNewline: hasValue && endsWithNewline)
    }

    mutating func takeOutput() -> [UInt8] {
        layout.takeOutput()
    }

    private mutating func consume(_ byte: UInt8) throws {
        switch scanning {
        case .betweenTokens:
            try consumeBetweenTokens(byte)
        case .string(let isKey, let escape):
            try consumeString(byte, isKey: isKey, escape: escape)
        case .number(let part):
            try consumeNumber(byte, part: part)
        case .literal(let literal, let matched):
            try consumeLiteral(byte, literal: literal, matched: matched)
        }
    }

    mutating func consumeBetweenTokens(_ byte: UInt8) throws {
        switch byte {
        case 0x20, 0x09, 0x0D:
            break
        case 0x0A:
            endsWithNewline = true
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            try open(byte)
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            try close(byte)
        case UInt8(ascii: ":"):
            try separate(byte, expected: .colon, next: .value)
        case UInt8(ascii: ","):
            try separate(byte, expected: .separatorOrClose,
                         next: openContainers.last?.kind == .object ? .key : .value)
        case UInt8(ascii: "\""):
            try beginString()
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            try beginNumber(byte)
        case UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"):
            try beginLiteral(byte)
        case UInt8(ascii: "/"):
            throw position.error("Comments are not allowed in JSON")
        default:
            throw unexpected(byte)
        }
    }

    // MARK: - Structure

    private mutating func open(_ bracket: UInt8) throws {
        beginToken()
        try requireValue(bracket)
        let kind: Container = bracket == UInt8(ascii: "{") ? .object : .array
        openContainers.append(OpenContainer(kind: kind, position: position))
        expectation = kind == .object ? .keyOrClose : .valueOrClose
        layout.handle(.open(bracket))
    }

    private mutating func close(_ bracket: UInt8) throws {
        beginToken()
        let kind: Container = bracket == UInt8(ascii: "}") ? .object : .array
        let emptyExpectation: Expectation = kind == .object ? .keyOrClose : .valueOrClose
        guard openContainers.last?.kind == kind,
              expectation == .separatorOrClose || expectation == emptyExpectation else {
            throw unexpected(bracket)
        }
        openContainers.removeLast()
        layout.handle(.close(bracket))
        finishValue()
    }

    private mutating func separate(_ separator: UInt8, expected: Expectation, next: Expectation) throws {
        beginToken()
        guard expectation == expected else {
            throw unexpected(separator)
        }
        expectation = next
        layout.handle(separator == UInt8(ascii: ":") ? .colon : .comma)
    }

    /// A token starts here: whitespace before it no longer ends the input.
    mutating func beginToken() {
        endsWithNewline = false
        tokenStart = position
    }

    mutating func requireValue(_ byte: UInt8) throws {
        guard [.topLevelValue, .value, .valueOrClose].contains(expectation) else {
            throw unexpected(byte)
        }
        hasValue = true
    }

    mutating func finishValue() {
        expectation = openContainers.isEmpty ? .topLevelValue : .separatorOrClose
    }

    /// Hands the scalar bytes read so far to the layout.
    mutating func passScalar() {
        if !scalar.isEmpty {
            layout.handle(.scalarBytes(scalar))
            scalar.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Errors

    func unexpected(_ byte: UInt8) -> FormattingError {
        position.error("Expected \(expectedDescription) but found \(JSONFormatter.describe(byte))")
    }

    private var expectedDescription: String {
        let closing = openContainers.last?.kind == .object ? "“}”" : "“]”"
        var description: String
        switch expectation {
        case .topLevelValue, .value: description = "a value"
        case .valueOrClose: description = "a value or “]”"
        case .key: description = "a string key"
        case .keyOrClose: description = "a string key or “}”"
        case .colon: description = "“:”"
        case .separatorOrClose: description = "“,” or \(closing)"
        }
        return description
    }

    static func describe(_ byte: UInt8) -> String {
        var description = "a non-ASCII character"
        if byte >= 0x20 && byte < 0x7F {
            description = "“\(Character(UnicodeScalar(byte)))”"
        } else if byte < 0x20 || byte == 0x7F {
            description = String(format: "the control character 0x%02X", byte)
        }
        return description
    }
}
