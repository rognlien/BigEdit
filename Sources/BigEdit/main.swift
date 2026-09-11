import AppKit

// Headless modes (see `HeadlessCommands`) run and exit; otherwise start the app.
if let exitCode = HeadlessCommands.exitCode(for: CommandLine.arguments) {
    exit(exitCode)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
