import AppKit

/// Replace All: materialised as undoable edits under a cap, otherwise a
/// deferred replacement rule.
extension DocumentView {

    /// Matches at or below this count are applied as real (undoable) edits;
    /// above it, Replace All falls back to the deferred rule. The bound keeps
    /// the per-edit layout bookkeeping comfortably interactive.
    private static let replaceAllMaterializeLimit = 2_000

    func findBar(_ bar: FindBar, didRequestReplaceAll pattern: String, with replacement: String) {
        if let document = viewport.document, document.isEditable, editModel.rule == nil {
            startMaterializedReplaceAll(in: document, pattern: pattern, replacement: replacement)
        } else if bar.isRegularExpression {
            // The deferred rule matches literal bytes; a pattern can only be
            // replaced where the result can be applied as edits.
            findBar.updateReplaceStatus("Patterns replace only in an editable document")
        } else if viewport.document?.hasEdits == true {
            // The deferred rule and positional edits are mutually exclusive.
            findBar.updateReplaceStatus("Save your edits first")
        } else if let rule = ReplacementRule(pattern: pattern, replacement: replacement),
                  let file = viewport.file {
            editModel.setRule(rule, file: file) { [weak self] in
                self?.editScanDidProgress()
            }
            viewport.needsDisplay = true
            updateEditStatus()
        } else {
            findBar.updateReplaceStatus("Invalid pattern")
        }
    }

    /// Scans for `pattern` over the logical document, then applies the
    /// replacements as one undoable step — or falls back to the deferred
    /// rule when there are too many.
    private func startMaterializedReplaceAll(
        in document: EditedDocument, pattern: String, replacement: String
    ) {
        replaceAllScan?.cancel()
        guard let scan = makeSearchScan(pattern, caseSensitive: true) else {
            findBar.updateReplaceStatus("Invalid pattern")
            return
        }
        replaceAllScan = scan
        findBar.updateReplaceStatus("Scanning…")
        scan.start(in: document) { [weak self, weak scan] in
            if let self, let scan, self.replaceAllScan === scan {
                if scan.isComplete {
                    self.replaceAllScan = nil
                    self.finishReplaceAll(scan: scan, pattern: pattern,
                                          replacement: replacement, in: document)
                } else {
                    self.findBar.updateReplaceStatus(
                        "Scanning… \(Int(scan.scanProgress * 100))%")
                }
            }
        }
    }

    private func finishReplaceAll(
        scan: SearchScan, pattern: String, replacement: String, in document: EditedDocument
    ) {
        let count = scan.matchCount
        if count == 0 {
            findBar.updateReplaceStatus("Not found")
        } else if count <= DocumentView.replaceAllMaterializeLimit && !scan.isTruncated {
            materializeReplaceAll(scan: scan, replacement: replacement, in: document)
            let formatted = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
            findBar.updateReplaceStatus("\(formatted) replaced")
        } else if scan.isRegularExpression {
            findBar.updateReplaceStatus("Too many matches for a pattern to replace")
        } else if !document.hasEdits,
                  let rule = ReplacementRule(pattern: pattern, replacement: replacement) {
            // Too many occurrences to hold as positional edits — fall back to
            // the deferred rule, applied streaming at save time.
            editModel.setRule(rule, file: document.file) { [weak self] in
                self?.editScanDidProgress()
            }
            viewport.needsDisplay = true
            updateEditStatus()
        } else {
            findBar.updateReplaceStatus("Too many matches to replace with unsaved edits")
        }
    }

    /// Applies every match back-to-front (so earlier offsets stay valid) as
    /// one grouped undo step.
    private func materializeReplaceAll(
        scan: SearchScan, replacement: String, in document: EditedDocument
    ) {
        let matches = scan.matches(beginningIn: 0..<Int.max)
        let replacementBytes = Array(replacement.utf8)
        document.undoStack.beginGrouping()
        for match in matches.reversed() {
            document.replace(match, with: replacementBytes)
        }
        document.undoStack.endGrouping()
        viewport.documentDidChangeProgrammatically()
        documentWasEdited()
    }

    func findBarRequestedRevert(_ bar: FindBar) {
        editModel.clear()
        viewport.needsDisplay = true
        updateEditStatus()
    }
}
