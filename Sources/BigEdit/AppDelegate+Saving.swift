import AppKit

/// Save, Save As, reload from disk, and the conflict prompts around them.
extension AppDelegate {

    @objc func save() {
        if let document = activeDocument, document.isEdited {
            if document.hasDiskChanges {
                presentDiskChangeConflict(for: document)
            } else {
                performSave(of: document, to: document.url)
            }
        }
    }

    @objc func saveAs() {
        if let document = activeDocument, document.isEdited {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = document.fileName
            panel.directoryURL = document.url.deletingLastPathComponent()
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.performSave(of: document, to: url)
                }
            }
        }
    }

    /// The file changed on disk while it has unsaved edits: the mmap gives no
    /// guarantee the edits are based on what is there now, so saving over it
    /// is unsafe. Offer Save As or discarding the edits.
    func presentDiskChangeConflict(for document: Document) {
        let alert = NSAlert()
        alert.messageText = "\(document.fileName) changed on disk"
        alert.informativeText = "The file was modified by another program while you had "
            + "unsaved changes. Save to a different file, or reload the file and lose "
            + "your changes."
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Reload and Discard Changes")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.saveAs()
            case .alertSecondButtonReturn:
                self?.reload(document, from: document.url, preserveScroll: true)
            default:
                break
            }
        }
    }

    /// Runs the streaming write under a progress sheet, picking the piece
    /// save for positional edits or the rule save for a deferred rule. On
    /// success re-loads the document so it reflects what is now on disk.
    func performSave(of document: Document, to destination: URL,
                             completion: ((Bool) -> Void)? = nil) {
        let sheet = SaveProgressSheet(fileName: destination.lastPathComponent)
        let cancelToken = CancelToken()
        sheet.onCancel = { cancelToken.cancel() }
        saveProgressSheet = sheet
        window.beginSheet(sheet.window) { _ in }

        let finish: (Result<Void, FileWriter.WriteError>) -> Void = { [weak self] result in
            self?.window.endSheet(sheet.window)
            self?.saveProgressSheet = nil
            self?.handleSaveResult(result, document: document, destination: destination,
                                   completion: completion)
        }

        if let rule = document.view.currentRule {
            FileWriter.save(
                file: document.file,
                rule: rule,
                to: destination,
                cancelToken: cancelToken,
                onProgress: { sheet.setProgress($0) },
                completion: finish
            )
        } else if let editedDocument = document.view.editedDocument {
            FileWriter.save(
                document: editedDocument,
                to: destination,
                cancelToken: cancelToken,
                onProgress: { sheet.setProgress($0) },
                completion: finish
            )
        } else {
            window.endSheet(sheet.window)
            saveProgressSheet = nil
            completion?(false)
        }
    }

    private func handleSaveResult(
        _ result: Result<Void, FileWriter.WriteError>,
        document: Document,
        destination: URL,
        completion: ((Bool) -> Void)? = nil
    ) {
        switch result {
        case .success:
            reloadDocument(document, from: destination)
            completion?(true)
        case .failure(let error):
            if case .cancelled = error {
                completion?(false)
                return  // Silent on cancel; original file untouched.
            }
            presentSaveError(error.localizedDescription)
            completion?(false)
        }
    }

    /// Re-points a document at the freshly written file and restarts indexing.
    /// After a save: the document re-maps from what was just written, keeping
    /// its edit history so ⌘Z still works.
    private func reloadDocument(_ document: Document, from destination: URL) {
        reload(document, from: destination, preserveScroll: false, inheritingHistory: true)
        document.view.startJournalFromCurrentFile()
        addRecentDocument(destination)
    }

    /// Reloads the active document from its file on disk (the ⌘R command),
    /// keeping the scroll position so log tailing isn't jarring.
    @objc func revealInFinder() {
        if let url = activeDocument?.url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc func reloadActiveFromDisk() {
        if let document = activeDocument {
            if document.isEdited {
                let alert = NSAlert()
                alert.messageText = "Reload \(document.fileName)?"
                alert.informativeText = "Reloading from disk will discard your unsaved changes."
                alert.addButton(withTitle: "Reload")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .warning
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn {
                        document.view.discardJournal()
                        self?.reload(document, from: document.url, preserveScroll: true)
                        document.view.startJournalFromCurrentFile()
                    }
                }
            } else {
                reload(document, from: document.url, preserveScroll: true)
            }
        }
    }

    /// Swaps a document's contents for a fresh map of `url` and restarts
    /// indexing, optionally keeping the current scroll position.
    func reload(_ document: Document, from url: URL, preserveScroll: Bool,
                        inheritingHistory: Bool = false) {
        guard let file = MappedFile(path: url.path) else {
            presentSaveError("Could not reopen \(url.lastPathComponent).")
            return
        }
        let previousRow = document.view.viewport.scrollRow
        let index = LineIndex()
        document.watcher?.cancel()
        document.view.close()
        document.reload(url: url, file: file, index: index)
        document.hasDiskChanges = false
        document.view.load(file: file, index: index, inheritingHistory: inheritingHistory)
        document.view.viewport.setFontSize(editorFontSize)
        document.view.setInfoPaneWidth(infoPaneWidth)
        document.view.setFileFormat(document.format)
        if preserveScroll {
            document.view.viewport.setScrollRow(previousRow)
        }
        document.watcher = FileWatcher(path: url.path) { [weak self, weak document] in
            if let self, let document {
                self.fileDidChangeOnDisk(document)
            }
        }
        index.build(from: file) { [weak self, weak document] in
            if let self, let document {
                self.documentDidUpdate(document)
            }
        }
        persistSession()

        if let position = documents.firstIndex(where: { $0 === document }) {
            sidebar.reloadRow(position)
            if position == activeIndex {
                selectDocument(at: position)
            }
        }
    }
}
