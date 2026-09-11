import Foundation

/// A document's bytes seen as lines, and put back together again.
///
/// `LineProcessor` works on lines without their terminators, so something has
/// to remember what the terminators were. Getting that wrong would rewrite
/// every line ending in the file as a side effect of sorting it, so the
/// splitting and joining live here where they can be tested on their own.
struct LineDocument {

    /// The lines, without their terminators.
    let lines: [String]

    /// The terminator to write back — the document's own, so a CRLF file stays
    /// a CRLF file.
    let newline: [UInt8]

    /// Whether the last line was terminated. A file that ended with a newline
    /// must still end with one afterwards.
    let endedWithNewline: Bool

    init(bytes: [UInt8], newline: [UInt8]) {
        self.newline = newline

        var collected: [String] = []
        var lineStart = 0
        for (position, byte) in bytes.enumerated() where byte == 0x0A {
            var end = position
            if end > lineStart && bytes[end - 1] == 0x0D {
                end -= 1                      // drop the CR of a CRLF pair
            }
            collected.append(String(decoding: bytes[lineStart..<end], as: UTF8.self))
            lineStart = position + 1
        }
        if lineStart < bytes.count {
            collected.append(String(decoding: bytes[lineStart...], as: UTF8.self))
            self.endedWithNewline = false
        } else {
            self.endedWithNewline = !bytes.isEmpty
        }
        self.lines = collected
    }

    /// `replacement` written back out with this document's terminators.
    func bytes(from replacement: [String]) -> [UInt8] {
        var result: [UInt8] = []
        for (position, line) in replacement.enumerated() {
            result.append(contentsOf: Array(line.utf8))
            if position < replacement.count - 1 || endedWithNewline {
                result.append(contentsOf: newline)
            }
        }
        return result
    }
}
