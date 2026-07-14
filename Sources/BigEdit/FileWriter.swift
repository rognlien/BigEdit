import Foundation

/// A cancellable flag shared with a background save.
final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Streams the document to a destination file, splicing in a replacement rule
/// as it goes.
///
/// The pass is **independent of the display match scan**: it runs its own
/// `memmem` over the mmap'd input, so the 1,000,000-match display cap is
/// irrelevant to save, and the writer does not wait for any search to finish.
///
/// Output goes to a temp file in the destination's directory, then `rename()`
/// atomically swaps it into place. A half-written file never appears at the
/// destination if anything fails midway.
enum FileWriter {

    enum WriteError: Error, LocalizedError {
        case cannotOpenTempFile(errno: Int32)
        case writeFailed(errno: Int32)
        case renameFailed(errno: Int32)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotOpenTempFile(let code):
                return "Could not create the temporary file (errno \(code))."
            case .writeFailed(let code):
                return "Write failed (errno \(code))."
            case .renameFailed(let code):
                return "Could not rename the temporary file into place (errno \(code))."
            case .cancelled:
                return "Save was cancelled."
            }
        }
    }

    private static let writeChunkSize = 16 * 1024 * 1024     // 16 MB
    private static let progressEveryBytes = 32 * 1024 * 1024 // 32 MB

    /// Writes `file` to `destination`, applying `rule` as it streams. Runs on a
    /// background queue; `onProgress` and `completion` fire on the main queue.
    static func save(
        file: MappedFile,
        rule: ReplacementRule,
        to destination: URL,
        cancelToken: CancelToken,
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, WriteError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = performWrite(destination: destination) { descriptor in
                streamToDescriptor(fd: descriptor, file: file, rule: rule,
                                   cancelToken: cancelToken) { fraction in
                    DispatchQueue.main.async { onProgress(fraction) }
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Writes synchronously on the calling thread. Used by `--replace`.
    static func saveSynchronously(
        file: MappedFile,
        rule: ReplacementRule,
        to destination: URL,
        cancelToken: CancelToken = CancelToken()
    ) -> Result<Void, WriteError> {
        return performWrite(destination: destination) { descriptor in
            streamToDescriptor(fd: descriptor, file: file, rule: rule,
                               cancelToken: cancelToken, onProgress: { _ in })
        }
    }

    // MARK: - Piece-table save

    /// Writes an edited `document` to `destination` by walking its piece
    /// table in logical order — original pieces stream from the mmap, added
    /// pieces from the add buffer. Constant memory regardless of file size.
    /// Runs on a background queue; callbacks fire on the main queue.
    static func save(
        document: EditedDocument,
        to destination: URL,
        cancelToken: CancelToken,
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, WriteError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = performWrite(destination: destination) { descriptor in
                streamPieces(fd: descriptor, document: document,
                             cancelToken: cancelToken) { fraction in
                    DispatchQueue.main.async { onProgress(fraction) }
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Piece-table save, synchronously on the calling thread. Used by tests.
    static func saveSynchronously(
        document: EditedDocument,
        to destination: URL,
        cancelToken: CancelToken = CancelToken()
    ) -> Result<Void, WriteError> {
        return performWrite(destination: destination) { descriptor in
            streamPieces(fd: descriptor, document: document,
                         cancelToken: cancelToken, onProgress: { _ in })
        }
    }

    // MARK: - Core

    /// Opens the temp file, runs `stream` into it, and atomically renames it
    /// over the destination on success.
    private static func performWrite(
        destination: URL,
        stream: (Int32) -> Result<Void, WriteError>
    ) -> Result<Void, WriteError> {
        let tempPath = destination.path + ".bigedit-tmp"
        let permissions = preservedMode(for: destination)

        let descriptor = open(tempPath, O_WRONLY | O_CREAT | O_TRUNC, permissions)
        if descriptor < 0 {
            return .failure(.cannotOpenTempFile(errno: errno))
        }

        let streamResult = stream(descriptor)
        close(descriptor)

        let result: Result<Void, WriteError>
        switch streamResult {
        case .success:
            if rename(tempPath, destination.path) == 0 {
                result = .success(())
            } else {
                let code = errno
                unlink(tempPath)
                result = .failure(.renameFailed(errno: code))
            }
        case .failure(let error):
            unlink(tempPath)
            result = .failure(error)
        }
        return result
    }

    /// The piece-walking loop: every piece streams zero-copy from its backing
    /// store in `writeChunkSize` slices.
    private static func streamPieces(
        fd: Int32,
        document: EditedDocument,
        cancelToken: CancelToken,
        onProgress: @escaping (Double) -> Void
    ) -> Result<Void, WriteError> {
        let total = document.length
        var result: Result<Void, WriteError> = .success(())

        if total > 0 {
            var written = 0
            var lastReportedBytes = 0
            let progress = { (bytes: Int) in
                if bytes - lastReportedBytes >= progressEveryBytes || bytes == total {
                    lastReportedBytes = bytes
                    onProgress(Double(bytes) / Double(total))
                }
            }

            for piece in document.pieceTable.pieces(in: 0..<total) where result.isSuccess {
                if cancelToken.isCancelled {
                    result = .failure(.cancelled)
                } else {
                    result = writePiece(piece, fd: fd, document: document,
                                        cancelToken: cancelToken,
                                        writtenBefore: written, progress: progress)
                    written += piece.length
                }
            }
        }
        if case .success = result {
            onProgress(1.0)
        }
        return result
    }

    private static func writePiece(
        _ piece: PieceTable.Piece,
        fd: Int32,
        document: EditedDocument,
        cancelToken: CancelToken,
        writtenBefore: Int,
        progress: (Int) -> Void
    ) -> Result<Void, WriteError> {
        var result: Result<Void, WriteError> = .success(())
        // Translate a within-piece offset into overall logical progress.
        let pieceProgress = { (offset: Int) in
            progress(writtenBefore + (offset - piece.start))
        }
        switch piece.source {
        case .original:
            if let base = document.file.buffer.baseAddress {
                result = writeRange(fd: fd, base: base, range: piece.start..<piece.end,
                                    cancelToken: cancelToken, progress: pieceProgress)
            }
        case .added:
            result = document.addBuffer.withUnsafeBytes(in: piece.start..<piece.end) { raw in
                var written: Result<Void, WriteError> = .success(())
                if let base = raw.baseAddress {
                    written = writeRange(fd: fd, base: base, range: 0..<raw.count,
                                         cancelToken: cancelToken) { offset in
                        progress(writtenBefore + offset)
                    }
                }
                return written
            }
        }
        return result
    }

    /// The streaming loop: copy original spans, splice the replacement at each
    /// match found by `memmem`.
    private static func streamToDescriptor(
        fd: Int32,
        file: MappedFile,
        rule: ReplacementRule,
        cancelToken: CancelToken,
        onProgress: @escaping (Double) -> Void
    ) -> Result<Void, WriteError> {
        let buffer = file.buffer
        let total = buffer.count

        guard total > 0, let base = buffer.baseAddress else {
            onProgress(1.0)
            return .success(())
        }

        let needleLength = rule.patternBytes.count
        var lastReportedBytes = 0
        var cursor = 0

        let progress = { (bytes: Int) in
            if bytes - lastReportedBytes >= progressEveryBytes || bytes == total {
                lastReportedBytes = bytes
                onProgress(Double(bytes) / Double(total))
            }
        }

        let result = rule.patternBytes.withUnsafeBytes { rawNeedle -> Result<Void, WriteError> in
            let needlePointer = rawNeedle.baseAddress!
            var step: Result<Void, WriteError> = .success(())

            while cursor < total && step.isSuccess {
                if cancelToken.isCancelled {
                    step = .failure(.cancelled)
                    break
                }
                let remaining = total - cursor
                if remaining < needleLength {
                    step = writeRange(fd: fd, base: base, range: cursor..<total,
                                      cancelToken: cancelToken, progress: progress)
                    cursor = total
                    break
                }
                if let hit = memmem(base + cursor, remaining, needlePointer, needleLength) {
                    let matchOffset = base.distance(to: UnsafeRawPointer(hit))
                    if matchOffset > cursor {
                        step = writeRange(fd: fd, base: base, range: cursor..<matchOffset,
                                          cancelToken: cancelToken, progress: progress)
                    }
                    if step.isSuccess, !rule.replacementBytes.isEmpty {
                        step = writeReplacement(fd: fd, bytes: rule.replacementBytes)
                    }
                    cursor = matchOffset + needleLength
                } else {
                    step = writeRange(fd: fd, base: base, range: cursor..<total,
                                      cancelToken: cancelToken, progress: progress)
                    cursor = total
                }
            }
            return step
        }
        if case .success = result {
            onProgress(1.0)
        }
        return result
    }

    /// Writes a slice of the original buffer in `writeChunkSize` pieces.
    private static func writeRange(
        fd: Int32,
        base: UnsafeRawPointer,
        range: Range<Int>,
        cancelToken: CancelToken,
        progress: (Int) -> Void
    ) -> Result<Void, WriteError> {
        var result: Result<Void, WriteError> = .success(())
        var offset = range.lowerBound
        while offset < range.upperBound && result.isSuccess {
            if cancelToken.isCancelled {
                result = .failure(.cancelled)
                break
            }
            let length = min(writeChunkSize, range.upperBound - offset)
            result = writeBytes(fd: fd, pointer: base + offset, count: length)
            if result.isSuccess {
                offset += length
                progress(offset)
            }
        }
        return result
    }

    private static func writeReplacement(fd: Int32, bytes: [UInt8]) -> Result<Void, WriteError> {
        return bytes.withUnsafeBytes { raw -> Result<Void, WriteError> in
            guard let pointer = raw.baseAddress else {
                return .success(())
            }
            return writeBytes(fd: fd, pointer: pointer, count: bytes.count)
        }
    }

    private static func writeBytes(fd: Int32, pointer: UnsafeRawPointer, count: Int) -> Result<Void, WriteError> {
        var result: Result<Void, WriteError> = .success(())
        var written = 0
        while written < count && result.isSuccess {
            let n = write(fd, pointer.advanced(by: written), count - written)
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                result = .failure(.writeFailed(errno: errno))
            } else if n == 0 {
                result = .failure(.writeFailed(errno: 0))
            } else {
                written += n
            }
        }
        return result
    }

    /// Picks permission bits for the temp file: those of the destination if it
    /// already exists (preserves the original's mode on overwrite), else 0644.
    private static func preservedMode(for destination: URL) -> mode_t {
        var info = stat()
        var mode: mode_t = 0o644
        if stat(destination.path, &info) == 0 {
            mode = info.st_mode & 0o777
        }
        return mode
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}
