import Foundation

/// Failure that ends the CLI with a message and exit code.
struct CLIError: Error {
    enum Code: Int32 {
        /// The API returned an error (bad pane id, …).
        case failure = 1
        /// Bad command line.
        case usage = 2
        /// The app is not running / socket unreachable.
        case unavailable = 3
    }

    var message: String
    var code: Code

    static func usage(_ message: String) -> CLIError { CLIError(message: message, code: .usage) }
    static func failure(_ message: String) -> CLIError { CLIError(message: message, code: .failure) }
}

/// Parsed command line of one subcommand: `--opt value`, `--opt=value`, `--flag`, positionals and `-- rest…`.
struct Arguments {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    /// Everything after a bare `--` (nil when there was none).
    var rest: [String]?

    /// Options accepted by every command.
    static let globalFlags: Set<String> = ["json", "help"]
    static let globalOptions: Set<String> = ["socket"]

    /// - Parameters:
    ///   - valueOptions: long names taking a value (short aliases map via `aliases`).
    ///   - flagNames: long names without a value.
    init(_ args: [String], options valueOptions: Set<String> = [], flags flagNames: Set<String> = [],
         aliases: [Character: String] = [:]) throws {
        let valueOptions = valueOptions.union(Self.globalOptions)
        let flagNames = flagNames.union(Self.globalFlags)
        let aliases = aliases.merging(["h": "help"]) { current, _ in current }
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg == "--" {
                rest = Array(args[index...])
                break
            }
            var name: String
            var inlineValue: String?
            if arg.hasPrefix("--") {
                name = String(arg.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    inlineValue = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
            } else if arg.hasPrefix("-"), arg.count == 2, let alias = aliases[arg.last!] {
                name = alias
            } else if arg.hasPrefix("-"), arg.count > 1, Double(arg) == nil {
                throw CLIError.usage("unknown option: \(arg)")
            } else {
                positionals.append(arg)
                continue
            }
            if valueOptions.contains(name) {
                if let inlineValue {
                    options[name] = inlineValue
                } else {
                    guard index < args.count else { throw CLIError.usage("option --\(name) needs a value") }
                    options[name] = args[index]
                    index += 1
                }
            } else if flagNames.contains(name) {
                guard inlineValue == nil else { throw CLIError.usage("option --\(name) takes no value") }
                flags.insert(name)
            } else {
                throw CLIError.usage("unknown option: --\(name)")
            }
        }
    }

    subscript(option name: String) -> String? { options[name] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }

    func int(_ name: String) throws -> Int? {
        guard let raw = options[name] else { return nil }
        guard let value = Int(raw), value >= 0 else { throw CLIError.usage("--\(name) expects a non-negative number") }
        return value
    }

    func expectPositionals(_ range: ClosedRange<Int>, usage: String) throws {
        guard range.contains(positionals.count) else { throw CLIError.usage("usage: \(usage)") }
    }
}

/// Joins argv-style words into one shell command line (single words are passed through verbatim).
func shellCommand(_ words: [String]) -> String? {
    guard !words.isEmpty else { return nil }
    if words.count == 1 { return words[0] }
    return words.map(shellQuote).joined(separator: " ")
}

func shellQuote(_ word: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
    if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
