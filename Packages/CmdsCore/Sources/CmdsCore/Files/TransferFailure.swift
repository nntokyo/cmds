import Foundation

/// Why an item of a transfer, a whole transfer or a server's Trash failed. `description` is English (socket API, CLI,
/// logs); the app shows its own text for each case, so its UI is not English except for what a server or ssh said.
public indirect enum TransferFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case noSuchItem
    /// A folder into itself (or into a folder inside it).
    case intoItself
    /// Replacing would trash the folder the item comes from.
    case replaceContainsSource
    /// Replace: the existing item could not go to the Trash, so nothing was replaced.
    case existingNotTrashed(TransferFailure)
    /// The name was taken while the file was copied; the copy was not renamed into place.
    case appeared(name: String, TransferFailure)
    /// The server's Trash, or a folder containing it, cannot go to the Trash.
    case trashItself
    case alreadyInTrash
    /// A folder of the server's Trash is something else.
    case trashNotAFolder(String)
    /// Moving into the server's Trash failed (e.g. another file system); nothing was deleted.
    case serverTrashFailed(name: String, TransferFailure)
    case sftp(SFTPError)
    case connect(SSHFailure)
    /// A system call on this Mac failed with `code` (`errno`) on the item `name`.
    case posix(code: Int32, name: String)
    /// A Cocoa error (e.g. the Mac's Trash): English text as before, and the system's localized text.
    case system(String, localized: String)
    case other(String)

    public init(_ error: Error) {
        switch error {
        case let failure as TransferFailure: self = failure
        case let error as SFTPError: self = .sftp(error)
        case let error as SSHConnectError: self = .connect(error.failure)
        case let error as FileTreeError: self = .other(error.description)
        default:
            let ns = error as NSError
            if [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain].contains(ns.domain) {
                self = .system("\(error)", localized: ns.localizedDescription)
            } else {
                self = .other("\(error)")
            }
        }
    }

    public var description: String {
        switch self {
        case .noSuchItem: return "No such file or folder"
        case .intoItself: return "A folder cannot be copied or moved into itself."
        case .replaceContainsSource: return "The item to replace contains the item being moved."
        case .existingNotTrashed(let reason): return "The existing item could not be moved to the Trash: \(reason)"
        case .appeared(let name, let reason):
            return "“\(name)” appeared in the destination during the copy; it was left as it is (\(reason))"
        case .trashItself: return "The Trash itself, or a folder containing it, cannot be moved to the Trash."
        case .alreadyInTrash: return "This item is already in the Trash."
        case .trashNotAFolder(let path): return "\(path) is not a folder"
        case .serverTrashFailed(let name, let reason):
            return "Could not move “\(name)” to the server's Trash (\(reason)). Nothing was deleted."
        case .sftp(let error): return error.description
        case .connect(let failure): return failure.description
        case .posix(let code, let name): return "\(String(cString: strerror(code))) (\(name))"
        case .system(let text, _), .other(let text): return text
        }
    }
}
