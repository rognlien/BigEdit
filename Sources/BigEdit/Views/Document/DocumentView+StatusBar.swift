import AppKit

/// The status bar: file format, caret position and selection size.
extension DocumentView {

    /// Sets the detected format (encoding / line endings) shown on the right,
    /// and derives editability from it: only UTF-8 / ASCII text accepts
    /// positional edits, and Return inserts the detected line ending.
    func setFileFormat(_ format: FileFormat?) {
        fileFormat = format
        viewport.setTextEncoding(textEncoding)
        if let document = viewport.document {
            document.isEditable = format?.isUTF8 ?? false
            document.newlineBytes = format?.lineEnding == "CRLF" ? [0x0D, 0x0A] : [0x0A]
        }
        updateStatusBar()
    }

    func updateStatusBar() {
        var left = ""
        if let document = viewport.document, let layout = viewport.layout, document.length > 0,
           let caret = viewport.caretByteOffset {
            let row = layout.visualRow(forLogicalByteOffset: caret)
            let line = layout.visualLines(forRows: row..<(row + 1)).first
            let lineNumber = (line?.documentLine ?? 0) + 1
            let lineText = numberFormatter.string(from: NSNumber(value: lineNumber)) ?? "\(lineNumber)"
            let offset = numberFormatter.string(from: NSNumber(value: caret)) ?? "\(caret)"
            left = "Ln \(lineText)  ·  Offset \(offset)"
            if let range = viewport.selectionByteRange {
                let bytes = numberFormatter.string(from: NSNumber(value: range.count)) ?? "\(range.count)"
                let lineCount = selectedLineCount(range, layout: layout)
                let lines = numberFormatter.string(from: NSNumber(value: lineCount)) ?? "\(lineCount)"
                let bytesUnit = range.count == 1 ? "byte" : "bytes"
                let linesUnit = lineCount == 1 ? "line" : "lines"
                left += "  ·  \(bytes) \(bytesUnit), \(lines) \(linesUnit) selected"
            }
        }
        statusBar.setLeft(left)

        var right = ""
        if let format = fileFormat {
            right = format.lineEnding == "—" ? format.encoding : "\(format.lineEnding)  ·  \(format.encoding)"
        }
        if viewport.isCSVRenderingActive {
            right = right.isEmpty ? "CSV" : "CSV  ·  \(right)"
        }
        if isFollowing {
            right = right.isEmpty ? "Following" : "Following  ·  \(right)"
        }
        statusBar.setRight(right)
    }

    /// The number of document lines the selection touches — derived from the
    /// layout (O(log n) per end), so it's cheap even for a huge selection.
    private func selectedLineCount(_ range: Range<Int>, layout: EditedLayout) -> Int {
        let startLine = documentLine(forByteOffset: range.lowerBound, layout: layout)
        let endLine = documentLine(forByteOffset: max(range.lowerBound, range.upperBound - 1),
                                   layout: layout)
        return endLine - startLine + 1
    }

    private func documentLine(forByteOffset offset: Int, layout: EditedLayout) -> Int {
        let row = layout.visualRow(forLogicalByteOffset: offset)
        return layout.visualLines(forRows: row..<(row + 1)).first?.documentLine ?? 0
    }
}
