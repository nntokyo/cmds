import CmdsCore
import Foundation

// A `cmds` found on PATH in a terminal of another copy of the app runs that app's own CLI (CLIHandoff).
if let target = CLIHandoff.target(environment: ProcessInfo.processInfo.environment, ownPath: CLIHandoff.executablePath()) {
    CLIHandoff.run(target, arguments: Array(CommandLine.arguments.dropFirst()))
}
setvbuf(stdout, nil, _IOLBF, 0)
exit(CLI.main(Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment))
