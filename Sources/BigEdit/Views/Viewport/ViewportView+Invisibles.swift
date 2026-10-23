import AppKit
import CoreText

/// Marking spaces, line endings and other invisible characters over the
/// drawn rows. The marks are an overlay: they are placed by the row's own
/// layout and never move the text, the caret or a selection.
extension ViewportView {

    /// Where one invisible character of a row is, from the row's text origin.
    struct InvisibleMarkPlacement {
        let mark: InvisibleCharacters.Mark
        /// The span the character takes, which is empty for one with no
        /// width and for a line ending, placed just after the text.
        let minX: CGFloat
        let maxX: CGFloat
    }

    /// The invisible characters of `visualLine`, placed by the layout of
    /// `row`, the attributed text it is drawn as.
    func invisibleMarkPlacements(for visualLine: LineIndex.VisualLine,
                                 drawnAs row: NSAttributedString) -> [InvisibleMarkPlacement] {
        let marks = InvisibleCharacters.marks(in: decodeChunk(visualLine),
                                              terminator: lineTerminator(of: visualLine),
                                              startsDocument: chunkStartByte(visualLine) == 0)
        var placements: [InvisibleMarkPlacement] = []
        if !marks.isEmpty {
            let line = CTLineCreateWithAttributedString(row as CFAttributedString)
            let length = row.length
            placements = marks.map { mark in
                let end = min(length, mark.offset + 1)
                return InvisibleMarkPlacement(mark: mark,
                                              minX: CTLineGetOffsetForStringIndex(line, mark.offset, nil),
                                              maxX: CTLineGetOffsetForStringIndex(line, end, nil))
            }
        }
        return placements
    }

    /// How the line `visualLine` belongs to ends, if the row is its last.
    /// The row's bytes stop short of the line feed, and its decoded text
    /// leaves out the carriage return before one, so both are read from
    /// the document.
    func lineTerminator(of visualLine: LineIndex.VisualLine) -> InvisibleCharacters.LineTerminator {
        var terminator = InvisibleCharacters.LineTerminator.none
        let range = visualLine.byteRange
        if let document, visualLine.chunkIndex == visualLine.chunkCount - 1 {
            let endsWithReturn = range.upperBound > range.lowerBound
                && document.byte(at: range.upperBound - 1) == 0x0D
            if document.byte(at: range.upperBound) == 0x0A {
                terminator = endsWithReturn ? .carriageReturnLineFeed : .lineFeed
            } else if endsWithReturn {
                terminator = .carriageReturn
            }
        }
        return terminator
    }

    /// Marks the invisible characters of one drawn row, when they are shown.
    func drawInvisibles(for visualLine: LineIndex.VisualLine, drawnAs row: NSAttributedString,
                        rowY: CGFloat, rowX: CGFloat) {
        if showsInvisibles {
            let paths = InvisibleMarkPaths()
            for placement in invisibleMarkPlacements(for: visualLine, drawnAs: row) {
                addInvisibleMark(placement, rowLength: row.length, rowX: rowX, rowY: rowY, to: paths)
            }
            paths.paint(returnLineWidth: max(1, (fontSize / 12).rounded()))
        }
    }

    /// Adds one mark to `paths`, or draws it straight away when it is a
    /// glyph. Tabs are left out: their arrow is drawn whether or not
    /// invisibles are.
    private func addInvisibleMark(_ placement: InvisibleMarkPlacement, rowLength: Int,
                                  rowX: CGFloat, rowY: CGFloat, to paths: InvisibleMarkPaths) {
        let minX = rowX + placement.minX
        let maxX = rowX + placement.maxX
        switch placement.mark.kind {
        case .space:
            paths.spaces.appendOval(in: spaceDotRect(centerX: (minX + maxX) / 2, rowY: rowY))
        case .tab:
            break
        case .zeroWidth, .control:
            appendZeroWidthMark(to: paths.zeroWidths, x: minX, rowY: rowY)
        case .carriageReturn where placement.mark.offset < rowLength:
            appendZeroWidthMark(to: paths.zeroWidths, x: minX, rowY: rowY)
            appendReturnFoot(to: paths.returnFeet, x: minX, rowY: rowY)
        default:
            drawInvisibleGlyph(for: placement.mark.kind, minX: minX, maxX: maxX, rowY: rowY)
        }
    }

    /// The drawn marks of a row, gathered so each kind is painted at once.
    private final class InvisibleMarkPaths {
        let spaces = NSBezierPath()
        let zeroWidths = NSBezierPath()
        let returnFeet = NSBezierPath()

        func paint(returnLineWidth: CGFloat) {
            ViewportView.faintInvisibleColor.setFill()
            spaces.fill()
            ViewportView.prominentInvisibleColor.set()
            zeroWidths.lineWidth = 1
            zeroWidths.stroke()
            zeroWidths.fill()
            returnFeet.lineWidth = returnLineWidth
            returnFeet.stroke()
        }
    }

    /// Ordinary spaces and line endings: present, but easy to read past.
    static let faintInvisibleColor = NSColor.tertiaryLabelColor

    /// The characters people go looking for, a step more visible.
    static let prominentInvisibleColor = NSColor.secondaryLabelColor

    /// A dot at the height of a middle dot, in the middle of the space.
    private func spaceDotRect(centerX: CGFloat, rowY: CGFloat) -> NSRect {
        let diameter = max(1.5, (fontSize * 0.15).rounded())
        let centerY = rowY + font.ascender - font.xHeight / 2
        return NSRect(x: centerX - diameter / 2, y: centerY - diameter / 2,
                      width: diameter, height: diameter)
    }

    /// An upright under a small pointer where a character with no width
    /// sits, so it can be seen without pushing its neighbours apart.
    private func appendZeroWidthMark(to path: NSBezierPath, x: CGFloat, rowY: CGFloat) {
        let pixelX = x.rounded() + 0.5
        let pointer = (characterWidth * 0.3).rounded()
        path.move(to: NSPoint(x: pixelX - pointer, y: rowY + 1))
        path.line(to: NSPoint(x: pixelX + pointer, y: rowY + 1))
        path.line(to: NSPoint(x: pixelX, y: rowY + 1 + pointer))
        path.close()
        path.move(to: NSPoint(x: pixelX, y: rowY + 1 + pointer))
        path.line(to: NSPoint(x: pixelX, y: rowY + lineHeight - 1))
    }

    /// The foot that turns a zero-width mark into a return arrow (↵), for a
    /// carriage return inside the line: it has no width there, so a glyph
    /// would cover the next character.
    private func appendReturnFoot(to path: NSBezierPath, x: CGFloat, rowY: CGFloat) {
        let pixelX = x.rounded() + 0.5
        let footY = (rowY + font.ascender).rounded() - 0.5
        let reach = (characterWidth * 0.5).rounded()
        let head = (characterWidth * 0.25).rounded()
        path.move(to: NSPoint(x: pixelX, y: footY))
        path.line(to: NSPoint(x: pixelX - reach, y: footY))
        path.move(to: NSPoint(x: pixelX - reach + head, y: footY - head))
        path.line(to: NSPoint(x: pixelX - reach, y: footY))
        path.line(to: NSPoint(x: pixelX - reach + head, y: footY + head))
    }

    /// The glyph that stands for a line ending, a lone carriage return or an
    /// unusual space, set in the editor font: after the text for a line
    /// ending, centred on the character otherwise.
    private func drawInvisibleGlyph(for kind: InvisibleCharacters.Kind, minX: CGFloat, maxX: CGFloat,
                                    rowY: CGFloat) {
        let color = kind.isProminent ? ViewportView.prominentInvisibleColor : ViewportView.faintInvisibleColor
        let glyph = NSAttributedString(string: ViewportView.invisibleGlyph(for: kind),
                                       attributes: [.font: font, .foregroundColor: color])
        var x = minX
        if maxX > minX {
            x = (minX + maxX - glyph.size().width) / 2
        }
        glyph.draw(at: NSPoint(x: x, y: rowY))
    }

    static func invisibleGlyph(for kind: InvisibleCharacters.Kind) -> String {
        var glyph = ""
        switch kind {
        case .lineFeed:
            glyph = "¬"
        case .carriageReturnLineFeed:
            glyph = "¤¬"
        case .carriageReturn:
            glyph = "¤"
        case .unusualSpace:
            glyph = "°"
        case .space, .tab, .zeroWidth, .control:
            glyph = ""
        }
        return glyph
    }
}
