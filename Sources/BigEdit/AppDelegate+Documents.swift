import AppKit

/// Opening, creating, selecting and closing documents, and what happens
/// when one changes on disk.
extension AppDelegate {

    /// Creates an empty file and opens it.
    ///
    /// BigEdit reads through `mmap`, so a document is always a real file —
    /// there is no untitled-and-unsaved state to fall back on. Asking where
    /// the file goes up front keeps every other part of the app (the file
    /// watcher, Open Recent, session restore, Save) working exactly as it does
    /// for a file that was already there.
    @objc func newDocument() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.txt"
        panel.canCreateDirectories = true
        panel.message = "Choose where to create the new file."
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.createAndOpenDocument(at: url)
            }
        }
    }

    /// Writes an empty file at `url` and opens it, replacing anything already
    /// there — the save panel has already asked about overwriting.
    private func createAndOpenDocument(at url: URL) {
        if FileManager.default.createFile(atPath: url.path, contents: Data()) {
            openDocuments(at: [url])
        } else {
            presentError("Could not create \(url.lastPathComponent).")
        }
    }

    /// Asks which line operation to run, then runs it over the whole document.
    @objc func showProcessLines() {
        guard let view = activeView, view.canProcessLines else {
            return
        }
        let sheet = ProcessLinesSheet()
        processLinesSheet = sheet
        sheet.present(in: window) { [weak self, weak view] operation in
            self?.processLinesSheet = nil
            if let operation, let view {
                self?.runProcessLines(operation, in: view)
            }
        }
    }

    private func runProcessLines(_ operation: LineOperation, in view: DocumentView) {
        view.processLines(operation) { [weak self] result in
            switch result {
            case .success:
                self?.updateTitle()
            case .failure(let error):
                self?.presentProcessLinesFailure(error)
            }
        }
    }

    private func presentProcessLinesFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        switch error {
        case DocumentView.ProcessLinesRefusal.tooLarge(let size, let limit):
            let formatter = ByteCountFormatter()
            alert.messageText = "This document is too large to process"
            alert.informativeText = "Processing lines holds the whole document in memory, so it "
                + "is limited to \(formatter.string(fromByteCount: Int64(limit))). "
                + "This one is \(formatter.string(fromByteCount: Int64(size)))."
        case DocumentView.ProcessLinesRefusal.notEditable:
            alert.messageText = "This document cannot be edited"
            alert.informativeText = "Processing lines rewrites the document, which is not "
                + "possible while a replacement rule or CSV view is active, or for a file that "
                + "is not UTF-8 text."
        case LineProcessor.ProcessingError.invalidPattern(let pattern):
            alert.messageText = "That pattern is not a valid regular expression"
            alert.informativeText = "“\(pattern)” could not be understood."
        default:
            alert.messageText = "Could not process the lines"
            alert.informativeText = "\(error)"
        }
        alert.beginSheetModal(for: window) { _ in }
    }

    @objc func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            if response == .OK {
                self?.openDocuments(at: panel.urls)
            }
        }
    }

    /// Opens each URL as a new document and selects the last one.
    func openDocuments(at urls: [URL]) {
        var lastOpened: Int?
        for url in urls {
            if let document = makeDocument(at: url) {
                documents.append(document)
                lastOpened = documents.count - 1
                addRecentDocument(url)
            } else {
                presentError("Could not open \(url.lastPathComponent).")
            }
        }
        if let lastOpened {
            sidebar.reload(documents: documents, selectedIndex: lastOpened)
            selectDocument(at: lastOpened)
        }
        persistSession()
    }

    /// Maps the file, builds a view + index, and kicks off background indexing.
    private func makeDocument(at url: URL) -> Document? {
        guard let file = MappedFile(path: url.path) else {
            return nil
        }
        let index = LineIndex()
        let view = DocumentView(frame: contentContainer.bounds)
        let document = Document(url: url, file: file, index: index, view: view)

        view.load(file: file, index: index)
        view.viewport.setFontSize(editorFontSize)
        view.setInfoPaneWidth(infoPaneWidth)
        view.onInfoPaneWidthChange = { [weak self] width in
            self?.setInfoPaneWidth(width)
        }
        view.setFileFormat(document.format)
        offerRecoveryIfPending(for: document)
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
        return document
    }

    /// If an earlier run left unsaved edits for this file, asks whether to
    /// bring them back; otherwise the journal starts fresh from the file.
    private func offerRecoveryIfPending(for document: Document) {
        let view = document.view
        var recovered = false
        if view.hasRecoverableEdits {
            let alert = NSAlert()
            alert.messageText = "Recover unsaved changes to \(document.fileName)?"
            alert.informativeText = "BigEdit did not quit normally the last time this file was "
                + "open, and the changes made then were not saved. They can be restored now."
            alert.addButton(withTitle: "Recover")
            alert.addButton(withTitle: "Discard")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                recovered = view.recoverEdits()
                if !recovered {
                    presentError("The unsaved changes to \(document.fileName) could not be recovered.")
                }
            }
        }
        if !recovered {
            view.startJournalFromCurrentFile()
        }
    }

    /// Marks a document as changed on disk and surfaces it (sidebar + title).
    func fileDidChangeOnDisk(_ document: Document) {
        guard let index = documents.firstIndex(where: { $0 === document }) else {
            return
        }
        if document.isFollowing && document.view.canFollow {
            absorbGrowth(of: document)
        } else {
            document.hasDiskChanges = true
            sidebar.reloadRow(index)
            if index == activeIndex {
                updateTitle()
            }
        }
    }

    /// Mounts the document at `index` and refreshes window chrome from it.
    func selectDocument(at index: Int) {
        guard documents.indices.contains(index) else {
            return
        }
        activeIndex = index
        let document = documents[index]
        contentContainer.setActiveView(document.view)
        window?.makeFirstResponder(document.view.viewport)
        window?.isDocumentEdited = document.isEdited
        sidebar.applySelection(index)
        updateTitle()
        persistSession()
    }

    @objc func closeActiveDocument() {
        if let activeIndex {
            closeDocument(at: activeIndex)
        }
    }

    /// Prompts about unsaved changes if needed, then tears down the document.
    func closeDocument(at index: Int) {
        guard documents.indices.contains(index) else {
            return
        }
        let document = documents[index]
        if document.isEdited {
            presentClosePrompt(for: document) { [weak self] shouldClose in
                if shouldClose, let self,
                   let position = self.documents.firstIndex(where: { $0 === document }) {
                    // Saved, or Don't Save: either way nothing is left to recover.
                    document.view.discardJournal()
                    self.tearDownDocument(at: position)
                }
            }
        } else {
            document.view.discardJournal()
            tearDownDocument(at: index)
        }
    }

    /// The standard Save / Don't Save / Cancel sheet for a dirty document.
    private func presentClosePrompt(for document: Document,
                                    completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.fileName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                if document.hasDiskChanges {
                    self?.presentDiskChangeConflict(for: document)
                    completion(false)
                } else {
                    self?.performSave(of: document, to: document.url) { saved in
                        completion(saved)
                    }
                }
            case .alertSecondButtonReturn:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    /// Removes the document at `index`, then selects a neighbour (or shows
    /// the empty state when the last one closes).
    private func tearDownDocument(at index: Int) {
        guard documents.indices.contains(index) else {
            return
        }
        let document = documents[index]
        document.watcher?.cancel()
        document.view.close()
        document.index.cancel()
        documents.remove(at: index)

        if documents.isEmpty {
            activeIndex = nil
            contentContainer.setActiveView(nil)
            window.isDocumentEdited = false
            sidebar.reload(documents: documents, selectedIndex: nil)
            updateTitle()
            persistSession()
        } else {
            let next = min(index, documents.count - 1)
            sidebar.reload(documents: documents, selectedIndex: next)
            selectDocument(at: next)
        }
    }

    /// Called as a document's index reports progress / completes. Refreshes its
    /// view and sidebar row, and the window title when it's the active document.
    func documentDidUpdate(_ document: Document) {
        guard let index = documents.firstIndex(where: { $0 === document }) else {
            return
        }
        // Re-apply a restored scroll position as the row count grows; clear it
        // once indexing is done and the target is final.
        if let pending = document.pendingScrollRow {
            document.view.viewport.setScrollRow(pending)
            if document.index.isComplete {
                document.pendingScrollRow = nil
            }
        }
        document.view.refresh()
        sidebar.reloadRow(index)
        if index == activeIndex {
            updateTitle()
        }
    }

    private func updateTitle() {
        // Just the file name, drawn by the centered title label. Size, line
        // count, encoding, and disk-change state live in the info pane / status
        // bar / sidebar instead.
        let name = activeDocument?.fileName ?? "BigEdit"
        window?.title = name          // keeps the Window menu / app switcher correct
        titleLabel.stringValue = name
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Cannot Open File"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    func presentSaveError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Save Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
