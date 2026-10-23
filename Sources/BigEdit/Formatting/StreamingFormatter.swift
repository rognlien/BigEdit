import Foundation

/// A formatter given its input a window at a time, which hands back what it
/// has produced so far after each, so text of any size streams through it.
/// Every token is copied byte for byte; only the whitespace between tokens
/// is rewritten.
protocol StreamingFormatter {

    /// Consumes the next part of the input. Throws at the first byte that
    /// makes the input invalid.
    mutating func feed(_ bytes: ArraySlice<UInt8>) throws

    /// Ends the input, throwing if it stopped short of being complete.
    mutating func finish() throws

    /// The output produced since the last call.
    mutating func takeOutput() -> [UInt8]
}

extension StreamingFormatter {

    /// Formats `bytes` whole.
    mutating func format(_ bytes: [UInt8]) throws -> [UInt8] {
        try feed(bytes[...])
        try finish()
        return takeOutput()
    }
}

/// Formatted bytes as they are produced, and the column the next one lands
/// in — what fitting a structure within the line width measures.
struct FormattedOutput {

    private(set) var bytes: [UInt8] = []
    private(set) var column = 0
    private let options: FormattingOptions

    init(options: FormattingOptions) {
        self.options = options
    }

    mutating func write(_ byte: UInt8) {
        bytes.append(byte)
        column = byte == 0x0A ? 0 : column + FormattedOutput.columns(of: byte, options: options)
    }

    mutating func write<Bytes: Collection>(_ text: Bytes) where Bytes.Element == UInt8 {
        bytes.append(contentsOf: text)
        for byte in text {
            column = byte == 0x0A ? 0 : column + FormattedOutput.columns(of: byte, options: options)
        }
    }

    /// Writes a byte that takes no column, such as a byte order mark's.
    mutating func writeUncounted(_ byte: UInt8) {
        bytes.append(byte)
    }

    /// Starts a new line indented `depth` levels.
    mutating func writeNewline(indentedBy depth: Int) {
        bytes.append(contentsOf: options.newline)
        column = 0
        writeIndentation(depth)
    }

    mutating func writeIndentation(_ depth: Int) {
        for _ in 0..<max(0, depth) {
            bytes.append(contentsOf: options.indentation.bytes)
        }
        column += max(0, depth) * options.indentation.columns
    }

    mutating func writeSpaces(_ count: Int) {
        bytes.append(contentsOf: repeatElement(0x20, count: max(0, count)))
        column += max(0, count)
    }

    mutating func take() -> [UInt8] {
        let taken = bytes
        bytes = []
        return taken
    }

    /// The columns `text` takes, a character each.
    static func columns<Bytes: Collection>(of text: Bytes, options: FormattingOptions) -> Int
    where Bytes.Element == UInt8 {
        var count = 0
        for byte in text {
            count += columns(of: byte, options: options)
        }
        return count
    }

    private static func columns(of byte: UInt8, options: FormattingOptions) -> Int {
        options.encoding.isSingleByte || byte & 0xC0 != 0x80 ? 1 : 0
    }
}

/// Recognises a UTF-8 byte order mark at the very start of the input, which
/// is copied through rather than read as text.
struct ByteOrderMarkReader {

    private static let mark: [UInt8] = [0xEF, 0xBB, 0xBF]
    private let isEnabled: Bool
    private var matched = 0

    init(encoding: TextEncoding) {
        isEnabled = encoding.isUTF8
    }

    /// Whether `byte`, at `offset` in the input, belongs to a leading mark.
    mutating func accepts(_ byte: UInt8, at offset: Int) -> Bool {
        let accepted = isEnabled && offset == matched && matched < ByteOrderMarkReader.mark.count
            && ByteOrderMarkReader.mark[matched] == byte
        if accepted {
            matched += 1
        }
        return accepted
    }
}
