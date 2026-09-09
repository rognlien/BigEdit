import Foundation

/// The `bigedit` command line tool.
///
/// It resolves the paths named on the command line, creates any file that does
/// not exist yet, and hands the lot to the BigEdit application. The logic lives
/// in a library rather than in the executable so it can be tested without
/// launching anything.
public enum CommandLineTool {

    /// What the arguments asked for.
    enum Command: Equatable {
        case showHelp
        case showVersion
        case open(paths: [String])
    }

    /// Anything that stops the tool before it reaches the application.
    enum Failure: Error, Equatable {
        case unreadableOption(String)
        case cannotCreate(path: String)
        case isDirectory(path: String)
        case applicationNotFound
    }

    public static let usage = """
        usage: bigedit [file ...]

        Opens each file in BigEdit, creating it if it does not exist.
        With no arguments, brings BigEdit to the front.

          -h, --help       show this message
          -v, --version    show the tool's version
        """

    // MARK: - Entry point

    /// Runs the tool and returns the process exit status. `executablePath` is
    /// the tool's own location, used to find the surrounding application.
    public static func run(arguments: [String], executablePath: String) -> Int32 {
        var status: Int32 = 0
        do {
            switch try parse(arguments) {
            case .showHelp:
                print(usage)
            case .showVersion:
                print("bigedit \(toolVersion)")
            case .open(let paths):
                let files = try paths.map { try prepareFile(at: $0) }
                let application = try applicationURL(forExecutableAt: executablePath)
                status = launch(application: application, files: files)
            }
        } catch {
            FileHandle.standardError.write(Data("bigedit: \(message(for: error))\n".utf8))
            status = 1
        }
        return status
    }

    /// The tool's version, kept in step with the app it ships inside.
    static let toolVersion = "1.0"

    // MARK: - Arguments

    static func parse(_ arguments: [String]) throws -> Command {
        var command = Command.open(paths: [])
        var paths: [String] = []
        var sawTerminator = false

        for argument in arguments {
            if sawTerminator {
                paths.append(argument)
            } else if argument == "--" {
                sawTerminator = true          // everything after is a filename
            } else if argument == "-h" || argument == "--help" {
                return .showHelp
            } else if argument == "-v" || argument == "--version" {
                return .showVersion
            } else if argument.hasPrefix("-") && argument != "-" {
                throw Failure.unreadableOption(argument)
            } else {
                paths.append(argument)
            }
        }
        command = .open(paths: paths)
        return command
    }

    // MARK: - Files

    /// The absolute URL for `path`, creating an empty file if nothing is there.
    static func prepareFile(at path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let manager = FileManager.default

        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                throw Failure.isDirectory(path: url.path)
            }
        } else if !manager.createFile(atPath: url.path, contents: Data()) {
            // Most often the parent directory does not exist; createFile does
            // not say which, so the message names the file either way.
            throw Failure.cannotCreate(path: url.path)
        }
        return url
    }

    // MARK: - The application

    /// The `.app` the tool is bundled inside, found by walking up from its own
    /// location. Symlinks are resolved first, so an install on the PATH still
    /// finds the bundle it points into.
    static func applicationURL(forExecutableAt executablePath: String) throws -> URL? {
        var result: URL?
        let executable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        // <App>.app/Contents/MacOS/bigedit → up three to the bundle.
        let candidate = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if candidate.pathExtension == "app",
           FileManager.default.fileExists(atPath: candidate.path) {
            result = candidate
        }
        return result
    }

    /// Hands the files to BigEdit via `open`. A `nil` application means the
    /// tool is not inside a bundle (a development build), so it falls back to
    /// finding BigEdit by name.
    private static func launch(application: URL?, files: [URL]) -> Int32 {
        var arguments: [String] = []
        if let application {
            arguments += ["-a", application.path]
        } else {
            arguments += ["-a", "BigEdit"]
        }
        arguments += files.map(\.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments

        var status: Int32 = 0
        do {
            try process.run()
            process.waitUntilExit()
            status = process.terminationStatus
        } catch {
            FileHandle.standardError.write(Data("bigedit: could not run open\n".utf8))
            status = 1
        }
        return status
    }

    // MARK: - Messages

    static func message(for error: Error) -> String {
        var text = "\(error)"
        if let failure = error as? Failure {
            switch failure {
            case .unreadableOption(let option):
                text = "unknown option '\(option)'\n\(usage)"
            case .cannotCreate(let path):
                text = "cannot create '\(path)' — is the folder missing or read-only?"
            case .isDirectory(let path):
                text = "'\(path)' is a folder, not a file"
            case .applicationNotFound:
                text = "could not find BigEdit"
            }
        }
        return text
    }
}
