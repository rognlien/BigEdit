import Foundation

/// Lays out XML as it arrives, rewriting only the whitespace-only text
/// between elements.
///
/// An element's content is reformatted only when it holds elements,
/// comments or processing instructions and no other text: each child then
/// goes on a line of its own and the whitespace between them is replaced.
/// Anything else — text alone, mixed content, and everything inside them —
/// is copied exactly, as is everything under `xml:space="preserve"` until an
/// `xml:space="default"` turns reformatting back on. Which kind an element
/// is shows only further on, so its content is held until it is known, or
/// until `lookaheadLimit` bytes are held, when it is taken to be elements
/// only (see `XMLLayout+Lookahead`).
///
/// A start tag that would run past the line width puts each attribute
/// after the first on a line of its own, aligned under the first.
struct XMLLayout {

    enum Mode {
        case formatted
        case verbatim
    }

    struct Frame {
        var mode: Mode
        let preservesSpace: Bool
        /// Set inside mixed content, where nothing below is reformatted.
        var keepsDescendantsVerbatim: Bool
        var hasWrittenChild = false
    }

    /// An element's content while it is not yet known whether it may be
    /// reformatted.
    struct Pending {
        var events: [XMLEvent] = []
        var size = 0
        var depth = 0
        var hasChild = false
    }

    let style: FormattingStyle
    let options: FormattingOptions
    let lookaheadLimit: Int
    var output: FormattedOutput
    var frames: [Frame] = []
    var pending: Pending?
    var heldWhitespace: [UInt8] = []
    var hasWrittenTopLevelNode = false

    init(style: FormattingStyle, options: FormattingOptions, lookaheadLimit: Int) {
        self.style = style
        self.options = options
        self.lookaheadLimit = lookaheadLimit
        output = FormattedOutput(options: options)
    }

    mutating func handle(_ event: XMLEvent) {
        if pending != nil {
            hold(event)
        } else {
            write(event)
        }
    }

    /// Ends the output, with a line break when the input ended with one.
    mutating func finish(endingWithNewline: Bool) {
        if endingWithNewline {
            output.writeNewline(indentedBy: 0)
        }
    }

    mutating func takeOutput() -> [UInt8] {
        output.take()
    }

    private var isReformatting: Bool {
        frames.last.map { $0.mode == .formatted } ?? true
    }

    // MARK: - Writing

    mutating func write(_ event: XMLEvent) {
        switch event {
        case .whitespace(let bytes):
            writeWhitespace(bytes)
        case .characters(let bytes):
            writeCharacters(bytes)
        case .startTag(let tag):
            writeStartTag(tag)
        case .endTag(let tag):
            writeEndTag(tag)
        case .markupBegin(let kind):
            writeMarkupBegin(kind)
        case .markupBytes(let bytes):
            output.write(bytes)
        case .markupEnd:
            break
        }
    }

    /// Whitespace between reformatted nodes is held, to be dropped at the
    /// next node — or written after all, should text follow it.
    private mutating func writeWhitespace(_ bytes: [UInt8]) {
        if !isReformatting {
            output.write(bytes)
        } else if heldWhitespace.count < lookaheadLimit {
            heldWhitespace += bytes
        }
    }

    /// Text in content being reformatted makes it mixed after all: it is
    /// copied as it is from here on.
    private mutating func writeCharacters(_ bytes: [UInt8]) {
        if isReformatting && !frames.isEmpty {
            frames[frames.count - 1].mode = .verbatim
            frames[frames.count - 1].keepsDescendantsVerbatim = true
            output.write(heldWhitespace)
        }
        heldWhitespace = []
        output.write(bytes)
    }

    private mutating func writeMarkupBegin(_ kind: XMLMarkup) {
        if kind == .cdata {
            writeCharacters([])
        } else if isReformatting {
            heldWhitespace = []
            writeNodePrefix()
        }
    }

    private mutating func writeStartTag(_ tag: XMLTag) {
        if isReformatting {
            heldWhitespace = []
            writeNodePrefix()
            writeTag(tag)
        } else {
            output.write(tag.raw)
        }
        if !tag.isSelfClosing {
            open(tag)
        }
    }

    /// Starts the element's content: copied as it is when its parent's is,
    /// or under `xml:space="preserve"`, and otherwise held until it is
    /// known whether it may be reformatted.
    private mutating func open(_ tag: XMLTag) {
        let parent = frames.last
        let preservesSpace = tag.preservesSpace ?? parent?.preservesSpace ?? false
        if parent?.keepsDescendantsVerbatim == true {
            frames.append(Frame(mode: .verbatim, preservesSpace: preservesSpace, keepsDescendantsVerbatim: true))
        } else if preservesSpace {
            frames.append(Frame(mode: .verbatim, preservesSpace: true, keepsDescendantsVerbatim: false))
        } else {
            pending = Pending()
        }
    }

    private mutating func writeEndTag(_ tag: XMLEndTag) {
        if isReformatting {
            heldWhitespace = []
            if style == .pretty && frames.last?.hasWrittenChild == true {
                output.writeNewline(indentedBy: frames.count - 1)
            }
            output.write(Array("</".utf8) + tag.name + [UInt8(ascii: ">")])
        } else {
            output.write(tag.raw)
        }
        frames.removeLast()
    }

    /// The line break and indentation before a reformatted node.
    private mutating func writeNodePrefix() {
        if frames.isEmpty {
            if style == .pretty && hasWrittenTopLevelNode {
                output.writeNewline(indentedBy: 0)
            }
            hasWrittenTopLevelNode = true
        } else {
            if style == .pretty {
                output.writeNewline(indentedBy: frames.count)
            }
            frames[frames.count - 1].hasWrittenChild = true
        }
    }

    // MARK: - Tags

    /// Writes `tag` with one space before each attribute, or with each one
    /// after the first on a line of its own when it would not fit.
    private mutating func writeTag(_ tag: XMLTag) {
        let name = tag.raw[tag.name]
        let wraps = style == .pretty && options.lineWidth > 0 && tag.attributes.count > 1
            && output.column + inlineColumns(of: tag) > options.lineWidth
        output.write(UInt8(ascii: "<"))
        output.write(name)
        for (index, attribute) in tag.attributes.enumerated() {
            if wraps && index > 0 {
                output.writeNewline(indentedBy: frames.count)
                output.writeSpaces(FormattedOutput.columns(of: name, options: options) + 2)
            } else {
                output.write(0x20)
            }
            output.write(tag.raw[attribute.name])
            output.write(UInt8(ascii: "="))
            output.write(tag.raw[attribute.value])
        }
        output.write(tag.isSelfClosing ? Array("/>".utf8) : [UInt8(ascii: ">")])
    }

    private func inlineColumns(of tag: XMLTag) -> Int {
        var columns = 1 + FormattedOutput.columns(of: tag.raw[tag.name], options: options)
        for attribute in tag.attributes {
            columns += 2 + FormattedOutput.columns(of: tag.raw[attribute.name], options: options)
                + FormattedOutput.columns(of: tag.raw[attribute.value], options: options)
        }
        return columns + (tag.isSelfClosing ? 2 : 1)
    }
}
