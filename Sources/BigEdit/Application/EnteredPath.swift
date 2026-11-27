import Foundation

/// A path typed or pasted into Open Path, turned into a file URL: quotes
/// and whitespace around it are dropped, spaces escaped as in Terminal are
/// unescaped, `~` is expanded, a `file://` URL is taken as it is, and a
/// relative path is resolved against `base`.
enum EnteredPath {

    static func url(from text: String, relativeTo base: URL) -> URL? {
        let path = unquoted(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var result: URL?
        if path.hasPrefix("file://") {
            result = URL(string: path)
        } else if !path.isEmpty {
            let unescaped = path.replacingOccurrences(of: "\\ ", with: " ")
            let expanded = (unescaped as NSString).expandingTildeInPath
            let folder = URL(fileURLWithPath: base.path, isDirectory: true)
            result = URL(fileURLWithPath: expanded, relativeTo: folder).standardizedFileURL
        }
        return result
    }

    private static func unquoted(_ text: String) -> String {
        var result = text
        for quote in ["\"", "'"] where result.count >= 2
            && result.hasPrefix(quote) && result.hasSuffix(quote) {
            result = String(result.dropFirst().dropLast())
        }
        return result
    }
}
