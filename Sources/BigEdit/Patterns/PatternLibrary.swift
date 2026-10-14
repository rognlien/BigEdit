import Foundation

/// A find pattern kept for later: what to look for, what to replace it
/// with, and how to match.
struct SavedPattern: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var pattern: String
    var replacement: String
    var isRegularExpression: Bool
    var isCaseSensitive: Bool
    /// A line about what the pattern is for, shown in the manage window.
    var note: String

    init(id: UUID = UUID(), name: String, pattern: String, replacement: String = "",
         isRegularExpression: Bool = true, isCaseSensitive: Bool = true, note: String = "") {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.isRegularExpression = isRegularExpression
        self.isCaseSensitive = isCaseSensitive
        self.note = note
    }
}

/// The saved patterns, kept as one JSON file so it is readable, portable
/// between Macs, and syncable by copying the file.
///
/// The file is read when the library is created and after `reload()`, and
/// written after every change. Every change posts `didChangeNotification`
/// on the main queue so the menus that list the patterns can rebuild.
final class PatternLibrary {

    static let didChangeNotification = Notification.Name("BigEditPatternLibraryDidChange")

    /// The file name, wherever the library lives.
    static let fileName = "Saved Patterns.json"

    /// The library every find bar and sheet shares.
    static let shared = PatternLibrary(fileURL: defaultFileURL())

    /// Where the library lives by default: the app's Application Support
    /// folder.
    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BigEdit", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private(set) var fileURL: URL
    private(set) var patterns: [SavedPattern] = []

    /// The modification date of the file as last read or written, so a
    /// reload can tell whether anything changed underneath.
    private var loadedModificationDate: Date?

    init(fileURL: URL) {
        self.fileURL = fileURL
        reload()
    }

    // MARK: - Reading and writing

    /// Re-reads the file. A missing file is an empty library; a file that
    /// does not parse is left alone and reported as empty rather than
    /// overwritten, so a stray edit cannot wipe the collection.
    func reload() {
        patterns = PatternLibrary.read(from: fileURL) ?? []
        loadedModificationDate = PatternLibrary.modificationDate(of: fileURL)
        notify()
    }

    /// Re-reads the file only when its modification date moved on, which is
    /// what another Mac writing through iCloud Drive looks like.
    func reloadIfChangedOnDisk() {
        if PatternLibrary.modificationDate(of: fileURL) != loadedModificationDate {
            reload()
        }
    }

    /// Moves the library to `url`: the file is written there and, when
    /// that succeeds, the old file removed. A file already at `url` wins and
    /// is loaded instead, so switching to a location another Mac filled in
    /// does not overwrite it.
    func relocate(to url: URL) throws {
        if url == fileURL {
            return
        }
        let old = fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            fileURL = url
            reload()
        } else {
            fileURL = url
            try write()
            try? FileManager.default.removeItem(at: old)
            notify()
        }
    }

    private static func read(from url: URL) -> [SavedPattern]? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode([SavedPattern].self, from: data)
    }

    private static func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    private func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(patterns)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        loadedModificationDate = PatternLibrary.modificationDate(of: fileURL)
    }

    private func notify() {
        let post = {
            NotificationCenter.default.post(name: PatternLibrary.didChangeNotification, object: self)
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    // MARK: - Changes

    /// Adds `pattern` at the end. Errors writing the file are reported but
    /// the pattern stays in the in-memory list for the session.
    @discardableResult
    func add(_ pattern: SavedPattern) -> Error? {
        patterns.append(pattern)
        return commit()
    }

    /// Replaces the pattern with `pattern`'s id, if there is one.
    @discardableResult
    func update(_ pattern: SavedPattern) -> Error? {
        guard let index = patterns.firstIndex(where: { $0.id == pattern.id }) else {
            return nil
        }
        patterns[index] = pattern
        return commit()
    }

    @discardableResult
    func remove(id: UUID) -> Error? {
        patterns.removeAll { $0.id == id }
        return commit()
    }

    /// Moves the pattern at `source` so it sits at `destination`.
    @discardableResult
    func move(from source: Int, to destination: Int) -> Error? {
        guard patterns.indices.contains(source), patterns.indices.contains(destination) else {
            return nil
        }
        let pattern = patterns.remove(at: source)
        patterns.insert(pattern, at: destination)
        return commit()
    }

    private func commit() -> Error? {
        var failure: Error?
        do {
            try write()
        } catch {
            failure = error
        }
        notify()
        return failure
    }

    /// A name no saved pattern uses yet, for a new one: the pattern text
    /// itself, cut short, with a counter when that is taken.
    func suggestedName(for pattern: String) -> String {
        let base = pattern.count > 32 ? String(pattern.prefix(32)) + "…" : pattern
        var candidate = base.isEmpty ? "Pattern" : base
        var counter = 2
        while patterns.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }
}
