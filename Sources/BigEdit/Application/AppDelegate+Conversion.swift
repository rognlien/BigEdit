import AppKit

/// Converting a single-byte document to UTF-8, so it can hold characters
/// its own encoding has no way to write.
extension AppDelegate {

    @objc func convertToUTF8() {
        if let document = activeDocument, document.view.canConvertToUTF8 {
            offerConversionToUTF8(of: document)
        }
    }

    /// Asks before rewriting the file behind `view` in UTF-8.
    func offerConversionToUTF8(in view: DocumentView) {
        if let document = documents.first(where: { $0.view === view }), view.canConvertToUTF8 {
            offerConversionToUTF8(of: document)
        }
    }

    private func offerConversionToUTF8(of document: Document) {
        let alert = NSAlert()
        alert.messageText = "Convert “\(document.fileName)” to UTF-8?"
        alert.informativeText = "BigEdit rewrites the file on disk from "
            + "\(document.view.textEncoding.label) to UTF-8, which can hold any character. "
            + "Unsaved changes are included, and the conversion cannot be undone."
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.convertUnlessChangedOnDisk(document)
            }
        }
    }

    private func convertUnlessChangedOnDisk(_ document: Document) {
        if document.hasDiskChanges {
            presentDiskChangeConflict(for: document)
        } else if let edited = document.view.editedDocument {
            convert(document, edited: edited)
        }
    }

    /// Streams the converted document over its own file behind the save
    /// sheet, then reloads from what was written. Every offset after the
    /// first non-ASCII character moves, so the edit history cannot follow.
    private func convert(_ document: Document, edited: EditedDocument) {
        let sheet = SaveProgressSheet(fileName: document.fileName)
        let cancelToken = CancelToken()
        sheet.onCancel = { cancelToken.cancel() }
        saveProgressSheet = sheet
        window.beginSheet(sheet.window) { _ in }
        FileWriter.save(document: edited, convertingFrom: document.view.textEncoding,
                        to: document.url, cancelToken: cancelToken,
                        onProgress: { sheet.setProgress($0) }) { [weak self] result in
            self?.window.endSheet(sheet.window)
            self?.saveProgressSheet = nil
            self?.finishConversion(of: document, result: result)
        }
    }

    private func finishConversion(of document: Document, result: Result<Void, FileWriter.WriteError>) {
        switch result {
        case .success:
            document.view.discardJournal()
            reload(document, from: document.url, preserveScroll: true)
            document.view.startJournalFromCurrentFile()
        case .failure(.cancelled):
            break
        case .failure(let error):
            presentSaveError(error.localizedDescription)
        }
    }
}
