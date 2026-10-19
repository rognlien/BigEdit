import AppKit

extension DocumentView {

    /// The journal for a document over `file` — none while a kept journal
    /// occupies the same directory.
    func openJournal(for file: MappedFile) -> EditJournal? {
        var result: EditJournal?
        if keptJournal?.directory != EditJournal.directory(for: file.path) {
            result = EditJournal.open(for: file.path)
        }
        return result
    }

    /// What the journal for this file holds from an earlier run, and whether
    /// it still applies to the file as it is on disk.
    var journalRecoveryState: EditJournal.RecoveryState {
        var result = EditJournal.RecoveryState.nothingPending
        if let document = viewport.document, let journal = document.journal {
            result = journal.recoveryState(for: document.file)
        }
        return result
    }

    /// Replays the pending journal into the document. Returns false if it
    /// could not be replayed, in which case nothing changed. Adopting the
    /// baseline makes the file as it is now the one the replayed ops stand
    /// against, for a recovery the user chose despite a changed file.
    func recoverEdits(adoptingBaseline: Bool = false) -> Bool {
        var recovered = false
        if let document = viewport.document, let journal = document.journal {
            recovered = document.recover(from: journal)
            if recovered {
                if adoptingBaseline {
                    journal.adoptBaseline(document.file)
                }
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
            document.journal?.setBaseline(document.file, mirroring: document.addBuffer)
        }
    }

    /// Leaves the pending journal on disk for a later open, and stops this
    /// document from journaling over it: the two would share a directory.
    func keepPendingJournal() {
        keptJournal = viewport.document?.journal
        viewport.document?.journal = nil
    }

    /// Whether the journal alone could rebuild the document as it is: every
    /// edit is in it and replayable, and no deferred rule (which is never
    /// journaled) is pending.
    var journalHoldsEveryEdit: Bool {
        currentRule == nil && viewport.document?.journal?.isReplayable == true
    }

    /// Removes the journal: the document closed cleanly or its unsaved edits
    /// were deliberately discarded.
    func discardJournal() {
        viewport.document?.journal?.discard()
    }
}
