import Foundation

/// The text encodings BigEdit decodes.
///
/// UTF-8 is the native one: it is what editing produces and what every byte
/// offset in the app assumes. The single-byte encodings are decoded for
/// reading, copying, searching and counting — one byte is one character,
/// which keeps every byte↔character mapping exact — but a document in one
/// stays read-only, since edits are spliced as UTF-8 bytes. UTF-16 is
/// detected and labelled but not decoded: the line index finds newlines by
/// the `0x0A` byte, and two-byte units would need an indexer that understands
/// them.
enum TextEncoding: Equatable {
    case utf8
    case windows1252
    case latin1

    var label: String {
        switch self {
        case .utf8: return "UTF-8"
        case .windows1252: return "Windows-1252"
        case .latin1: return "ISO-8859-1"
        }
    }

    var isUTF8: Bool {
        self == .utf8
    }

    /// Whether every byte is exactly one character.
    var isSingleByte: Bool {
        self != .utf8
    }

    private var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .windows1252: return .windowsCP1252
        case .latin1: return .isoLatin1
        }
    }

    /// Decodes `bytes` without failing: invalid UTF-8 becomes U+FFFD, and a
    /// byte Windows-1252 leaves undefined is read as Latin-1.
    func decode<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var result: String
        switch self {
        case .utf8:
            result = String(decoding: bytes, as: UTF8.self)
        case .windows1252, .latin1:
            let array = Array(bytes)
            result = String(bytes: array, encoding: foundationEncoding)
                ?? String(bytes: array, encoding: .isoLatin1)
                ?? ""
        }
        return result
    }

    /// Decodes `bytes` only if they are valid in this encoding. Every byte is
    /// valid in the single-byte encodings; only UTF-8 can fail.
    func decodeStrictly(_ bytes: [UInt8]) -> String? {
        var result: String?
        switch self {
        case .utf8:
            result = String(bytes: bytes, encoding: .utf8)
        case .windows1252, .latin1:
            result = decode(bytes)
        }
        return result
    }

    /// `text` as bytes in this encoding, or `nil` when a character has no
    /// representation in it — a query like "🙂" cannot occur in a Latin-1
    /// file, so a search for it has nothing to look for.
    func encode(_ text: String) -> [UInt8]? {
        var result: [UInt8]?
        switch self {
        case .utf8:
            result = Array(text.utf8)
        case .windows1252, .latin1:
            result = text.data(using: foundationEncoding).map(Array.init)
        }
        return result
    }

    /// How many bytes `scalar` occupies in this encoding. This is what turns a
    /// character position back into a byte offset.
    func byteLength(of scalar: Unicode.Scalar) -> Int {
        isSingleByte ? 1 : UTF8.width(scalar)
    }
}
