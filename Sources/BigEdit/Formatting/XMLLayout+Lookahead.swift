import Foundation

/// Holding an element's content until it shows whether it may be
/// reformatted: text directly inside it says no, its end tag after only
/// elements, comments and processing instructions says yes. Content that
/// runs past `lookaheadLimit` before either is taken to be elements only;
/// should text turn up after all, it and what follows are copied as they
/// are, but the whitespace before it may already have been replaced.
extension XMLLayout {

    mutating func hold(_ event: XMLEvent) {
        let size = XMLLayout.size(of: event)
        pending?.events.append(event)
        pending?.size += size
        var decision = pending?.observe(event)
        if decision == nil, let held = pending, held.size > lookaheadLimit {
            decision = .formatted
        }
        if let decision {
            release(as: decision)
        }
    }

    /// Opens the held element as `mode` and lays its content out again.
    private mutating func release(as mode: Mode) {
        let events = pending?.events ?? []
        pending = nil
        frames.append(Frame(mode: mode, preservesSpace: false, keepsDescendantsVerbatim: mode == .verbatim))
        events.forEach { handle($0) }
    }

    private static func size(of event: XMLEvent) -> Int {
        var size = 0
        switch event {
        case .whitespace(let bytes), .characters(let bytes), .markupBytes(let bytes):
            size = bytes.count
        case .startTag(let tag):
            size = tag.raw.count
        case .endTag(let tag):
            size = tag.raw.count
        case .markupBegin, .markupEnd:
            size = 0
        }
        return size
    }
}

extension XMLLayout.Pending {

    /// Takes in the next event of the held content, and returns how the
    /// element is laid out once that shows.
    mutating func observe(_ event: XMLEvent) -> XMLLayout.Mode? {
        var decision: XMLLayout.Mode?
        switch event {
        case .characters:
            decision = depth == 0 ? .verbatim : nil
        case .markupBegin(let kind):
            if depth == 0 && kind == .cdata {
                decision = .verbatim
            }
            hasChild = hasChild || depth == 0
        case .startTag(let tag):
            hasChild = hasChild || depth == 0
            depth += tag.isSelfClosing ? 0 : 1
        case .endTag:
            if depth == 0 {
                decision = hasChild ? .formatted : .verbatim
            }
            depth -= 1
        case .whitespace, .markupBytes, .markupEnd:
            break
        }
        return decision
    }
}
