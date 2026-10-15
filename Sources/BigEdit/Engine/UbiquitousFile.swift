import Foundation

/// Files in iCloud Drive that are not on this Mac yet.
///
/// iCloud Drive is a folder, so its files open like any other — except an
/// evicted one, which exists only as a `.name.icloud` placeholder with no
/// bytes behind it. Mapping that would show an empty document, so the
/// placeholder is recognised, the download asked for, and the real file
/// opened once it has arrived. None of this needs an entitlement: it is
/// the same file-provider machinery Finder uses.
enum UbiquitousFile {

    /// The file a `.name.icloud` placeholder stands for; any other URL is
    /// returned as it is.
    static func resolvedURL(for url: URL) -> URL {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else {
            return url
        }
        let realName = String(name.dropFirst().dropLast(".icloud".count))
        return url.deletingLastPathComponent().appendingPathComponent(realName)
    }

    /// Whether `url` is an iCloud item whose bytes are not on this Mac.
    static func needsDownload(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                              .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else {
            return false
        }
        return values.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    /// Whether the download of `url` has finished, so the file can be mapped.
    static func isDownloaded(_ url: URL) -> Bool {
        !needsDownload(url) && FileManager.default.fileExists(atPath: url.path)
    }

    /// Asks the system to fetch `url`. Returns at once; poll `isDownloaded`.
    static func startDownload(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Whether the user's iCloud Drive folder exists on this Mac — that is,
    /// iCloud Drive is turned on. `home` is a parameter so tests can point
    /// it at a folder of their own.
    static func iCloudDriveURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: drive.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return drive
        }
        return nil
    }
}
