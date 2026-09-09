import BigEditCLI
import Foundation

// The tool's own path is what locates the surrounding .app, so pass the real
// executable location rather than argv[0], which is only the name typed.
let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
exit(CommandLineTool.run(arguments: Array(CommandLine.arguments.dropFirst()),
                         executablePath: executablePath))
