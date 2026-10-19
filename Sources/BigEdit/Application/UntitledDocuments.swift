import Foundation

/// Where untitled documents live until they are saved. BigEdit reads through
/// `mmap`, so each one is a real, initially empty placeholder file here, and
/// everything keyed by a path — the edit journal, the view state, session
/// restore, the file watcher — works on it unchanged.
final class UntitledDocuments {

    /// Application Support, unless a test points it somewhere temporary.
    static let shared = UntitledDocuments(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BigEdit/Untitled", isDirectory: true))

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// Creates a new empty placeholder, or returns nil if it cannot be written.
    func makePlaceholder() -> URL? {
        let url = directory.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default
        var result: URL?
        if (try? manager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
           manager.createFile(atPath: url.path, contents: Data()) {
            result = url
        }
        return result
    }

    /// Whether `url` is one of the placeholders.
    func contains(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
    }

    // MARK: - Naming

    /// "Untitled" for the first, then "Untitled 2", "Untitled 3", …
    static func name(numbered number: Int) -> String {
        number == 1 ? "Untitled" : "Untitled \(number)"
    }

    /// The lowest number the open untitled documents do not already use.
    static func lowestUnusedNumber(among used: [Int]) -> Int {
        var number = 1
        while used.contains(number) {
            number += 1
        }
        return number
    }
}
