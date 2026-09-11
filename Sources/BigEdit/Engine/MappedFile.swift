import Foundation

/// A read-only, memory-mapped view of a file.
///
/// `mmap` lets the operating system page in only the bytes that are actually
/// touched, so the cost of holding a file open is independent of its size.
/// This is the foundation of BigEdit: a 50 GB file and a 50 KB file are equally
/// cheap to keep mapped.
final class MappedFile {

    /// The path the file was opened from.
    let path: String

    /// The size of the file in bytes.
    let size: Int

    /// The file's inode, so a later look at the same path can tell an append
    /// (same inode, larger) from a replacement (a new inode, as an atomic save
    /// or a log rotation produces).
    let inode: UInt64

    private let descriptor: Int32
    private let base: UnsafeMutableRawPointer?

    /// Opens and maps the file at `path`, or returns `nil` if it cannot be read.
    init?(path: String) {
        let openedDescriptor = open(path, O_RDONLY)
        guard openedDescriptor >= 0 else {
            return nil
        }

        var fileInfo = stat()
        guard fstat(openedDescriptor, &fileInfo) == 0 else {
            close(openedDescriptor)
            return nil
        }

        let fileSize = Int(fileInfo.st_size)
        self.path = path
        self.descriptor = openedDescriptor
        self.size = fileSize
        self.inode = UInt64(fileInfo.st_ino)

        // An empty file cannot be mapped, but it is still a valid (empty) document.
        if fileSize == 0 {
            self.base = nil
            return
        }

        guard let mapped = mmap(nil, fileSize, PROT_READ, MAP_PRIVATE, openedDescriptor, 0),
              mapped != MAP_FAILED else {
            close(openedDescriptor)
            return nil
        }

        // The line indexer scans the whole file once, front to back.
        madvise(mapped, fileSize, MADV_SEQUENTIAL)
        self.base = mapped
    }

    /// A raw byte view over the entire mapped file.
    var buffer: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: base, count: size)
    }

    deinit {
        if let base {
            munmap(base, size)
        }
        close(descriptor)
    }
}
