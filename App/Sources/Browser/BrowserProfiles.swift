import Foundation
import WebKit
import CmdsCore

/// The data stores of login profiles (`BrowserProfile`): one persistent `WKWebsiteDataStore` per name, whose identifier
/// is derived from the name (`BrowserProfile.identifier(for:)`), so a profile finds its sign-ins again after a relaunch
/// even if the list is lost. `browser-profiles.json` in cmds' support folder only lists the names created. Panes
/// without a profile use `WKWebsiteDataStore.default()`.
@MainActor
enum BrowserProfiles {
    static var fileURL: URL { CmdsEnv.supportDirectoryURL().appendingPathComponent("browser-profiles.json") }

    /// The names created, read once.
    private static var known: Set<String> = load()
    private static var stores: [String: WKWebsiteDataStore] = [:]

    static var names: [String] { known.sorted() }

    /// The data store of `name` (listed from then on), or the default one for nil.
    static func store(for name: String?) -> WKWebsiteDataStore {
        guard let name else { return .default() }
        if known.insert(name).inserted { save() }
        if let store = stores[name] { return store }
        let store = WKWebsiteDataStore(forIdentifier: BrowserProfile.identifier(for: name))
        stores[name] = store
        return store
    }

    /// Deletes `name`'s cookies and storage, then forgets it (the caller makes sure no pane uses it). When WebKit
    /// refuses (a web view of the profile is still alive), the profile stays listed and the error is thrown.
    static func remove(_ name: String) async throws {
        guard known.contains(name) else { throw RPCError.notFound("no profile named \"\(name)\"") }
        stores[name] = nil
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: BrowserProfile.identifier(for: name))
        } catch {
            throw RPCError(code: 500, message: "could not delete profile \"\(name)\" (\(error)); try again once its pages "
                           + "have closed")
        }
        known.remove(name)
        save()
    }

    private static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL), let raw = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(raw.compactMap { (try? BrowserProfile.validated($0)) ?? nil })
    }

    private static func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(names).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("cmds: could not save browser profiles: \(error)")
        }
    }
}
