import Foundation

/// A background pass that counts words and characters across the file.
///
/// `LineIndex` only needs to find newlines and so uses `memchr` (which can
/// skip over huge runs of bytes). Word and character counts need to look at
/// every byte, so they live in their own scanner that runs only when the
/// info pane needs the values. Counts are published in chunks so the pane
/// can show progress on long files.
final class StatisticsScan {

    /// The document's encoding: in a single-byte encoding every byte is a
    /// character, where UTF-8 counts only the bytes that begin one.
    private let encoding: TextEncoding

    init(encoding: TextEncoding = .utf8) {
        self.encoding = encoding
    }

    private let lock = NSLock()
    private var wordCountInternal = 0
    private var characterCountInternal = 0
    private var bytesScannedInternal = 0
    private var totalBytesInternal = 0
    private var scanComplete = false
    private var stopped = false

    var wordCount: Int {
        lock.lock(); defer { lock.unlock() }
        return wordCountInternal
    }

    var characterCount: Int {
        lock.lock(); defer { lock.unlock() }
        return characterCountInternal
    }

    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return scanComplete
    }

    /// Fraction of the file scanned so far.
    var progress: Double {
        lock.lock(); defer { lock.unlock() }
        return totalBytesInternal > 0 ? Double(bytesScannedInternal) / Double(totalBytesInternal) : 1
    }

    /// Stops the background scan; further results are not published.
    func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    /// The running counts, carried across chunk and piece boundaries so a
    /// word split by a boundary is still counted once.
    private struct Tally {
        var words = 0
        var characters = 0
        var inWord = false
        var everyByteIsACharacter = false

        mutating func consume(_ byte: UInt8) {
            let isWhitespace = byte == 0x20 || byte == 0x09 || byte == 0x0A
                || byte == 0x0D || byte == 0x0B || byte == 0x0C
            if isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
            // A UTF-8 character starts at any byte that is *not* a
            // continuation byte (0b10xxxxxx); elsewhere every byte is one.
            if everyByteIsACharacter || (byte & 0xC0) != 0x80 {
                characters += 1
            }
        }
    }

    private func makeTally() -> Tally {
        var tally = Tally()
        tally.everyByteIsACharacter = encoding.isSingleByte
        return tally
    }

    /// Counts the edited document on a background queue.
    ///
    /// Without edits this is the zero-copy mmap scan. With edits it walks a
    /// snapshot of the piece table, so the counts describe what is on screen
    /// rather than what is still on disk, and the scan is stable even while
    /// further edits arrive — the owner cancels and re-runs on each one.
    func start(in document: EditedDocument, onProgress: @escaping () -> Void) {
        if document.hasEdits {
            let pieces = document.pieceTable.pieces(in: 0..<document.length)
            let length = document.length
            let file = document.file
            let added = document.addBuffer
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.scanPieces(pieces: pieces, length: length, file: file, added: added) {
                    DispatchQueue.main.async(execute: onProgress)
                }
            }
        } else {
            start(in: document.file, onProgress: onProgress)
        }
    }

    /// Piece-walking count on the current thread — used by tests.
    func runSynchronously(in document: EditedDocument) {
        if document.hasEdits {
            scanPieces(pieces: document.pieceTable.pieces(in: 0..<document.length),
                       length: document.length,
                       file: document.file,
                       added: document.addBuffer,
                       onProgress: {})
        } else {
            runSynchronously(in: document.file)
        }
    }

    /// Walks the piece snapshot in logical order, counting as it goes.
    private func scanPieces(pieces: [PieceTable.Piece], length: Int, file: MappedFile,
                            added: AddedByteStore, onProgress: () -> Void) {
        lock.lock()
        totalBytesInternal = length
        bytesScannedInternal = 0
        lock.unlock()

        var tally = makeTally()
        var scanned = 0
        let chunkSize = 4 * 1024 * 1024

        for piece in pieces where !isStopped() {
            var offset = 0
            while offset < piece.length && !isStopped() {
                let take = min(chunkSize, piece.length - offset)
                let range = (piece.start + offset)..<(piece.start + offset + take)
                switch piece.source {
                case .original:
                    for byte in file.buffer[range] {
                        tally.consume(byte)
                    }
                case .added:
                    for byte in added.bytes(in: range) {
                        tally.consume(byte)
                    }
                }
                offset += take
                scanned += take
                publish(words: tally.words, chars: tally.characters, bytes: scanned)
                onProgress()
            }
        }

        publish(words: tally.words, chars: tally.characters, bytes: scanned)
        markComplete()
        onProgress()
    }

    /// Counts on a background queue; `onProgress` fires on the main queue.
    func start(in file: MappedFile, onProgress: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.scan(file: file) {
                DispatchQueue.main.async(execute: onProgress)
            }
        }
    }

    /// Runs synchronously on the calling thread. Used by `--stats`.
    func runSynchronously(in file: MappedFile) {
        scan(file: file, onProgress: {})
    }

    private func scan(file: MappedFile, onProgress: () -> Void) {
        let buffer = file.buffer
        let total = buffer.count

        lock.lock()
        totalBytesInternal = total
        bytesScannedInternal = 0
        lock.unlock()

        guard let base = buffer.baseAddress, total > 0 else {
            markComplete()
            onProgress()
            return
        }

        let bytePointer = base.assumingMemoryBound(to: UInt8.self)
        let chunkSize = 16 * 1024 * 1024

        var tally = makeTally()
        var offset = 0

        while offset < total && !isStopped() {
            let chunkEnd = min(total, offset + chunkSize)
            var index = offset
            while index < chunkEnd {
                tally.consume(bytePointer[index])
                index += 1
            }
            offset = chunkEnd
            publish(words: tally.words, chars: tally.characters, bytes: offset)
            onProgress()
        }

        publish(words: tally.words, chars: tally.characters, bytes: offset)
        markComplete()
        onProgress()
    }

    private func publish(words: Int, chars: Int, bytes: Int) {
        lock.lock()
        wordCountInternal = words
        characterCountInternal = chars
        bytesScannedInternal = bytes
        lock.unlock()
    }

    private func markComplete() {
        lock.lock()
        scanComplete = true
        lock.unlock()
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
