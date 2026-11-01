import Foundation

/// How an account's `<configDir>/projects` (where Claude Code keeps its session transcripts) relates to the shared one.
public enum ClaudeProjectsLink: String, Codable, Sendable {
    /// It is the shared directory, or a symlink to it: sessions of the other accounts can be resumed here.
    case shared
    /// No `projects` yet: sharing creates the symlink.
    case missing
    /// A directory of its own: sharing moves it aside (renamed, never deleted) and creates the symlink.
    case separate
    /// A symlink (or file) pointing somewhere else: left alone; the user decides.
    case elsewhere
    /// The config directory does not exist (not signed in yet).
    case noConfigDir
}

/// Sharing session transcripts between accounts, so a session can be continued under another account.
///
/// Claude Code keeps each session in `<CLAUDE_CONFIG_DIR>/projects/<project>/<session-id>.jsonl` and
/// `claude --resume <id>` only looks in its own config directory. The first account (in the user's order) whose
/// config directory exists keeps its `projects` directory: the *store*. Every other account gets
/// `projects` → the store as a symlink. An account's own `projects` directory is renamed to
/// `projects.before-cmds-<date>` first; nothing is deleted, copied over or merged. Only done when the user asks
/// (Settings › Claude Accounts › Share Sessions…, `cmds accounts share --yes`).
public enum ClaudeSessionSharing {
    public struct Step: Equatable, Sendable {
        public enum Action: Equatable, Sendable {
            /// Already shared (or the store itself).
            case none
            case createLink
            /// Rename `projects` to `backupName`, then create the link.
            case moveAsideAndLink(backupName: String)
            /// Left alone (`elsewhere`, `noConfigDir`).
            case skip(reason: String)

            /// The `action` of a step in `account.share` (API and CLI).
            public enum Name: String, Sendable {
                case unchanged = "none", link, moveAside, skip
            }

            public var name: Name {
                switch self {
                case .none: return .unchanged
                case .createLink: return .link
                case .moveAsideAndLink: return .moveAside
                case .skip: return .skip
                }
            }
        }

        public var account: String
        public var projectsPath: String
        public var action: Action
    }

    public static func projectsPath(_ configDir: String, home: String = NSHomeDirectory()) -> String {
        (ClaudeAccounts.expandedPath(configDir, home: home) as NSString).appendingPathComponent("projects")
    }

    /// The store's real path: the first existing account's `projects` with symlinks resolved, so when that account's
    /// `projects` is already a link (the accounts were reordered after sharing), the folder it links to stays the store.
    /// `account`: the account whose own `projects` is that folder, else the first existing account.
    public static func store(_ accounts: [ClaudeAccount], fileManager: FileManager = .default,
                             home: String = NSHomeDirectory()) -> (account: String, path: String)? {
        let existing = accounts.filter { ClaudeAccounts.configDirExists($0, fileManager: fileManager, home: home) }
        guard let first = existing.first else { return nil }
        let path = resolvedProjectsPath(first.configDir, home: home)
        let owner = existing.first { account in
            let projects = projectsPath(account.configDir, home: home)
            return itemType(projects, fileManager: fileManager) == .typeDirectory
                && resolvedProjectsPath(account.configDir, home: home) == path
        }
        return ((owner ?? first).name, path)
    }

    static func resolvedProjectsPath(_ configDir: String, home: String) -> String {
        (projectsPath(configDir, home: home) as NSString).resolvingSymlinksInPath
    }

    /// The type of the item at `path` itself (a symlink is not followed); nil when there is none.
    private static func itemType(_ path: String, fileManager: FileManager) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
    }

    public static func link(of account: ClaudeAccount, in accounts: [ClaudeAccount], fileManager: FileManager = .default,
                            home: String = NSHomeDirectory()) -> ClaudeProjectsLink {
        guard ClaudeAccounts.configDirExists(account, fileManager: fileManager, home: home),
              let store = store(accounts, fileManager: fileManager, home: home) else { return .noConfigDir }
        if store.account == account.name { return .shared }
        let projects = projectsPath(account.configDir, home: home)
        // Not following a symlink tells a link from a directory, also a dangling link.
        guard let type = itemType(projects, fileManager: fileManager) else { return .missing }
        // The store itself, however it is reached, is never moved aside (it would be linked to itself).
        if (type == .typeSymbolicLink || type == .typeDirectory),
           resolvedProjectsPath(account.configDir, home: home) == store.path { return .shared }
        if type == .typeSymbolicLink { return .elsewhere }
        return type == .typeDirectory ? .separate : .elsewhere
    }

    /// What `apply` would do for each account, in order.
    public static func plan(_ accounts: [ClaudeAccount], now: Date = Date(), fileManager: FileManager = .default,
                            home: String = NSHomeDirectory()) -> [Step] {
        accounts.map { account in
            let projects = projectsPath(account.configDir, home: home)
            let action: Step.Action
            switch link(of: account, in: accounts, fileManager: fileManager, home: home) {
            case .shared: action = .none
            case .missing: action = .createLink
            case .separate: action = .moveAsideAndLink(backupName: backupName(for: projects, now: now, fileManager: fileManager))
            case .elsewhere: action = .skip(reason: "projects is a link or file pointing elsewhere; move it yourself to share")
            case .noConfigDir: action = .skip(reason: "the config directory does not exist; sign in with claude first")
            }
            return Step(account: account.name, projectsPath: projects, action: action)
        }
    }

    /// Carries out `plan`. Creates the store's `projects` directory if it does not exist yet. Never deletes or
    /// overwrites: a rename whose target exists, a link where something appeared meanwhile, or a step that would move
    /// the store itself aside fails that step; when the link cannot be made after a rename, the folder is moved back.
    /// Returns the accounts that were linked; throws on the first failure (earlier steps stay done).
    @discardableResult
    public static func apply(_ steps: [Step], accounts: [ClaudeAccount], fileManager: FileManager = .default,
                             home: String = NSHomeDirectory()) throws -> [String] {
        guard let store = store(accounts, fileManager: fileManager, home: home) else { return [] }
        try fileManager.createDirectory(atPath: store.path, withIntermediateDirectories: true)
        var linked: [String] = []
        for step in steps {
            switch step.action {
            case .none, .skip:
                continue
            case .moveAsideAndLink(let backupName):
                let backup = ((step.projectsPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(backupName)
                guard (step.projectsPath as NSString).resolvingSymlinksInPath != store.path else {
                    throw SharingError("\(step.projectsPath) is the shared folder itself")
                }
                guard !fileManager.fileExists(atPath: backup) else {
                    throw SharingError("\(backup) already exists")
                }
                try fileManager.moveItem(atPath: step.projectsPath, toPath: backup)
                do {
                    try fileManager.createSymbolicLink(atPath: step.projectsPath, withDestinationPath: store.path)
                } catch {
                    // Put the folder back where it was (a move never overwrites: if something took its place, the
                    // folder stays under the backup name and the error says so).
                    do {
                        try fileManager.moveItem(atPath: backup, toPath: step.projectsPath)
                    } catch let restoreError {
                        throw SharingError("could not link \(step.projectsPath) (\(error)); the folder stays at \(backup) "
                                           + "because moving it back failed: \(restoreError)")
                    }
                    throw error
                }
            case .createLink:
                try fileManager.createSymbolicLink(atPath: step.projectsPath, withDestinationPath: store.path)
            }
            linked.append(step.account)
        }
        return linked
    }

    /// `projects.before-cmds-20261102-1530` (with `-2`, `-3`… if taken).
    static func backupName(for projects: String, now: Date, fileManager: FileManager) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let base = "projects.before-cmds-\(formatter.string(from: now))"
        let parent = (projects as NSString).deletingLastPathComponent as NSString
        var name = base
        var counter = 2
        while fileManager.fileExists(atPath: parent.appendingPathComponent(name)) {
            name = "\(base)-\(counter)"
            counter += 1
        }
        return name
    }

    /// The session's transcript can be found from `configDir`: `<configDir>/projects/<any project>/<id>.jsonl`.
    /// Lists directory names only; nothing is read.
    public static func transcriptReachable(sessionID: String, configDir: String, fileManager: FileManager = .default,
                                           home: String = NSHomeDirectory()) -> Bool {
        guard AgentResume.isValidSessionID(sessionID) else { return false }
        let projects = projectsPath(configDir, home: home) as NSString
        guard let names = try? fileManager.contentsOfDirectory(atPath: projects as String) else { return false }
        return names.contains { name in
            fileManager.fileExists(atPath: (projects.appendingPathComponent(name) as NSString)
                .appendingPathComponent("\(sessionID).jsonl"))
        }
    }

    public struct SharingError: Error, CustomStringConvertible {
        public var description: String
        init(_ description: String) { self.description = description }
    }
}
