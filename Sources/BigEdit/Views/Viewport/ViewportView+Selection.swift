import AppKit
import CoreText

/// How much the mouse selects per click — driven by `NSEvent.clickCount`.
enum SelectionGranularity {
    case character
    case word
    case line
}

/// Byte categories used by word-level selection to find a run of same-kind
/// bytes around a click point.
enum ByteClass {
    case word
    case whitespace
    case other
}
/// Mouse selection: click, drag, double- and triple-click, and mapping a
/// point back to a byte offset.
extension ViewportView {

    override func resetCursorRects() {
        // I-beam over the text area only; the gutter keeps the default arrow.
        let gutterW = layout.map { gutterWidth(for: $0.gutterLineCount) } ?? 0
        let textRect = NSRect(x: gutterW, y: 0,
                              width: max(0, bounds.width - gutterW), height: bounds.height)
        addCursorRect(textRect, cursor: .iBeam)

        // Column dividers take precedence in the band along the top.
        if isCSVRenderingActive {
            let band = csvDividerBand
            for x in csvDividerPositions() where x >= gutterW && x <= bounds.width {
                addCursorRect(NSRect(x: x - 3, y: band.minY, width: 6, height: band.height),
                              cursor: .resizeLeftRight)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-click context menu. Select All is deliberately omitted
        // because selecting and copying many GB would try to build a huge
        // string on the pasteboard.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: ""
        ))
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let downPoint = convert(event.locationInWindow, from: nil)
        if let column = csvDividerColumn(at: downPoint), let csvColumnLayout {
            if event.clickCount == 2 {
                sizeCSVColumnToContent(column)
            } else {
                columnDrag = (column, downPoint.x, csvColumnLayout.columnWidths[column])
            }
            return
        }
        if hasMarkedText() {
            // A click commits the composition (its bytes are already in the
            // document) and lets the input method start fresh.
            inputContext?.discardMarkedText()
            unmarkText()
        }
        document?.undoStack.breakCoalescing()
        desiredCaretX = nil
        let point = convert(event.locationInWindow, from: nil)
        let offset = byteOffset(at: point)
        selectionGranularity = granularity(forClickCount: event.clickCount)
        selectionAnchorUnit = unit(at: offset, granularity: selectionGranularity)
        selection = TextSelection(
            anchorOffset: selectionAnchorUnit.lowerBound,
            activeOffset: selectionAnchorUnit.upperBound
        )
        lastDragLocationInWindow = event.locationInWindow
        startAutoscrollTimer()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let columnDrag {
            let point = convert(event.locationInWindow, from: nil)
            let movedColumns = Int(((point.x - columnDrag.startX) / characterWidth).rounded())
            csvColumnLayout = csvColumnLayout?.settingWidth(
                columnDrag.startWidth + movedColumns, forColumn: columnDrag.column)
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        lastDragLocationInWindow = event.locationInWindow
        updateSelectionForDrag()
    }

    override func mouseUp(with event: NSEvent) {
        if columnDrag != nil {
            columnDrag = nil
            return
        }
        stopAutoscrollTimer()
        lastDragLocationInWindow = nil
    }

    /// Extends the selection to span from the anchor unit (set on mouseDown)
    /// to the unit currently under the cursor. The unit type — character,
    /// word, or line — is fixed for the duration of the drag, so a
    /// double-click + drag widens word-by-word.
    private func updateSelectionForDrag() {
        guard let location = lastDragLocationInWindow else { return }
        let raw = convert(location, from: nil)
        let clamped = NSPoint(
            x: raw.x,
            y: min(max(0, raw.y), max(0, bounds.height - 1))
        )
        let offset = byteOffset(at: clamped)
        let currentUnit = unit(at: offset, granularity: selectionGranularity)
        let lower = min(selectionAnchorUnit.lowerBound, currentUnit.lowerBound)
        let upper = max(selectionAnchorUnit.upperBound, currentUnit.upperBound)
        selection = TextSelection(anchorOffset: lower, activeOffset: upper)
        needsDisplay = true
    }

    /// The selection unit a click of `clickCount` clicks selects.
    private func granularity(forClickCount clickCount: Int) -> SelectionGranularity {
        switch clickCount {
        case 2: return .word
        case 3: return .line
        default: return .character
        }
    }

    /// The byte range a `granularity` unit covers at `byteOffset`.
    private func unit(at byteOffset: Int, granularity: SelectionGranularity) -> Range<Int> {
        switch granularity {
        case .character:
            return byteOffset..<byteOffset
        case .word:
            return wordRange(at: byteOffset)
        case .line:
            return lineRange(at: byteOffset)
        }
    }

    /// The byte range of the word-like token at `byteOffset`. Three classes —
    /// word, whitespace, other — and the run of the same class is selected.
    /// Newlines always break a run, so the selection never crosses lines.
    private func wordRange(at byteOffset: Int) -> Range<Int> {
        var result = byteOffset..<byteOffset
        if let document, let clickedByte = document.byte(at: byteOffset) {
            let total = document.length
            let cap = 10_000
            let clickedClass = byteClass(of: clickedByte)
            var start = byteOffset
            var end = byteOffset + 1
            while start > 0 && byteOffset - start < cap,
                  let candidate = document.byte(at: start - 1),
                  candidate != 0x0A, byteClass(of: candidate) == clickedClass {
                start -= 1
            }
            while end < total && end - byteOffset < cap,
                  let candidate = document.byte(at: end),
                  candidate != 0x0A, byteClass(of: candidate) == clickedClass {
                end += 1
            }
            result = start..<end
        }
        return result
    }

    /// The byte range of the visual line containing `byteOffset`, including
    /// its trailing newline if this row is the last chunk of its line.
    private func lineRange(at byteOffset: Int) -> Range<Int> {
        var result = byteOffset..<byteOffset
        if let document, let layout {
            let row = layout.visualRow(forLogicalByteOffset: byteOffset)
            let rows = layout.visualLines(forRows: row..<(row + 1))
            if let visualLine = rows.first {
                var upper = visualLine.byteRange.upperBound
                let isLastChunk = visualLine.chunkIndex == visualLine.chunkCount - 1
                if isLastChunk && upper < document.length && document.byte(at: upper) == 0x0A {
                    upper += 1
                }
                result = visualLine.byteRange.lowerBound..<upper
            }
        }
        return result
    }

    /// Categorises a byte for word-break purposes: ASCII alphanumerics +
    /// underscore are "word", common ASCII whitespace is "whitespace", and
    /// anything else (punctuation, non-ASCII) is "other". `\n` is handled
    /// explicitly at the call site so a run never crosses a newline.
    private func byteClass(of byte: UInt8) -> ByteClass {
        if (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x5F
            || byte >= 0x80 {              // any UTF-8 multibyte sequence is "word"
            return .word
        }
        if byte == 0x20 || byte == 0x09 || byte == 0x0D {
            return .whitespace
        }
        return .other
    }

    private func startAutoscrollTimer() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.autoscrollTick()
        }
    }

    private func stopAutoscrollTimer() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    /// One auto-scroll step: if the held drag point is above or below the
    /// viewport, scroll in that direction and extend the selection.
    private func autoscrollTick() {
        guard let location = lastDragLocationInWindow else { return }
        let point = convert(location, from: nil)

        var rowDelta = 0.0
        if point.y < 0 {
            rowDelta = -min(5, -Double(point.y) / 8)
        } else if point.y > bounds.height {
            rowDelta = min(5, Double(point.y - bounds.height) / 8)
        }
        if rowDelta != 0 {
            setScrollRow(scrollRow + rowDelta)
            updateSelectionForDrag()
        }
    }

    /// Translates a point in viewport coordinates to a byte offset in the file.
    /// Hit testing assumes a monospaced font and ASCII content; non-ASCII text
    /// may select a few bytes off, and with an active replacement rule the
    /// mapping near a replacement is approximate.
    private func byteOffset(at point: NSPoint) -> Int {
        var result = 0
        if let document, let layout, layout.visualRowCount > 0 {
            let firstRow = Int(scrollRow)
            let fraction = scrollRow - Double(firstRow)
            let contentY = max(0, Double(point.y) - Double(pinnedHeaderHeight))
            let rowsFromTop = (contentY + fraction * Double(lineHeight)) / Double(lineHeight)
            var rowIndex = firstRow + Int(rowsFromTop.rounded(.down))
            rowIndex = max(0, min(rowIndex, layout.visualRowCount - 1))

            let rows = layout.visualLines(forRows: rowIndex..<(rowIndex + 1))
            if let visualLine = rows.first {
                let gutterW = gutterWidth(for: layout.gutterLineCount)
                let textOriginX = gutterW + gutterPadding
                let relativeX = point.x - textOriginX + horizontalOffset
                result = byteOffset(inRow: visualLine, atX: relativeX)
            } else {
                result = document.length
            }
        }
        return result
    }

    /// Maps an x position within a visual row to a byte offset. Uses CoreText so
    /// the result lands on a character boundary even with non-ASCII or otherwise
    /// variable-width glyphs, instead of assuming one column equals one byte.
    /// While a replacement rule is active, or CSV columns are being padded into
    /// alignment, the drawn text differs from the underlying bytes, so it falls
    /// back to a monospaced column estimate.
    func byteOffset(inRow visualLine: LineIndex.VisualLine,
                            atX relativeX: CGFloat) -> Int {
        let rs = visualLine.byteRange.lowerBound
        let re = visualLine.byteRange.upperBound

        if document?.hasDisplayTransform == true || isCSVRenderingActive {
            let approxChars = Int((max(0, relativeX) / characterWidth).rounded())
            return max(rs, min(rs + approxChars, re))
        }

        let startByte = chunkStartByte(visualLine)
        let text = decodeChunk(visualLine)
        if text.isEmpty {
            return startByte
        }

        let line = CTLineCreateWithAttributedString(attributedRow(text) as CFAttributedString)
        let position = CGPoint(x: max(0, relativeX), y: 0)
        let utf16Index = CTLineGetStringIndexForPosition(line, position)
        let target = max(0, min(Int(utf16Index), text.utf16.count))

        // Convert the UTF-16 string index back to a byte offset in the file.
        var consumedUTF16 = 0
        var consumedBytes = 0
        for scalar in text.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if consumedUTF16 + width > target {
                break
            }
            consumedUTF16 += width
            consumedBytes += textEncoding.byteLength(of: scalar)
        }
        return min(startByte + consumedBytes, re)
    }

    /// The first fully-decodable byte of a chunk. A continuation chunk can begin
    /// mid-UTF-8 sequence, so skip leading continuation bytes — mirroring how
    /// `decodeChunk` builds the displayed text.
    func chunkStartByte(_ visualLine: LineIndex.VisualLine) -> Int {
        var start = visualLine.byteRange.lowerBound
        if visualLine.chunkIndex > 0, let document {
            var skipped = 0
            while start < visualLine.byteRange.upperBound && skipped < 3,
                  let byte = document.byte(at: start), (byte & 0xC0) == 0x80 {
                start += 1
                skipped += 1
            }
        }
        return start
    }
}
