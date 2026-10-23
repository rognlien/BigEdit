import Foundation

/// Why text could not be formatted, and where: the line and column of the
/// offending character, both counted from 1 and in characters, and its byte
/// offset from the start of the text.
struct FormattingError: Error, Equatable {
    let message: String
    let line: Int
    let column: Int
    let offset: Int
}

/// Where the next byte of a streamed text falls. A UTF-8 continuation byte
/// takes no column of its own, so columns count characters.
struct TextPosition: Equatable {

    private(set) var line = 1
    private(set) var column = 1
    private(set) var offset = 0
    let countsEveryByte: Bool

    init(encoding: TextEncoding) {
        countsEveryByte = encoding.isSingleByte
    }

    mutating func advance(past byte: UInt8) {
        if byte == 0x0A {
            line += 1
            column = 1
        } else if countsEveryByte || byte & 0xC0 != 0x80 {
            column += 1
        }
        offset += 1
    }

    /// Steps over a byte that takes no column, such as a byte order mark's.
    mutating func skip() {
        offset += 1
    }

    func error(_ message: String) -> FormattingError {
        FormattingError(message: message, line: line, column: column, offset: offset)
    }
}
