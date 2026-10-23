import Foundation

/// Start and end tags: read whole, a start tag with where each attribute
/// lies in it, and checked to close the elements in the order they opened.
extension XMLFormatter {

    mutating func consumeStartTag(_ byte: UInt8, part: TagPart) throws {
        tag.raw.append(byte)
        let offset = tag.raw.count - 1
        let isSpace = XMLFormatter.isWhitespace(byte)
        switch part {
        case .name where XMLFormatter.isNameCharacter(byte):
            tag.name = tag.name.lowerBound..<tag.raw.count
        case .name where isSpace, .beforeAttribute where isSpace:
            scanning = .startTag(.beforeAttribute)
        case .beforeAttribute where XMLFormatter.isNameStart(byte):
            scanning = .startTag(.attributeName(start: offset))
        case .name where byte == UInt8(ascii: ">"), .beforeAttribute where byte == UInt8(ascii: ">"):
            finishStartTag(selfClosing: false)
        case .name where byte == UInt8(ascii: "/"), .beforeAttribute where byte == UInt8(ascii: "/"):
            scanning = .startTag(.afterSlash)
        case .afterSlash where byte == UInt8(ascii: ">"):
            finishStartTag(selfClosing: true)
        case .attributeName, .afterAttributeName, .afterEquals, .value:
            try consumeAttribute(byte, part: part, offset: offset)
        default:
            throw position.error(unexpectedInTag(part))
        }
    }

    private mutating func consumeAttribute(_ byte: UInt8, part: TagPart, offset: Int) throws {
        let isSpace = XMLFormatter.isWhitespace(byte)
        let isQuote = byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'")
        switch part {
        case .attributeName where XMLFormatter.isNameCharacter(byte):
            break
        case .attributeName(let start) where isSpace:
            scanning = .startTag(.afterAttributeName(start..<offset))
        case .attributeName(let start) where byte == UInt8(ascii: "="):
            scanning = .startTag(.afterEquals(start..<offset))
        case .afterAttributeName where isSpace, .afterEquals where isSpace:
            break
        case .afterAttributeName(let name) where byte == UInt8(ascii: "="):
            scanning = .startTag(.afterEquals(name))
        case .afterEquals(let name) where isQuote:
            scanning = .startTag(.value(name: name, quote: byte, start: offset))
        case .value(let name, let quote, let start) where byte == quote:
            tag.attributes.append(XMLTag.Attribute(name: name, value: start..<tag.raw.count))
            scanning = .startTag(.beforeAttribute)
        case .value:
            break
        default:
            throw position.error(unexpectedInTag(part))
        }
    }

    private func unexpectedInTag(_ part: TagPart) -> String {
        var message: String
        switch part {
        case .name, .beforeAttribute: message = "Expected an attribute name, “>” or “/>”"
        case .attributeName, .afterAttributeName: message = "Expected “=” after the attribute name"
        case .afterEquals: message = "Expected a quoted attribute value"
        case .afterSlash: message = "Expected “>” after “/”"
        case .value: message = "Expected the attribute value to be closed"
        }
        return message
    }

    private mutating func finishStartTag(selfClosing: Bool) {
        tag.isSelfClosing = selfClosing
        if !selfClosing {
            openElements.append(OpenElement(name: Array(tag.raw[tag.name]), position: markupStart))
        }
        layout.handle(.startTag(tag))
        hasNode = true
        scanning = .content
    }

    mutating func consumeEndTag(_ byte: UInt8, afterName: Bool) throws {
        endTag.append(byte)
        if byte == UInt8(ascii: ">") && !endTagName.isEmpty {
            try finishEndTag()
        } else if XMLFormatter.isWhitespace(byte) && !endTagName.isEmpty {
            scanning = .endTag(afterName: true)
        } else if !afterName && (endTagName.isEmpty ? XMLFormatter.isNameStart(byte) : XMLFormatter.isNameCharacter(byte)) {
            endTagName.append(byte)
        } else {
            throw position.error(endTagName.isEmpty ? "Expected an element name after “</”" : "Expected “>” to end the end tag")
        }
    }

    private mutating func finishEndTag() throws {
        let found = "“</\(String(decoding: endTagName, as: UTF8.self))>”"
        guard let open = openElements.last else {
            throw markupStart.error("\(found) closes no element")
        }
        guard open.name == endTagName else {
            throw markupStart.error("Expected “</\(String(decoding: open.name, as: UTF8.self))>” but found \(found)")
        }
        openElements.removeLast()
        layout.handle(.endTag(XMLEndTag(raw: endTag, name: endTagName)))
        hasNode = true
        scanning = .content
    }
}
