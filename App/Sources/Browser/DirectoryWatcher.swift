import Foundation
import CoreServices

// The FSEvents plumbing behind a browser pane's reload on file changes (#252; the pane's side is
// BrowserPane+Watch.swift).

/// FSEvents on one folder tree (file-level events), delivered on the main queue as the changed items. `since`: replay
/// the history after that event first (changes made while nothing watched).
@MainActor
final class DirectoryWatcher {
    let folder: String
    private var stream: FSEventStreamRef?
    private let handler: ([Change]) -> Void

    /// A changed item; `isFolder`: the event is about a folder itself (its entries or metadata).
    struct Change {
        var path: String
        var isFolder: Bool
    }

    /// How long FSEvents gathers changes before it delivers them (the page's own debounce comes on top).
    static let latency: CFTimeInterval = 0.1

    init(folder: String, since: FSEventStreamEventId?, handler: @escaping ([Change]) -> Void) {
        self.folder = folder
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changed: [Change] = []
            for index in 0..<count {
                // The end-of-replay marker has no path to report.
                if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
                let isFolder = flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                if index < list.count { changed.append(Change(path: list[index], isFolder: isFolder)) }
            }
            MainActor.assumeIsolated { watcher.deliver(changed) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray,
                                               since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags)
        else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    private func deliver(_ changes: [Change]) {
        guard stream != nil, !changes.isEmpty else { return }
        handler(changes)
    }

    /// `path` with symlinks resolved as the file system reports it (`realpath`; Foundation's own resolving turns
    /// /private/tmp back into /tmp); `path` itself when it does not exist.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
