import Foundation

/// The characters in a row that draw nothing, or nothing that tells them
/// apart from an ordinary space, found so they can be marked when invisibles
/// are shown.
enum InvisibleCharacters {

    /// How a row's line ends, when the row is the line's last.
    enum LineTerminator: Equatable {
        case none
        case lineFeed
        case carriageReturnLineFeed
        /// A carriage return with no line feed after it, which only the
        /// file's final line can end with.
        case carriageReturn
    }

    enum Kind: Equatable {
        case space
        case tab
        /// A no-break, figure, ideographic or other Unicode space.
        case unusualSpace
        /// A character with no width, such as a zero-width space or joiner.
        case zeroWidth
        case control
        /// A carriage return that is not part of a CRLF line ending.
        case carriageReturn
        case lineFeed
        case carriageReturnLineFeed

        /// Whether this is a character people go looking for, which is
        /// marked more visibly than an ordinary space or line ending.
        var isProminent: Bool {
            [.unusualSpace, .zeroWidth, .control, .carriageReturn].contains(self)
        }
    }

    struct Mark: Equatable {
        let kind: Kind
        /// The character's UTF-16 offset in the row's text; a line ending's
        /// mark sits at the end of the text.
        let offset: Int
    }

    /// The marks for `text`, a row without its line ending, followed by one
    /// for `terminator`. A byte order mark that `startsDocument` is not
    /// marked: there it is the encoding's signature, not a stray character.
    static func marks(in text: String, terminator: LineTerminator, startsDocument: Bool = false) -> [Mark] {
        var marks: [Mark] = []
        var offset = 0
        for scalar in text.unicodeScalars {
            let isSignature = startsDocument && offset == 0 && scalar == "\u{FEFF}"
            if let kind = kind(of: scalar), !isSignature {
                marks.append(Mark(kind: kind, offset: offset))
            }
            offset += scalar.utf16.count
        }
        if let kind = kind(of: terminator) {
            marks.append(Mark(kind: kind, offset: offset))
        }
        return marks
    }

    private static func kind(of scalar: Unicode.Scalar) -> Kind? {
        var kind: Kind?
        switch scalar.value {
        case 0x20:
            kind = .space
        case 0x09:
            kind = .tab
        case 0x0D:
            kind = .carriageReturn
        case 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
            kind = .unusualSpace
        case 0xAD, 0x180E, 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF:
            kind = .zeroWidth
        case 0x00...0x1F, 0x7F...0x9F:
            kind = .control
        default:
            kind = nil
        }
        return kind
    }

    private static func kind(of terminator: LineTerminator) -> Kind? {
        var kind: Kind?
        switch terminator {
        case .none:
            kind = nil
        case .lineFeed:
            kind = .lineFeed
        case .carriageReturnLineFeed:
            kind = .carriageReturnLineFeed
        case .carriageReturn:
            kind = .carriageReturn
        }
        return kind
    }
}
