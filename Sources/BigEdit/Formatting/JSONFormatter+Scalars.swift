import Foundation

/// Reading strings, numbers and the literals byte by byte, checking each
/// against the grammar and passing it on unchanged.
extension JSONFormatter {

    // MARK: - Strings

    mutating func beginString() throws {
        beginToken()
        let isKey = expectation == .key || expectation == .keyOrClose
        if !isKey {
            try requireValue(UInt8(ascii: "\""))
        }
        scanning = .string(isKey: isKey, escape: .none)
        layout.handle(.scalarBegin)
        append(UInt8(ascii: "\""))
    }

    mutating func consumeString(_ byte: UInt8, isKey: Bool, escape: StringEscape) throws {
        switch escape {
        case .none:
            try consumeUnescaped(byte, isKey: isKey)
        case .escaped:
            guard Array("\"\\/bfnrtu".utf8).contains(byte) else {
                throw position.error("“\\\(Character(UnicodeScalar(byte)))” is not a valid escape")
            }
            let next: StringEscape = byte == UInt8(ascii: "u") ? .unicode(remaining: 4) : .none
            scanning = .string(isKey: isKey, escape: next)
            append(byte)
        case .unicode(let remaining):
            guard JSONFormatter.isHexDigit(byte) else {
                throw position.error("Expected a hexadecimal digit in a \\u escape")
            }
            scanning = .string(isKey: isKey, escape: remaining > 1 ? .unicode(remaining: remaining - 1) : .none)
            append(byte)
        }
    }

    private mutating func consumeUnescaped(_ byte: UInt8, isKey: Bool) throws {
        if byte < 0x20 {
            throw position.error("A string cannot contain \(JSONFormatter.describe(byte)); escape it")
        }
        append(byte)
        if byte == UInt8(ascii: "\\") {
            scanning = .string(isKey: isKey, escape: .escaped)
        } else if byte == UInt8(ascii: "\"") {
            passScalar()
            scanning = .betweenTokens
            if isKey {
                expectation = .colon
            } else {
                finishValue()
            }
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    // MARK: - Numbers

    mutating func beginNumber(_ byte: UInt8) throws {
        beginToken()
        try requireValue(byte)
        layout.handle(.scalarBegin)
        scanning = .number(JSONFormatter.numberPart(after: nil, byte) ?? .sign)
        append(byte)
    }

    /// A byte that cannot continue the number ends it, and is then read as
    /// whatever follows it.
    mutating func consumeNumber(_ byte: UInt8, part: NumberPart) throws {
        if JSONFormatter.isNumberByte(byte) {
            guard let next = JSONFormatter.numberPart(after: part, byte) else {
                throw position.error("Invalid number")
            }
            scanning = .number(next)
            append(byte)
        } else {
            try finishNumber(part)
            try consumeBetweenTokens(byte)
        }
    }

    private mutating func finishNumber(_ part: NumberPart) throws {
        guard [.zero, .integer, .fraction, .exponent].contains(part) else {
            throw position.error("Invalid number")
        }
        passScalar()
        scanning = .betweenTokens
        finishValue()
    }

    private static let numberPunctuation = Set("+-.eE".utf8)

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        isDigit(byte) || numberPunctuation.contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// The part of the number `byte` puts it in after `part` (nil before
    /// the first byte), or nil if the number cannot continue with it.
    private static func numberPart(after part: NumberPart?, _ byte: UInt8) -> NumberPart? {
        let digit = isDigit(byte)
        let isZero = byte == UInt8(ascii: "0")
        let isExponent = byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
        var next: NumberPart?
        switch part {
        case nil:
            next = byte == UInt8(ascii: "-") ? .sign : (isZero ? .zero : (digit ? .integer : nil))
        case .sign:
            next = isZero ? .zero : (digit ? .integer : nil)
        case .zero, .integer:
            next = byte == UInt8(ascii: ".") ? .point : (isExponent ? .exponentMark : nil)
            if part == .integer && digit {
                next = .integer
            }
        case .point, .fraction:
            next = digit ? .fraction : (part == .fraction && isExponent ? .exponentMark : nil)
        case .exponentMark:
            next = byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") ? .exponentSign : (digit ? .exponent : nil)
        case .exponentSign, .exponent:
            next = digit ? .exponent : nil
        }
        return next
    }

    // MARK: - Literals

    mutating func beginLiteral(_ byte: UInt8) throws {
        beginToken()
        try requireValue(byte)
        let literal: Literal = byte == UInt8(ascii: "t") ? .trueValue : (byte == UInt8(ascii: "f") ? .falseValue : .nullValue)
        layout.handle(.scalarBegin)
        scanning = .literal(literal, matched: 1)
        append(byte)
    }

    mutating func consumeLiteral(_ byte: UInt8, literal: Literal, matched: Int) throws {
        let spelling = JSONFormatter.spelling(of: literal)
        guard spelling[matched] == byte else {
            throw tokenStart.error("Expected “\(String(decoding: spelling, as: UTF8.self))”")
        }
        append(byte)
        if matched + 1 == spelling.count {
            passScalar()
            scanning = .betweenTokens
            finishValue()
        } else {
            scanning = .literal(literal, matched: matched + 1)
        }
    }

    private static let spellings: [Literal: [UInt8]] = [
        .trueValue: Array("true".utf8), .falseValue: Array("false".utf8), .nullValue: Array("null".utf8)
    ]

    private static func spelling(of literal: Literal) -> [UInt8] {
        spellings[literal] ?? []
    }

    // MARK: - The end of the input

    /// Ends whatever token the input stopped in.
    mutating func finishToken() throws {
        switch scanning {
        case .betweenTokens:
            break
        case .number(let part):
            try finishNumber(part)
        case .string:
            throw tokenStart.error("The string is never closed")
        case .literal(let literal, _):
            throw tokenStart.error("Expected “\(String(decoding: JSONFormatter.spelling(of: literal), as: UTF8.self))”")
        }
    }

    /// Adds `byte` to the scalar being read, passing it on in chunks.
    private mutating func append(_ byte: UInt8) {
        scalar.append(byte)
        if scalar.count >= JSONFormatter.scalarChunkLength {
            passScalar()
        }
    }
}
