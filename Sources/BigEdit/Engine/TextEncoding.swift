import Foundation

/// The text encodings BigEdit decodes.
///
/// A document's bytes stay in its own encoding: typed and pasted text is
/// encoded before it is spliced in, so a save writes the bytes unchanged and
/// every byte offset keeps its meaning. In the single-byte encodings one byte
/// is one character, which keeps every byte↔character mapping exact. UTF-16
/// is detected and labelled but not decoded: the line index finds newlines by
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

    /// The first character of `text` this encoding has no representation
    /// for, or `nil` when all of it can be written.
    func firstUnrepresentableCharacter(in text: String) -> Character? {
        var result: Character?
        if encode(text) == nil {
            result = text.first { encode(String($0)) == nil }
        }
        return result
    }

    /// `bytes` in this encoding rewritten as UTF-8. The single-byte encodings
    /// convert byte by byte, so a window cut anywhere converts exactly as the
    /// whole would, and a byte Windows-1252 leaves undefined becomes its
    /// Latin-1 character, as it does when decoded for display.
    func transcodedToUTF8(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8]
        switch self {
        case .utf8:
            result = bytes
        case .windows1252:
            result = TextEncoding.transcode(bytes, with: TextEncoding.windows1252ToUTF8)
        case .latin1:
            result = TextEncoding.transcode(bytes, with: TextEncoding.latin1ToUTF8)
        }
        return result
    }

    private static let windows1252ToUTF8 = utf8Table(for: .windows1252)
    private static let latin1ToUTF8 = utf8Table(for: .latin1)

    /// The UTF-8 bytes of every one of the 256 single-byte characters.
    private static func utf8Table(for encoding: TextEncoding) -> [[UInt8]] {
        (0...255).map { Array(encoding.decode([UInt8($0)]).utf8) }
    }

    private static func transcode(_ bytes: [UInt8], with table: [[UInt8]]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count + bytes.count / 4)
        for byte in bytes {
            result.append(contentsOf: table[Int(byte)])
        }
        return result
    }

    /// How many bytes `scalar` occupies in this encoding. This is what turns a
    /// character position back into a byte offset.
    func byteLength(of scalar: Unicode.Scalar) -> Int {
        isSingleByte ? 1 : UTF8.width(scalar)
    }
}
