import AppKit

extension DocumentView {

    /// Whether the journal for this file holds unsaved edits from an earlier
    /// run that still apply to the file as it is on disk.
    var hasRecoverableEdits: Bool {
        var result = false
        if let document = viewport.document, let journal = document.journal {
            result = journal.hasRecoverableEdits(for: document.file)
        }
        return result
    }

    /// Replays the pending journal into the document. Returns false if it
    /// could not be replayed, in which case nothing changed.
    func recoverEdits() -> Bool {
        var recovered = false
        if let document = viewport.document, let journal = document.journal {
            recovered = document.recover(from: journal)
            if recovered {
                viewport.documentDidChangeProgrammatically()
                documentWasEdited()
            }
        }
        return recovered
    }

    /// Makes the current file the journal's baseline, dropping whatever
    /// operations it held. Called on a fresh open, and after every save.
    func startJournalFromCurrentFile() {
        if let document = viewport.document {
            document.journal?.setBaseline(document.file,
                                          retainingAddedBytes: document.addBuffer.count > 0)
        }
    }

    /// Removes the journal: the document closed cleanly or its unsaved edits
    /// were deliberately discarded.
    func discardJournal() {
        viewport.document?.journal?.discard()
    }
}
