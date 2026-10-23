import Foundation

/// Lays out JSON tokens as they arrive, writing only the whitespace between
/// them.
///
/// Pretty Print keeps a container on one line when it fits within the line
/// width, and otherwise puts each member on a line of its own. Whether it
/// fits is known once it closes, or as soon as it has grown too wide, so the
/// tokens of an open container are held until then — never more than a
/// line's worth. A container found too wide is opened on its own and the
/// held tokens laid out again, each nested container getting its own chance
/// to fit.
struct JSONLayout {

    enum Event {
        case open(UInt8)
        case close(UInt8)
        case colon
        case comma
        case scalarBegin
        case scalarBytes([UInt8])
    }

    /// An open container's tokens while it may still fit on one line.
    private struct Pending {
        var events: [Event] = []
        var width = 0
        var depth = 0
        let limit: Int
    }

    private enum Place {
        case start
        case afterOpen
        case afterComma
        case afterColon
        case afterValue
    }

    private let style: FormattingStyle
    private let options: FormattingOptions
    private(set) var output: FormattedOutput
    private var depth = 0
    private var place = Place.start
    private var pending: Pending?

    init(style: FormattingStyle, options: FormattingOptions) {
        self.style = style
        self.options = options
        output = FormattedOutput(options: options)
    }

    mutating func handle(_ event: Event) {
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

    mutating func writeUncounted(_ byte: UInt8) {
        output.writeUncounted(byte)
    }

    mutating func takeOutput() -> [UInt8] {
        output.take()
    }

    // MARK: - Writing directly

    private mutating func write(_ event: Event) {
        switch event {
        case .open(let bracket):
            writeValuePrefix()
            if style == .pretty && options.lineWidth > 0 {
                pending = Pending(limit: options.lineWidth - (depth > 0 ? 1 : 0))
                hold(event)
            } else {
                writeOpen(bracket)
            }
        case .close(let bracket):
            writeClose(bracket)
        case .colon:
            output.write(UInt8(ascii: ":"))
            if style == .pretty {
                output.write(0x20)
            }
            place = .afterColon
        case .comma:
            output.write(UInt8(ascii: ","))
            place = .afterComma
        case .scalarBegin:
            writeValuePrefix()
            place = .afterValue
        case .scalarBytes(let bytes):
            output.write(bytes)
        }
    }

    /// The line break and indentation before a member of a broken
    /// container, or between two values at the top level.
    private mutating func writeValuePrefix() {
        switch place {
        case .afterOpen, .afterComma:
            if style == .pretty {
                output.writeNewline(indentedBy: depth)
            }
        case .afterValue:
            output.writeNewline(indentedBy: 0)
        case .start, .afterColon:
            break
        }
    }

    private mutating func writeOpen(_ bracket: UInt8) {
        output.write(bracket)
        depth += 1
        place = .afterOpen
    }

    private mutating func writeClose(_ bracket: UInt8) {
        if style == .pretty && place != .afterOpen {
            output.writeNewline(indentedBy: depth - 1)
        }
        output.write(bracket)
        depth -= 1
        place = .afterValue
    }

    // MARK: - Holding a container that may fit

    private mutating func hold(_ event: Event) {
        let width = inlineWidth(of: event)
        let change = depthChange(of: event)
        pending?.events.append(event)
        pending?.width += width
        pending?.depth += change
        if let held = pending {
            if output.column + held.width > held.limit {
                breakHeldContainer()
            } else if held.depth == 0 {
                pending = nil
                held.events.forEach { writeInline($0) }
                place = .afterValue
            }
        }
    }

    /// Opens the held container on its own and lays its tokens out again.
    private mutating func breakHeldContainer() {
        let events = pending?.events ?? []
        pending = nil
        if case .open(let bracket) = events.first {
            writeOpen(bracket)
        }
        events.dropFirst().forEach { handle($0) }
    }

    private mutating func writeInline(_ event: Event) {
        switch event {
        case .open(let bracket), .close(let bracket):
            output.write(bracket)
        case .colon:
            writeSeparator(UInt8(ascii: ":"))
        case .comma:
            writeSeparator(UInt8(ascii: ","))
        case .scalarBegin:
            break
        case .scalarBytes(let bytes):
            output.write(bytes)
        }
    }

    private mutating func writeSeparator(_ separator: UInt8) {
        output.write(separator)
        if options.spacesAfterSeparators {
            output.write(0x20)
        }
    }

    private func inlineWidth(of event: Event) -> Int {
        var width = 0
        switch event {
        case .open, .close:
            width = 1
        case .colon, .comma:
            width = options.spacesAfterSeparators ? 2 : 1
        case .scalarBegin:
            width = 0
        case .scalarBytes(let bytes):
            width = FormattedOutput.columns(of: bytes, options: options)
        }
        return width
    }

    private func depthChange(of event: Event) -> Int {
        var change = 0
        if case .open = event {
            change = 1
        } else if case .close = event {
            change = -1
        }
        return change
    }
}
