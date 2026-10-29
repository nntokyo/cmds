import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
exit(CLI.main(Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment))
