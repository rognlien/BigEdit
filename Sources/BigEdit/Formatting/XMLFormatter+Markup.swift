import Foundation

/// Comments, CDATA sections, processing instructions and declarations such
/// as the DOCTYPE: recognised by how they open, then copied byte for byte
/// until the sequence that closes them.
extension XMLFormatter {

    private static let cdataOpening = Array("<![CDATA[".utf8)

    /// After `<!`: `--` opens a comment, `[CDATA[` a CDATA section, and a
    /// letter a declaration.
    mutating func consumeBang(_ byte: UInt8) throws {
        markup.append(byte)
        switch scanning {
        case .bang where byte == UInt8(ascii: "-"):
            scanning = .commentOpening
        case .bang where byte == UInt8(ascii: "["):
            scanning = .cdataOpening(matched: 3)
        case .bang where XMLFormatter.isNameStart(byte):
            beginMarkup(.declaration, scanning: .declaration(quote: nil, depth: 0))
        case .commentOpening where byte == UInt8(ascii: "-"):
            beginMarkup(.comment, scanning: .comment(dashes: 0))
        case .cdataOpening(let matched) where XMLFormatter.cdataOpening[matched] == byte:
            if matched + 1 == XMLFormatter.cdataOpening.count {
                beginMarkup(.cdata, scanning: .cdata(brackets: 0))
            } else {
                scanning = .cdataOpening(matched: matched + 1)
            }
        default:
            throw markupStart.error("Expected a comment, a CDATA section or a declaration after “<!”")
        }
    }

    mutating func beginMarkup(_ kind: XMLMarkup, scanning next: Scanning) {
        layout.handle(.markupBegin(kind))
        isInMarkup = true
        scanning = next
    }

    mutating func consumeMarkup(_ byte: UInt8) {
        markup.append(byte)
        if isClosingMarkup(with: byte) {
            endMarkup()
        } else {
            advanceMarkup(past: byte)
        }
        if markup.count >= XMLFormatter.chunkLength {
            passMarkup()
        }
    }

    /// Whether `byte` is the `>` of the `-->`, `]]>` or `?>` that closes
    /// the comment, CDATA section or processing instruction.
    private func isClosingMarkup(with byte: UInt8) -> Bool {
        var closes = false
        if byte == UInt8(ascii: ">") {
            switch scanning {
            case .comment(let dashes):
                closes = dashes >= 2
            case .cdata(let brackets):
                closes = brackets >= 2
            case .processingInstruction(let afterQuestionMark):
                closes = afterQuestionMark
            default:
                closes = false
            }
        }
        return closes
    }

    private mutating func advanceMarkup(past byte: UInt8) {
        switch scanning {
        case .comment(let dashes):
            scanning = .comment(dashes: byte == UInt8(ascii: "-") ? dashes + 1 : 0)
        case .cdata(let brackets):
            scanning = .cdata(brackets: byte == UInt8(ascii: "]") ? brackets + 1 : 0)
        case .processingInstruction:
            scanning = .processingInstruction(afterQuestionMark: byte == UInt8(ascii: "?"))
        case .declaration(let quote, let depth):
            consumeDeclaration(byte, quote: quote, depth: depth)
        default:
            break
        }
    }

    /// A declaration ends at the first `>` outside quotes and outside the
    /// brackets of a DOCTYPE's internal subset.
    private mutating func consumeDeclaration(_ byte: UInt8, quote: UInt8?, depth: Int) {
        if let quote {
            scanning = .declaration(quote: byte == quote ? nil : quote, depth: depth)
        } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
            scanning = .declaration(quote: byte, depth: depth)
        } else if byte == UInt8(ascii: "[") || byte == UInt8(ascii: "]") {
            scanning = .declaration(quote: nil, depth: depth + (byte == UInt8(ascii: "[") ? 1 : -1))
        } else if byte == UInt8(ascii: ">") && depth <= 0 {
            endMarkup()
        }
    }

    private mutating func endMarkup() {
        passMarkup()
        layout.handle(.markupEnd)
        isInMarkup = false
        hasNode = true
        scanning = .content
    }

    /// Hands the markup read so far to the layout, once it knows what kind
    /// it is.
    mutating func passMarkup() {
        if isInMarkup && !markup.isEmpty {
            layout.handle(.markupBytes(markup))
            markup.removeAll(keepingCapacity: true)
        }
    }
}
