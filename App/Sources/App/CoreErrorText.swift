import CmdsCore
import Foundation

// UI text for CmdsCore errors whose `description` stays English for the socket API and the CLI
// (docs/internals/localization.md).

extension SSHLaunch.InvalidInput {
    var localizedText: String {
        switch reason {
        case .hostEmpty: return String(localized: "Enter a host.")
        case .hostStartsWithDash: return String(localized: "The host must not start with “-”.")
        case .hostTooLong: return String(localized: "The host is too long.")
        case .hostCharacters:
            let characters = ". _ - @ : [ ] % / +" // interpolated: a literal % in a catalog key reads as a format
            return String(localized: "The host may only contain letters, digits and \(characters)")
        case .directoryTooLong: return String(localized: "The remote directory is too long.")
        case .directoryCharacters:
            return String(localized: "The remote directory must not contain quotes, backslashes or control characters.")
        case .directoryNotAbsolute: return String(localized: "The remote directory must be an absolute path or start with ~/.")
        }
    }
}

extension LidSleepError {
    var localizedText: String {
        switch self {
        case .unavailable: return String(localized: "Not available in an isolated instance (CMDS_SUPPORT_DIR).")
        case .alreadyDisabledOutsideCmds: return String(localized: "Sleep is already disabled system-wide by something other than cmds.")
        case .cancelled: return String(localized: "Cancelled.")
        case .failed(let message): return message
        }
    }
}

extension WorktreeError {
    var localizedText: String {
        switch self {
        case .gitMissing: return String(localized: "git is not installed. Install the Xcode Command Line Tools.")
        case .notARepository(let path): return String(localized: "\(path) is not in a git repository.")
        case .bareRepository(let path): return String(localized: "\(path) is a bare repository, without a working tree to start from.")
        case .invalidBranch(let name): return String(localized: "“\(name)” is not a valid branch name.")
        case .branchExists(let name): return String(localized: "A branch named “\(name)” already exists (locally or on the remote).")
        case .pathNotAbsolute(let path): return String(localized: "The location must be an absolute path: \(path)")
        case .pathExists(let path): return String(localized: "\(path) already exists.")
        case .pathInsideRepository(let path): return String(localized: "\(path) is inside the repository. Choose a folder outside it.")
        case .unknownBase(let name): return String(localized: "There is no branch or commit named “\(name)”.")
        case .noDefaultBranch: return String(localized: "Cannot tell the repository's default branch. Enter a base.")
        case .notCreatedByCmds(let path): return String(localized: "cmds did not create the worktree \(path), so it never removes it.")
        case .inUse(let path): return String(localized: "Another workspace is in the worktree \(path).")
        case .refused(let refusals): return refusals.map(\.localizedText).joined(separator: "\n")
        case .gitFailed(let command, let message): return String(localized: "\(command) failed: \(message)")
        }
    }
}

extension WorktreeRefusal {
    var localizedText: String {
        switch self {
        case .notAWorktree: return String(localized: "It is no longer a worktree of its repository.")
        case .locked: return String(localized: "It is locked (git worktree lock).")
        case .uncommittedChanges(let count): return String(localized: "Uncommitted changes: \(count)")
        case .untrackedFiles(let count): return String(localized: "Untracked files: \(count)")
        case .unpushedCommits(let count): return String(localized: "Commits not pushed: \(count)")
        }
    }
}

/// UI text for any error of the worktree actions.
func worktreeErrorText(_ error: Error) -> String {
    (error as? WorktreeError)?.localizedText ?? (error as? RPCError)?.message ?? error.localizedDescription
}
