import Foundation

/// Text put into a document a few megabytes at a time: converted to the
/// document's encoding, its line endings to the document's, and appended to
/// the add buffer as it goes, so a huge paste is never held as bytes as well
/// as a string.
struct StreamedInsertion {

    /// UTF-16 units converted at a time; at most three bytes each.
    static let chunkLength = 1024 * 1024

    let encoding: TextEncoding
    let newline: [UInt8]

    /// Appends `text` to `document`'s add buffer and returns where it
    /// landed and whether it holds a line break — or nil when some character
    /// cannot be written in the encoding, leaving what was appended before it
    /// unreferenced.
    func append(_ text: String, to document: EditedDocument) -> (range: Range<Int>, containsNewline: Bool)? {
        let string = text as NSString
        var normalizer = LineEndingNormalizer(newline: newline)
        var buffer = [UInt8](repeating: 0, count: 3 * StreamedInsertion.chunkLength)
        let start = document.addBuffer.count
        var location = 0
        var failed = false
        while location < string.length && !failed {
            let range = NSRange(location: location, length: min(StreamedInsertion.chunkLength, string.length - location))
            let converted = convert(string, range: range, into: &buffer)
            failed = converted.next == location
            if !failed {
                append(normalizer.normalize(buffer[0..<converted.length]), to: document)
                location = converted.next
            }
        }
        append(normalizer.finish(), to: document)
        return failed ? nil : (start..<document.addBuffer.count, normalizer.containsNewline)
    }

    private func append(_ bytes: [UInt8], to document: EditedDocument) {
        if !bytes.isEmpty {
            _ = document.appendToAddBuffer(bytes)
        }
    }

    /// Converts as much of `range` as fits and the encoding can write.
    /// Returns the bytes written and where the next conversion starts.
    private func convert(_ string: NSString, range: NSRange,
                         into buffer: inout [UInt8]) -> (length: Int, next: Int) {
        var used = 0
        var remaining = NSRange(location: range.location, length: 0)
        buffer.withUnsafeMutableBytes { bytes in
            _ = string.getBytes(bytes.baseAddress, maxLength: bytes.count, usedLength: &used,
                                encoding: encoding.foundationEncoding.rawValue, options: [],
                                range: range, remaining: &remaining)
        }
        return (used, remaining.location)
    }
}

/// Turns CR LF and lone CR into LF, and LF into `newline`, across chunks: a
/// CR ending one chunk is held until the next shows whether an LF follows.
/// Every encoding BigEdit edits writes CR and LF as single bytes that occur
/// in no other character.
struct LineEndingNormalizer {

    let newline: [UInt8]
    private(set) var containsNewline = false
    private var pendingCarriageReturn = false

    init(newline: [UInt8]) {
        self.newline = newline
    }

    mutating func normalize(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var result: [UInt8]
        if !pendingCarriageReturn && newline == [0x0A] && !bytes.contains(0x0D) {
            result = Array(bytes)
            containsNewline = containsNewline || bytes.contains(0x0A)
        } else {
            result = []
            result.reserveCapacity(bytes.count + bytes.count / 8)
            for byte in bytes {
                append(byte, to: &result)
            }
        }
        return result
    }

    /// What is still held back at the end of the text.
    mutating func finish() -> [UInt8] {
        var result: [UInt8] = []
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            appendNewline(to: &result)
        }
        return result
    }

    private mutating func append(_ byte: UInt8, to result: inout [UInt8]) {
        let completesPair = pendingCarriageReturn && byte == 0x0A
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            appendNewline(to: &result)
        }
        if byte == 0x0D {
            pendingCarriageReturn = true
        } else if byte == 0x0A && !completesPair {
            appendNewline(to: &result)
        } else if byte != 0x0A {
            result.append(byte)
        }
    }

    private mutating func appendNewline(to result: inout [UInt8]) {
        result.append(contentsOf: newline)
        containsNewline = true
    }
}
