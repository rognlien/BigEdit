import Foundation

/// What makes two paths the same file: its device and inode. A symbolic link,
/// a hard link, or a path that differs only in case all lead to the same one.
struct FileIdentity: Equatable {

    let device: UInt64
    let inode: UInt64

    /// The identity of the file at `url`, or nil when it cannot be read.
    init?(url: URL) {
        var fileInfo = stat()
        guard stat(url.path, &fileInfo) == 0 else {
            return nil
        }
        device = UInt64(fileInfo.st_dev)
        inode = UInt64(fileInfo.st_ino)
    }

    /// The position of the first of `urls` that is the same file as `url`.
    static func firstIndex(of url: URL, in urls: [URL]) -> Int? {
        let identity = FileIdentity(url: url)
        return identity.flatMap { identity in
            urls.firstIndex { FileIdentity(url: $0) == identity }
        }
    }
}
