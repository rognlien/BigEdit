import AppKit

/// Opening, creating, selecting and closing documents, and what happens
/// when one changes on disk.
extension AppDelegate {

    /// Opens a new untitled document. BigEdit reads through `mmap`, so it is
    /// an empty placeholder file until its first save asks where it goes.
    @objc func newDocument() {
        if let url = untitledDocuments.makePlaceholder() {
            openDocuments(at: [url])
        } else {
            presentError("Could not create a new document.")
        }
    }

    /// The number a newly opened untitled document is shown with.
    private func nextUntitledNumber() -> Int {
        UntitledDocuments.lowestUnusedNumber(among: documents.compactMap(\.untitledNumber))
    }

    /// Asks which line operation to run, then runs it over the whole document.
    @objc func showProcessLines() {
        guard let view = activeView, view.canProcessLines else {
            return
        }
        view.leaveRenderedMarkdown()
        let sheet = ProcessLinesSheet()
        sheet.sampleText = view.sampleText()
        processLinesSheet = sheet
        sheet.present(in: window, otherLists: otherLineLists(excluding: view)) {
            [weak self, weak view] request in
            self?.processLinesSheet = nil
            if let request, let view {
                self?.runProcessLines(request, in: view)
            }
        }
    }

    /// Every other open document as a list a set operation can compare
    /// against, in sidebar order.
    func otherLineLists(excluding view: DocumentView) -> [OtherLineList] {
        documents.compactMap { document in
            guard document.view !== view, let edited = document.view.editedDocument else {
                return nil
            }
            return OtherLineList.document(named: document.fileName, edited)
        }
    }

    private func runProcessLines(_ request: ProcessLinesRequest, in view: DocumentView) {
        let completion: (Result<Int, Error>) -> Void = { [weak self] result in
            switch result {
            case .success:
                self?.updateTitle()
            case .failure(let error):
                self?.presentProcessLinesFailure(error)
            }
        }
        switch request {
        case .operation(let operation):
            view.processLines(operation, completion: completion)
        case .setOperation(let kind, let other, let options):
            let length = view.editedDocument?.length ?? 0
            if length > DocumentView.processLinesSizeLimit && view.canStreamSetOperation(kind) {
                offerStreamedSetOperation(kind, other: other, options: options, in: view)
            } else {
                view.processSetOperation(kind, other: other, options: options,
                                         completion: completion)
            }
        }
    }

    /// A document above the ceiling cannot be rewritten in place, but a
    /// filtering set operation can still stream its result to a new file:
    /// ask where, write it, and open what was written.
    private func offerStreamedSetOperation(_ kind: SetOperationKind, other: OtherLineList,
                                           options: LineMatchOptions, in view: DocumentView) {
        let formatter = ByteCountFormatter()
        let alert = NSAlert()
        alert.messageText = "This document is too large to rewrite in place"
        alert.informativeText = "Documents over "
            + "\(formatter.string(fromByteCount: Int64(DocumentView.processLinesSizeLimit))) "
            + "are not held in memory, but this operation can still read the document once and "
            + "write the lines it keeps to a new file."
        alert.addButton(withTitle: "Write to New File…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak view] response in
            guard response == .alertFirstButtonReturn, let self, let view else {
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = self.suggestedResultName(for: view)
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: self.window) { [weak self, weak view] response in
                if response == .OK, let url = panel.url, let view {
                    self?.streamSetOperation(kind, other: other, options: options,
                                             in: view, to: url)
                }
            }
        }
    }

    private func suggestedResultName(for view: DocumentView) -> String {
        let name = activeDocument?.url ?? URL(fileURLWithPath: "Result.txt")
        let stem = name.deletingPathExtension().lastPathComponent
        let suffix = name.pathExtension.isEmpty ? "" : ".\(name.pathExtension)"
        return "\(stem) (filtered)\(suffix)"
    }

    private func streamSetOperation(_ kind: SetOperationKind, other: OtherLineList,
                                    options: LineMatchOptions, in view: DocumentView,
                                    to destination: URL) {
        view.streamSetOperation(kind, other: other, options: options, to: destination) {
            [weak self] result in
            switch result {
            case .success(let count):
                if count != nil {
                    self?.openDocuments(at: [destination])
                }
            case .failure(let error):
                self?.presentProcessLinesFailure(error)
            }
        }
    }

    func presentProcessLinesFailure(_ error: Error) {
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
                + "possible while a replacement rule is active, or for a file that is not "
                + "UTF-8 text."
        case DocumentView.ProcessLinesRefusal.cannotReadOtherList(let name):
            alert.messageText = "The other list could not be read"
            alert.informativeText = "“\(name)” could not be opened."
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

    /// Opens each URL as a new document, or finds the document already
    /// showing that file, and selects the last one. The URLs are files on
    /// this Mac; `openDocuments(at:)` is the entry point that also fetches
    /// what iCloud has not downloaded.
    func openReadyDocuments(at urls: [URL]) {
        var lastOpened: Int?
        for url in urls {
            if let open = FileIdentity.firstIndex(of: url, in: documents.map(\.url)) {
                lastOpened = open
                addRecentDocument(url)
            } else if let document = makeDocument(at: url) {
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
        if untitledDocuments.contains(url) {
            document.untitledNumber = nextUntitledNumber()
        }

        view.load(file: file, index: index)
        view.apply(settings)
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

    /// What to do with unsaved edits an earlier run left for a file.
    private enum RecoveryChoice {
        case recover(adoptingBaseline: Bool)
        case keepForLater
        case discard
    }

    /// If an earlier run left unsaved edits for this file, asks what to do
    /// with them; otherwise the journal starts fresh from the file.
    private func offerRecoveryIfPending(for document: Document) {
        var choice = RecoveryChoice.discard
        switch document.view.journalRecoveryState {
        case .nothingPending:
            break
        case .recoverable:
            // Quitting left an untitled document's text in its journal.
            choice = document.isUntitled ? .recover(adoptingBaseline: false) : askToRecover(document)
        case .baselineUncertain:
            choice = askToRecoverOntoModifiedFile(document)
        case .baselineChanged:
            choice = askToKeepUnrecoverableEdits(document)
        }
        apply(choice, to: document)
    }

    private func apply(_ choice: RecoveryChoice, to document: Document) {
        let view = document.view
        switch choice {
        case .recover(let adoptingBaseline):
            if !view.recoverEdits(adoptingBaseline: adoptingBaseline) {
                presentError("The unsaved changes to \(document.fileName) could not be recovered.")
                view.startJournalFromCurrentFile()
            }
        case .keepForLater:
            view.keepPendingJournal()
        case .discard:
            view.startJournalFromCurrentFile()
        }
    }

    private func askToRecover(_ document: Document) -> RecoveryChoice {
        let alert = NSAlert()
        alert.messageText = "Recover unsaved changes to \(document.fileName)?"
        alert.informativeText = "BigEdit did not quit normally the last time this file was "
            + "open, and the changes made then were not saved. They can be restored now."
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Discard")
        alert.alertStyle = .warning
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .recover(adoptingBaseline: false) : .discard
    }

    /// The file is the same size with the same text at both ends, but its
    /// date or identity changed: it may be untouched, or edited in the middle.
    private func askToRecoverOntoModifiedFile(_ document: Document) -> RecoveryChoice {
        let alert = NSAlert()
        alert.messageText = "Recover unsaved changes to \(document.fileName)?"
        alert.informativeText = "BigEdit did not quit normally the last time this file was "
            + "open, and the changes made then were not saved. The file has been modified "
            + "since then. If its contents changed, the recovered changes will be put in the "
            + "wrong places, so check the document before you save it."
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Recover Anyway")
        alert.addButton(withTitle: "Discard")
        alert.alertStyle = .warning
        var choice = RecoveryChoice.keepForLater
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            choice = .recover(adoptingBaseline: true)
        case .alertThirdButtonReturn:
            choice = .discard
        default:
            break
        }
        return choice
    }

    /// The edits are splices onto bytes the file no longer has, so they are
    /// never applied; kept, they can still be recovered if the earlier
    /// version of the file comes back.
    private func askToKeepUnrecoverableEdits(_ document: Document) -> RecoveryChoice {
        let alert = NSAlert()
        alert.messageText = "The unsaved changes to \(document.fileName) can’t be recovered"
        alert.informativeText = "BigEdit did not quit normally the last time this file was "
            + "open, and the file has been changed since then. The unsaved changes were made "
            + "to the earlier version and can’t be applied to this one. If you restore the "
            + "earlier version, they can be recovered the next time you open it."
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Discard")
        alert.alertStyle = .warning
        let response = alert.runModal()
        return response == .alertSecondButtonReturn ? .discard : .keepForLater
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
        if document.asksBeforeClosing {
            presentClosePrompt(for: document) { [weak self] shouldClose in
                if shouldClose, let self,
                   let position = self.documents.firstIndex(where: { $0 === document }) {
                    // Saved, or Don't Save: either way nothing is left to recover.
                    self.discardLeftovers(of: document)
                    self.tearDownDocument(at: position)
                }
            }
        } else {
            discardLeftovers(of: document)
            tearDownDocument(at: index)
        }
    }

    /// Removes what a closed document leaves on disk: its journal, and the
    /// placeholder of one still untitled.
    private func discardLeftovers(of document: Document) {
        document.view.discardJournal()
        if document.isUntitled {
            try? FileManager.default.removeItem(at: document.url)
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
                if document.isUntitled {
                    self?.saveUntitled(document, completion: completion)
                } else if document.hasDiskChanges {
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
        // Just the file name, with the file as the window's represented URL so
        // the title bar gets the proxy icon and ⌘-click path menu. Size, line
        // count, encoding, and disk-change state live in the info pane / status
        // bar / sidebar instead.
        window?.title = activeDocument?.fileName ?? "BigEdit"
        window?.representedURL = activeDocument.flatMap { $0.isUntitled ? nil : $0.url }
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
