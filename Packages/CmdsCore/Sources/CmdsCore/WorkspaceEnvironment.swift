import Foundation

/// A workspace's own environment variables (#174 G23), set in Workspace › Environment Variables… and given to the
/// terminals opened in it afterwards. Written one per line as `NAME=value`; a secret is never written down but named
/// as a Keychain item, `NAME=keychain:service` or `NAME=keychain:service/account` (a generic password), and read
/// when a terminal opens. Lines starting with `#` and blank lines are kept out.
///
/// ```
/// NODE_ENV=development
/// OPENAI_API_KEY=keychain:cmds.env/OPENAI_API_KEY
/// ```
public struct WorkspaceEnvironment: Equatable, Sendable {
    public static let maxEntries = 50
    public static let maxValueLength = 4096
    /// Set by cmds for every terminal (`CmdsEnv`); a workspace cannot change them.
    public static let reservedPrefix = "CMDS_"
    static let keychainPrefix = "keychain:"

    public enum Value: Equatable, Sendable {
        case plain(String)
        /// A generic password in the login Keychain: its service and, when given, account.
        case keychain(service: String, account: String?)
    }

    public struct Entry: Equatable, Sendable {
        public var name: String
        public var value: Value

        public init(name: String, value: Value) {
            self.name = name
            self.value = value
        }

        public var isSecret: Bool {
            if case .keychain = value { return true }
            return false
        }

        /// The line as written (a secret shows only where it is kept).
        public var line: String {
            switch value {
            case .plain(let text): return "\(name)=\(text)"
            case .keychain(let service, let account): return "\(name)=\(keychainPrefix)\(service)\(account.map { "/\($0)" } ?? "")"
            }
        }
    }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The lines to edit and save (`parse` reads them back).
    public var lines: [String] { entries.map(\.line) }

    /// Reads `NAME=value` lines; the last line wins for a name given twice.
    public static func parse(_ text: String) throws -> WorkspaceEnvironment {
        var entries: [Entry] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let number = index + 1
            guard let equals = line.firstIndex(of: "=") else {
                throw Invalid(description: "line \(number): write NAME=value")
            }
            var name = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("export ") { name = String(name.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard isValidName(name) else {
                throw Invalid(description: "line \(number): \"\(name)\" is not a variable name (letters, digits and _)")
            }
            guard !name.uppercased().hasPrefix(reservedPrefix) else {
                throw Invalid(description: "line \(number): \(name) is set by cmds")
            }
            let text = String(line[line.index(after: equals)...])
            guard text.count <= maxValueLength else {
                throw Invalid(description: "line \(number): the value is longer than \(maxValueLength) characters")
            }
            let value: Value
            if text.hasPrefix(keychainPrefix) {
                let reference = String(text.dropFirst(keychainPrefix.count))
                let parts = reference.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard let service = parts.first, !service.isEmpty, parts.count == 1 || !parts[1].isEmpty else {
                    throw Invalid(description: "line \(number): write keychain:service or keychain:service/account")
                }
                value = .keychain(service: service, account: parts.count == 2 ? parts[1] : nil)
            } else {
                value = .plain(text)
            }
            entries.removeAll { $0.name == name }
            entries.append(Entry(name: name, value: value))
        }
        guard entries.count <= maxEntries else { throw Invalid(description: "at most \(maxEntries) variables") }
        return WorkspaceEnvironment(entries: entries)
    }

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 128 else { return false }
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        let rest = letters.union(CharacterSet(charactersIn: "0123456789"))
        return letters.contains(first) && name.unicodeScalars.allSatisfy { rest.contains($0) }
    }

    /// The variables for a new terminal: plain values as written, secrets from `secret` (the Keychain). A secret
    /// that cannot be read is left out and named in `missing`.
    public func resolved(secret: (_ service: String, _ account: String?) -> String?) -> (variables: [String: String], missing: [String]) {
        var variables: [String: String] = [:]
        var missing: [String] = []
        for entry in entries {
            switch entry.value {
            case .plain(let text):
                variables[entry.name] = text
            case .keychain(let service, let account):
                if let value = secret(service, account) { variables[entry.name] = value } else { missing.append(entry.name) }
            }
        }
        return (variables, missing)
    }
}
