import AppKit

extension DocumentView {

    /// Asks the user for a line number and scrolls the viewport to it.
    func showGoToLineSheet() {
        guard let layout = viewport.layout, layout.documentLineCount > 0,
              let parentWindow = window else {
            return
        }

        let lineCount = layout.documentLineCount
        let formattedCount = numberFormatter.string(from: NSNumber(value: lineCount))
            ?? "\(lineCount)"
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Line number (1 – \(formattedCount))"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "e.g. 1234"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: parentWindow) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.scrollToEnteredLine(field.stringValue, layout: layout)
            }
        }
    }

    private func scrollToEnteredLine(_ text: String, layout: EditedLayout) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let entered = Int(trimmed), entered > 0 {
            let targetLine = min(entered - 1, layout.documentLineCount - 1)
            let row = layout.visualRow(forDocumentLine: targetLine)
            viewport.scrollToRow(row)
        }
    }
}
