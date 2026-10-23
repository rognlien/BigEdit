import Foundation

/// Pretty prints or compacts XML as a stream: bytes go in a window at a
/// time and formatted bytes come out, with nothing held beyond a start tag,
/// the stack of open element names, and the lookahead `XMLLayout` needs.
///
/// Only whitespace-only text between elements is rewritten. Text, entity
/// references, attribute values, comments, CDATA sections, processing
/// instructions, the XML declaration and the DOCTYPE are copied byte for
/// byte. The input must be well-formed as far as its structure goes: tags
/// closed in order, markup terminated, attribute values quoted.
struct XMLFormatter: StreamingFormatter {

    enum Scanning {
        case content
        case markupOpen
        case bang
        case commentOpening
        case cdataOpening(matched: Int)
        case comment(dashes: Int)
        case cdata(brackets: Int)
        case processingInstruction(afterQuestionMark: Bool)
        case declaration(quote: UInt8?, depth: Int)
        case startTag(TagPart)
        case endTag(afterName: Bool)
    }

    enum TagPart {
        case name
        case beforeAttribute
        case attributeName(start: Int)
        case afterAttributeName(Range<Int>)
        case afterEquals(Range<Int>)
        case value(name: Range<Int>, quote: UInt8, start: Int)
        case afterSlash
    }

    struct OpenElement {
        let name: [UInt8]
        let position: TextPosition
    }

    /// The most held while waiting to see whether an element's content may
    /// be reformatted.
    static let lookaheadLimit = 64 * 1024

    /// Text and markup are passed to the layout at least this often.
    static let chunkLength = 4096

    var byteOrderMark: ByteOrderMarkReader
    var layout: XMLLayout
    var position: TextPosition
    var markupStart: TextPosition
    var scanning = Scanning.content
    var text: [UInt8] = []
    var textHasCharacters = false
    var markup: [UInt8] = []
    var isInMarkup = false
    var tag = XMLTag(raw: [], name: 0..<0)
    var endTag: [UInt8] = []
    var endTagName: [UInt8] = []
    var openElements: [OpenElement] = []
    var hasNode = false
    var endsWithNewline = false

    init(style: FormattingStyle, options: FormattingOptions = FormattingOptions(),
         lookaheadLimit: Int = XMLFormatter.lookaheadLimit) {
        layout = XMLLayout(style: style, options: options, lookaheadLimit: lookaheadLimit)
        position = TextPosition(encoding: options.encoding)
        byteOrderMark = ByteOrderMarkReader(encoding: options.encoding)
        markupStart = position
    }

    mutating func feed(_ bytes: ArraySlice<UInt8>) throws {
        for byte in bytes {
            if byteOrderMark.accepts(byte, at: position.offset) {
                layout.output.writeUncounted(byte)
                position.skip()
            } else {
                try consume(byte)
                position.advance(past: byte)
            }
        }
        passText()
        passMarkup()
    }

    mutating func finish() throws {
        if let unfinished = unfinishedDescription {
            throw markupStart.error(unfinished)
        }
        if let open = openElements.last {
            throw open.position.error("“<\(String(decoding: open.name, as: UTF8.self))>” is never closed")
        }
        layout.finish(endingWithNewline: hasNode && endsWithNewline)
    }

    mutating func takeOutput() -> [UInt8] {
        layout.takeOutput()
    }

    private mutating func consume(_ byte: UInt8) throws {
        switch scanning {
        case .content:
            try consumeContent(byte)
        case .markupOpen:
            try consumeMarkupOpen(byte)
        case .bang, .commentOpening, .cdataOpening:
            try consumeBang(byte)
        case .comment, .cdata, .processingInstruction, .declaration:
            consumeMarkup(byte)
        case .startTag(let part):
            try consumeStartTag(byte, part: part)
        case .endTag(let afterName):
            try consumeEndTag(byte, afterName: afterName)
        }
    }

    private mutating func consumeContent(_ byte: UInt8) throws {
        if byte == UInt8(ascii: "<") {
            passText()
            markupStart = position
            endsWithNewline = false
            scanning = .markupOpen
        } else {
            if !XMLFormatter.isWhitespace(byte) {
                if openElements.isEmpty {
                    throw position.error("Text is not allowed outside an element")
                }
                textHasCharacters = true
            }
            endsWithNewline = endsWithNewline || byte == 0x0A
            text.append(byte)
            if text.count >= XMLFormatter.chunkLength {
                passText()
            }
        }
    }

    /// What follows `<` says what the markup is.
    private mutating func consumeMarkupOpen(_ byte: UInt8) throws {
        switch byte {
        case UInt8(ascii: "/"):
            endTag = Array("</".utf8)
            endTagName = []
            scanning = .endTag(afterName: false)
        case UInt8(ascii: "!"):
            markup = Array("<!".utf8)
            scanning = .bang
        case UInt8(ascii: "?"):
            markup = Array("<?".utf8)
            beginMarkup(.processingInstruction, scanning: .processingInstruction(afterQuestionMark: false))
        default:
            guard XMLFormatter.isNameStart(byte) else {
                throw markupStart.error("“<” must start a tag; write “&lt;” for the character itself")
            }
            tag = XMLTag(raw: [UInt8(ascii: "<"), byte], name: 1..<2)
            scanning = .startTag(.name)
        }
    }

    /// Hands the character data read so far to the layout.
    mutating func passText() {
        if !text.isEmpty {
            layout.handle(textHasCharacters ? .characters(text) : .whitespace(text))
            text.removeAll(keepingCapacity: true)
        }
        textHasCharacters = false
    }

    /// Why the input cannot end where it does, or nil when it can.
    private var unfinishedDescription: String? {
        var description: String?
        switch scanning {
        case .content:
            description = nil
        case .markupOpen, .startTag, .bang:
            description = "The tag is never closed"
        case .endTag:
            description = "The end tag is never closed"
        case .commentOpening, .comment:
            description = "The comment is never closed"
        case .cdataOpening, .cdata:
            description = "The CDATA section is never closed"
        case .processingInstruction:
            description = "The processing instruction is never closed"
        case .declaration:
            description = "The declaration is never closed"
        }
        return description
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    static func isNameStart(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20) || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: ":") || byte >= 0x80
    }

    static func isNameCharacter(_ byte: UInt8) -> Bool {
        isNameStart(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
    }
}
