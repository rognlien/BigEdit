import AppKit

// Headless modes, for testing without the GUI:
//   swift run BigEdit --index <path>
//   swift run BigEdit --search <pattern> <path>
//   swift run BigEdit --search-regex <pattern> <path>
//   swift run BigEdit --preview <pattern> <replacement> <path>
//   swift run BigEdit --csv <path> [rows]
//   swift run BigEdit --process-lines <op> <in> <out> [pattern] [replacement]
let arguments = CommandLine.arguments
if let flagIndex = arguments.firstIndex(of: "--index"), flagIndex + 1 < arguments.count {
    exit(HeadlessIndexer.run(path: arguments[flagIndex + 1]))
}
if let flagIndex = arguments.firstIndex(of: "--search"), flagIndex + 2 < arguments.count {
    exit(HeadlessIndexer.search(pattern: arguments[flagIndex + 1], path: arguments[flagIndex + 2]))
}
if let flagIndex = arguments.firstIndex(of: "--search-regex"), flagIndex + 2 < arguments.count {
    let listAll = flagIndex + 3 < arguments.count && arguments[flagIndex + 3] == "all"
    exit(HeadlessIndexer.searchRegularExpression(pattern: arguments[flagIndex + 1],
                                                 path: arguments[flagIndex + 2],
                                                 listAll: listAll))
}
if let flagIndex = arguments.firstIndex(of: "--preview"), flagIndex + 3 < arguments.count {
    exit(HeadlessIndexer.preview(
        pattern: arguments[flagIndex + 1],
        replacement: arguments[flagIndex + 2],
        path: arguments[flagIndex + 3]
    ))
}
if let flagIndex = arguments.firstIndex(of: "--replace"), flagIndex + 4 < arguments.count {
    exit(HeadlessIndexer.replace(
        pattern: arguments[flagIndex + 1],
        replacement: arguments[flagIndex + 2],
        inputPath: arguments[flagIndex + 3],
        outputPath: arguments[flagIndex + 4]
    ))
}
if let flagIndex = arguments.firstIndex(of: "--stats"), flagIndex + 1 < arguments.count {
    exit(HeadlessIndexer.stats(path: arguments[flagIndex + 1]))
}
if let flagIndex = arguments.firstIndex(of: "--edit-smoke"), flagIndex + 2 < arguments.count {
    exit(HeadlessIndexer.editSmoke(
        inputPath: arguments[flagIndex + 1],
        outputPath: arguments[flagIndex + 2]
    ))
}

if let flagIndex = arguments.firstIndex(of: "--csv"), flagIndex + 1 < arguments.count {
    let rowArgument = flagIndex + 2 < arguments.count ? Int(arguments[flagIndex + 2]) : nil
    exit(HeadlessIndexer.csv(path: arguments[flagIndex + 1], rowLimit: rowArgument ?? 10))
}

if let flagIndex = arguments.firstIndex(of: "--process-lines"), flagIndex + 3 < arguments.count {
    let pattern = flagIndex + 4 < arguments.count ? arguments[flagIndex + 4] : nil
    let replacement = flagIndex + 5 < arguments.count ? arguments[flagIndex + 5] : nil
    exit(HeadlessIndexer.processLines(
        operation: arguments[flagIndex + 1],
        inputPath: arguments[flagIndex + 2],
        outputPath: arguments[flagIndex + 3],
        pattern: pattern,
        replacement: replacement
    ))
}

// GUI mode.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
