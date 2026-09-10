import Foundation

/// What happened to a watched file on disk, as far as following it is
/// concerned.
///
/// A log grows by having bytes appended: same inode, larger size, and the
/// bytes that were already there untouched. Anything else — a smaller file, a
/// new inode from an atomic save or a rotation, or old bytes that differ — is
/// a replacement, and the only honest response to that is a full reload.
enum FileGrowth: Equatable {
    case unchanged
    case appended(newSize: Int)
    case replaced

    /// Classifies the file at `path` against the mapping `previous` was made
    /// from, without reading the file: size and inode come from `stat`.
    static func detect(path: String, previous: MappedFile) -> FileGrowth {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return .replaced
        }
        let size = Int(info.st_size)
        let inode = UInt64(info.st_ino)
        var result = FileGrowth.replaced
        if inode == previous.inode {
            if size == previous.size {
                result = .unchanged
            } else if size > previous.size {
                result = .appended(newSize: size)
            }
        }
        return result
    }

    /// How many bytes at the end of the old mapping are compared with the new
    /// one before an append is believed. A rewrite that kept the same inode
    /// and happened to grow would otherwise be taken for an append; checking
    /// the last few kilobytes catches that without reading the whole file.
    static let tailCheckLength = 64 * 1024

    /// Whether `grown` really is `previous` plus appended bytes: the same
    /// length of tail, read from both mappings, must be identical.
    static func isAppend(previous: MappedFile, grown: MappedFile) -> Bool {
        var result = false
        if grown.size > previous.size {
            let length = min(tailCheckLength, previous.size)
            let range = (previous.size - length)..<previous.size
            result = length == 0
                || previous.buffer[range].elementsEqual(grown.buffer[range])
        }
        return result
    }
}
