import Foundation

/// A background pass that counts words and characters across the file.
///
/// `LineIndex` only needs to find newlines and so uses `memchr` (which can
/// skip over huge runs of bytes). Word and character counts need to look at
/// every byte, so they live in their own scanner that runs only when the
/// info pane needs the values. Counts are published in chunks so the pane
/// can show progress on long files.
final class StatisticsScan {

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

        var words = 0
        var chars = 0
        var inWord = false
        var offset = 0

        while offset < total && !isStopped() {
            let chunkEnd = min(total, offset + chunkSize)
            var index = offset
            while index < chunkEnd {
                let byte = bytePointer[index]
                let isWhitespace = byte == 0x20 || byte == 0x09 || byte == 0x0A
                    || byte == 0x0D || byte == 0x0B || byte == 0x0C
                if isWhitespace {
                    inWord = false
                } else if !inWord {
                    inWord = true
                    words += 1
                }
                // A UTF-8 character starts at any byte that is *not* a
                // continuation byte (0b10xxxxxx).
                if (byte & 0xC0) != 0x80 {
                    chars += 1
                }
                index += 1
            }
            offset = chunkEnd
            publish(words: words, chars: chars, bytes: offset)
            onProgress()
        }

        publish(words: words, chars: chars, bytes: offset)
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
