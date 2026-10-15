import AppKit

/// Compare Documents: two open documents as sets of lines, shown in a
/// window of their own.
extension AppDelegate {

    /// The largest document the comparison will hold. Both lists are read
    /// into memory whole, with a key per line, so this is a few times the
    /// Process Lines ceiling rather than unbounded.
    static let compareSizeLimit = 8 * DocumentView.processLinesSizeLimit

    var canCompareDocuments: Bool {
        documents.count >= 2
    }

    /// Asks which two documents to compare, then compares them.
    @objc func showCompareDocuments() {
        guard canCompareDocuments else {
            return
        }
        let lists = documents.compactMap { document -> OtherLineList? in
            guard let edited = document.view.editedDocument else {
                return nil
            }
            return OtherLineList.document(named: document.fileName, edited)
        }
        let sheet = CompareDocumentsSheet()
        compareSheet = sheet
        sheet.present(in: window, lists: lists, activeIndex: activeIndex ?? 0) { [weak self] request in
            self?.compareSheet = nil
            if let request {
                self?.runComparison(request)
            }
        }
    }

    /// Loads both lists off the main thread, compares them behind a
    /// cancellable sheet, and opens the result window.
    func runComparison(_ request: CompareRequest) {
        for list in [request.first, request.second] where list.byteCount > AppDelegate.compareSizeLimit {
            presentCompareRefusal(list)
            return
        }
        let sheet = SaveProgressSheet(title: "Comparing \(request.first.name) with \(request.second.name)…")
        let token = CancelToken()
        sheet.onCancel = { token.cancel() }
        sheet.setIndeterminate()
        saveProgressSheet = sheet
        window.beginSheet(sheet.window) { _ in }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var outcome: Result<[CompareSection]?, Error>
            do {
                guard let first = request.first.loadLines() else {
                    throw DocumentView.ProcessLinesRefusal.cannotReadOtherList(name: request.first.name)
                }
                guard let second = request.second.loadLines() else {
                    throw DocumentView.ProcessLinesRefusal.cannotReadOtherList(name: request.second.name)
                }
                let sections = try AppDelegate.compareSections(
                    first: first, second: second, request: request,
                    isCancelled: { token.isCancelled })
                outcome = .success(sections)
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.window.endSheet(sheet.window)
                self.saveProgressSheet = nil
                switch outcome {
                case .success(let sections):
                    if let sections {
                        self.showCompareResults(sections, for: request)
                    }
                case .failure(let error):
                    self.presentProcessLinesFailure(error)
                }
            }
        }
    }

    /// The sections of the result window, or `nil` when cancelled.
    static func compareSections(first: [String], second: [String], request: CompareRequest,
                                isCancelled: () -> Bool) throws -> [CompareSection]? {
        guard let comparison = try LineSetComparison.compare(
            first, second, options: request.options, isCancelled: isCancelled) else {
            return nil
        }
        let firstStem = stem(of: request.first.name)
        let secondStem = stem(of: request.second.name)
        guard let edits = LineDiff.diff(first, second, isCancelled: isCancelled) else {
            return nil
        }
        let changes = changeRows(edits, first: first, second: second, request: request)
        return [
            CompareSection(title: "Only in \(request.first.name)",
                           rows: comparison.onlyInFirst.map { CompareRow($0) },
                           suggestedFileName: "Only in \(firstStem).txt"),
            CompareSection(title: "Only in \(request.second.name)",
                           rows: comparison.onlyInSecond.map { CompareRow($0) },
                           suggestedFileName: "Only in \(secondStem).txt"),
            CompareSection(title: "In both",
                           rows: comparison.inBoth.map { CompareRow($0) },
                           suggestedFileName: "In both \(firstStem) and \(secondStem).txt"),
            CompareSection(title: "Changes", rows: changes,
                           suggestedFileName: "\(firstStem) to \(secondStem).diff")
        ]
    }

    /// The sequence diff as rows: the two file-name lines, then each hunk's
    /// header and its prefixed lines — joined, exactly the unified diff
    /// `diff -u` would write, which is what Save As… exports.
    static func changeRows(_ edits: [LineDiff.Edit], first: [String], second: [String],
                           request: CompareRequest) -> [CompareRow] {
        var rows = [
            CompareRow("--- \(request.first.name)", kind: .header),
            CompareRow("+++ \(request.second.name)", kind: .header)
        ]
        for hunk in LineDiff.hunks(edits, first: first, second: second, context: 3) {
            rows.append(CompareRow(hunk.header, kind: .header))
            for line in hunk.lines {
                let kind: CompareRow.Kind
                switch line.first {
                case "+": kind = .added
                case "-": kind = .removed
                default: kind = .context
                }
                rows.append(CompareRow(line, kind: kind))
            }
        }
        return rows
    }

    private static func stem(of fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        return url.deletingPathExtension().lastPathComponent
    }

    private func showCompareResults(_ sections: [CompareSection], for request: CompareRequest) {
        let results = CompareResultsWindow(
            title: "\(request.first.name) compared with \(request.second.name)",
            sections: sections)
        results.onOpenAsDocument = { [weak self] text, fileName in
            self?.openText(text, named: fileName)
        }
        results.onClose = { [weak self, weak results] in
            self?.compareWindows.removeAll { $0 === results }
        }
        compareWindows.append(results)
        results.show(relativeTo: window)
    }

    /// Writes `text` to a fresh file in the temporary directory and opens it
    /// as a document — every document is a real file, and Save As… moves it
    /// somewhere permanent.
    func openText(_ text: String, named fileName: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEdit-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName)
            try text.write(to: url, atomically: true, encoding: .utf8)
            openDocuments(at: [url])
        } catch {
            presentSaveError("Could not write \(fileName): \(error.localizedDescription)")
        }
    }

    private func presentCompareRefusal(_ list: OtherLineList) {
        let formatter = ByteCountFormatter()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(list.name) is too large to compare"
        alert.informativeText = "Comparing holds both documents in memory, so each is limited to "
            + "\(formatter.string(fromByteCount: Int64(AppDelegate.compareSizeLimit))). "
            + "This one is \(formatter.string(fromByteCount: Int64(list.byteCount)))."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }
}
