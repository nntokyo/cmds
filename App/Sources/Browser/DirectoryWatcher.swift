import Foundation
import CoreServices

// The FSEvents plumbing behind a browser pane's reload on file changes (#252; the pane's side is
// BrowserPane+Watch.swift).

/// FSEvents on one folder tree (file-level events), delivered on the main queue as the changed items. `since`: replay
/// the history after that event first (changes made while nothing watched). Nil when FSEvents cannot start. Stops when
/// stopped or released.
@MainActor
final class DirectoryWatcher {
    let folder: String
    private var stream: Stream?
    private let handler: ([Change]) -> Void
    private let rootChanged: () -> Void

    /// A changed item; `isFolder`: the event is about a folder itself (its entries or metadata).
    struct Change {
        var path: String
        var isFolder: Bool
    }

    /// How long FSEvents gathers changes before it delivers them (the page's own debounce comes on top).
    static let latency: CFTimeInterval = 0.1

    /// `rootChanged`: the folder itself was removed, moved or created again (FSEvents watches the path, so changes in
    /// a folder created again there are delivered too).
    init?(folder: String, since: FSEventStreamEventId?, handler: @escaping ([Change]) -> Void,
          rootChanged: @escaping () -> Void) {
        self.folder = folder
        self.handler = handler
        self.rootChanged = rootChanged
        // The stream holds the target (retained through the context), the target only a weak reference to the
        // watcher: a watcher released without `stop` is never called back after it is gone.
        let target = Target()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(target).toOpaque(),
                                           retain: { info in
                                               guard let info else { return nil }
                                               _ = Unmanaged<Target>.fromOpaque(info).retain()
                                               return info
                                           },
                                           release: { info in
                                               guard let info else { return }
                                               Unmanaged<Target>.fromOpaque(info).release()
                                           },
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let target = Unmanaged<Target>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changed: [Change] = []
            var rootChanged = false
            for index in 0..<count {
                // The end-of-replay marker has no path to report.
                if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
                if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                    rootChanged = true
                    continue
                }
                let isFolder = flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                if index < list.count { changed.append(Change(path: list[index], isFolder: isFolder)) }
            }
            MainActor.assumeIsolated { target.watcher?.deliver(changed, rootChanged: rootChanged) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let ref = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray,
                                            since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags)
        else { return nil }
        let stream = Stream(ref)
        FSEventStreamSetDispatchQueue(ref, .main)
        guard FSEventStreamStart(ref) else { return nil }  // `stream` invalidates and releases it
        stream.started = true
        self.stream = stream
        target.watcher = self
    }

    private func deliver(_ changes: [Change], rootChanged: Bool) {
        guard stream != nil else { return }
        if rootChanged { self.rootChanged() }
        if !changes.isEmpty { handler(changes) }
    }

    /// `path` with symlinks resolved as the file system reports it (`realpath`; Foundation's own resolving turns
    /// /private/tmp back into /tmp); `path` itself when it does not exist.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func stop() {
        stream = nil  // stops it
    }

    /// What the stream calls back (it retains this, not the watcher).
    private final class Target {
        weak var watcher: DirectoryWatcher?
    }

    /// Owns an FSEvents stream: stopped (once started), invalidated and released when this goes.
    private final class Stream {
        let ref: FSEventStreamRef
        var started = false

        init(_ ref: FSEventStreamRef) { self.ref = ref }

        deinit {
            if started { FSEventStreamStop(ref) }
            FSEventStreamInvalidate(ref)
            FSEventStreamRelease(ref)
        }
    }
}
