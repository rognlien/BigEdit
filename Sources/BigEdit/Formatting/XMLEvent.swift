import Foundation

/// What the XML formatter reads, in document order. Character data and the
/// insides of comments, CDATA sections, processing instructions and
/// declarations arrive in runs, so none of them is ever held whole.
enum XMLEvent {
    /// Character data that is only whitespace.
    case whitespace([UInt8])
    /// Character data with something besides whitespace in it.
    case characters([UInt8])
    case startTag(XMLTag)
    case endTag(XMLEndTag)
    case markupBegin(XMLMarkup)
    case markupBytes([UInt8])
    case markupEnd
}

enum XMLMarkup {
    case comment
    case cdata
    case processingInstruction
    case declaration
}

/// A start tag as it was written, with where its name and each attribute's
/// name and quoted value lie in it.
struct XMLTag {

    struct Attribute {
        let name: Range<Int>
        let value: Range<Int>
    }

    var raw: [UInt8]
    var name: Range<Int>
    var attributes: [Attribute] = []
    var isSelfClosing = false

    private static let spaceAttribute = Array("xml:space".utf8)

    /// What the tag's `xml:space` says: true for `preserve`, false for
    /// `default`, nil when it has none.
    var preservesSpace: Bool? {
        var result: Bool?
        if let attribute = attributes.last(where: { Array(raw[$0.name]) == XMLTag.spaceAttribute }) {
            let value = raw[(attribute.value.lowerBound + 1)..<(attribute.value.upperBound - 1)]
            if Array(value) == Array("preserve".utf8) {
                result = true
            } else if Array(value) == Array("default".utf8) {
                result = false
            }
        }
        return result
    }
}

struct XMLEndTag {
    let raw: [UInt8]
    let name: [UInt8]
}
