import Foundation

/// Append-only bytes on disk, for an add buffer grown too large to keep in
/// memory.
///
/// The file is unlinked as soon as it is opened, so it takes no name in the
/// directory and the system reclaims its space when the descriptor closes —
/// on release, or when the process ends however it ends. Appends are
/// `pwrite`s; reads are `pread`s, the small ones (what the layout and the
/// renderer ask for) through a cache of recently read pages.
///
/// Not thread-safe: the add buffer serialises access.
final class SpillFile {

    static let pageLength = 64 * 1024
    static let cachedPageLimit = 64

    /// Reads at least this long skip the cache: they are scans and saves,
    /// which would only push out the pages on screen.
    static let uncachedReadLength = 4 * pageLength

    private let descriptor: Int32
    private(set) var count = 0

    /// Whole pages only: a partial last page still grows.
    private var cachedPages: [Int: [UInt8]] = [:]
    private var recentPageIndexes: [Int] = []

    /// Opens a new spill file in `directory`, or returns nil if it cannot
    /// be created.
    init?(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(UUID().uuidString).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            return nil
        }
        unlink(path)
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    // MARK: - Writing

    /// Appends `buffer`. False if the disk refused it, in which case the
    /// count is unchanged and whatever part was written is ignored.
    func append(_ buffer: UnsafeRawBufferPointer) -> Bool {
        var written = 0
        var failed = false
        while written < buffer.count && !failed, let base = buffer.baseAddress {
            let result = pwrite(descriptor, base + written, buffer.count - written, off_t(count + written))
            if result > 0 {
                written += result
            } else if result == 0 || errno != EINTR {
                failed = true
            }
        }
        if !failed {
            count += buffer.count
        }
        return !failed
    }

    // MARK: - Reading

    /// Copies the bytes in `range`, which must lie within `count`.
    func bytes(in range: Range<Int>) -> [UInt8] {
        var result: [UInt8]
        if range.count >= SpillFile.uncachedReadLength {
            result = read(range)
        } else {
            result = cachedBytes(in: range)
        }
        return result
    }

    private func cachedBytes(in range: Range<Int>) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(range.count)
        var offset = range.lowerBound
        var progressing = true
        while offset < range.upperBound && progressing {
            let pageIndex = offset / SpillFile.pageLength
            let pageStart = pageIndex * SpillFile.pageLength
            let page = self.page(at: pageIndex)
            let end = min(range.upperBound, pageStart + page.count)
            progressing = end > offset
            if progressing {
                result.append(contentsOf: page[(offset - pageStart)..<(end - pageStart)])
                offset = end
            }
        }
        return result
    }

    private func page(at index: Int) -> [UInt8] {
        let page: [UInt8]
        if let cached = cachedPages[index] {
            page = cached
            markRecent(index)
        } else {
            let start = index * SpillFile.pageLength
            page = read(start..<min(count, start + SpillFile.pageLength))
            if page.count == SpillFile.pageLength {
                cache(page, at: index)
            }
        }
        return page
    }

    private func cache(_ page: [UInt8], at index: Int) {
        cachedPages[index] = page
        recentPageIndexes.append(index)
        if recentPageIndexes.count > SpillFile.cachedPageLimit {
            cachedPages[recentPageIndexes.removeFirst()] = nil
        }
    }

    private func markRecent(_ index: Int) {
        if let position = recentPageIndexes.lastIndex(of: index) {
            recentPageIndexes.remove(at: position)
        }
        recentPageIndexes.append(index)
    }

    /// Reads `range` straight from the file; shorter only if the file is.
    private func read(_ range: Range<Int>) -> [UInt8] {
        [UInt8](unsafeUninitializedCapacity: range.count) { buffer, initializedCount in
            var done = false
            while initializedCount < range.count && !done, let base = buffer.baseAddress {
                let result = pread(descriptor, base + initializedCount, range.count - initializedCount,
                                   off_t(range.lowerBound + initializedCount))
                if result > 0 {
                    initializedCount += result
                } else if result == 0 || errno != EINTR {
                    done = true
                }
            }
        }
    }

    // MARK: - Leftovers

    /// Removes files in `directory` older than `age`. A spill file is
    /// unlinked the moment it is opened, so anything there is one a crash
    /// left between the two.
    static func removeLeftovers(in directory: URL, olderThan age: TimeInterval = 60, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-age)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if (modified ?? .distantPast) < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
