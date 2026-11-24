import Foundation

/// Files an agent gives a page (`browser.upload`, `cmds browser upload`, MCP browser_upload): what a person would choose
/// in a file dialog or drop on a drop zone, which a WebKit pane cannot be given otherwise. The caller reads them (the
/// CLI and the MCP server, with the agent's own rights), never the app, and sends their bytes.
public enum BrowserUpload {
    public struct File: Equatable, Sendable {
        public var name: String
        public var type: String
        public var data: Data

        public init(name: String, type: String, data: Data) {
            self.name = name
            self.type = type
            self.data = data
        }
    }

    public static let maxFiles = 10
    /// All files together (base64 makes the request about a third larger).
    public static let maxBytes = 20 * 1024 * 1024

    public struct Invalid: Error, CustomStringConvertible {
        public var description: String
        public init(description: String) { self.description = description }
    }

    /// The file at `path` (relative to the current folder): a regular file within the size limit, and not where secrets
    /// are kept (`refusal`, judged on the real path after symbolic links): a page could talk an agent into sending one.
    public static func read(path: String, home: String = NSHomeDirectory(), fileManager: FileManager = .default) throws -> File {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        if let reason = refusal(realPath: url.path, home: URL(fileURLWithPath: home).resolvingSymlinksInPath().path) {
            throw Invalid(description: "\(path) is not uploaded: \(reason)")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw Invalid(description: "no such file: \(path)") }
        guard !isDirectory.boolValue else { throw Invalid(description: "\(path) is a folder") }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxBytes else { throw Invalid(description: "\(path) is larger than \(maxBytes / 1024 / 1024) MB") }
        let data = try Data(contentsOf: url)
        return File(name: url.lastPathComponent, type: SyncFile.mimeType(forFileName: url.lastPathComponent), data: data)
    }

    /// Why a file must not be uploaded (nil: it may): under `~/.ssh`, `~/.aws`, `~/.config/gcloud`, `~/.gemini`,
    /// `~/.claude*`, `~/Library/Keychains`, inside a `.git` folder, or named `.env` / `.env.*`, `*credentials*`,
    /// `*.pem`, `*.key`, `id_*`. `realPath` and `home` are real paths (symbolic links resolved).
    public static func refusal(realPath: String, home: String) -> String? {
        let components = realPath.split(separator: "/").map(String.init)
        let name = components.last ?? ""
        let lower = name.lowercased()
        if components.dropLast().contains(".git") { return "it is inside a .git folder" }
        if lower == ".env" || lower.hasPrefix(".env.") { return "an .env file holds secrets" }
        if lower.contains("credentials") { return "a credentials file" }
        if lower.hasSuffix(".pem") || lower.hasSuffix(".key") || lower.hasPrefix("id_") { return "a key file" }
        let homeParts = home.split(separator: "/").map(String.init)
        guard components.count > homeParts.count, Array(components.prefix(homeParts.count)) == homeParts else { return nil }
        let inHome = Array(components.dropFirst(homeParts.count))
        let first = inHome.first ?? ""
        if [".ssh", ".aws", ".gemini"].contains(first) || first.hasPrefix(".claude") { return "~/\(first) holds keys or sign-ins" }
        if inHome.starts(with: [".config", "gcloud"]) { return "~/.config/gcloud holds sign-ins" }
        if inHome.starts(with: ["Library", "Keychains"]) { return "~/Library/Keychains holds the Keychain" }
        return nil
    }

    /// `files` of a request, checked: 1 to `maxFiles`, plain names, `maxBytes` in all.
    public static func files(params: JSONValue?) throws -> [File] {
        guard case .array(let items)? = params?["files"], !items.isEmpty else {
            throw RPCError.invalidParams("files must be a list of {name, type, data}")
        }
        guard items.count <= maxFiles else { throw RPCError.invalidParams("at most \(maxFiles) files") }
        var total = 0
        return try items.map { item in
            guard let name = item["name"]?.stringValue, !name.isEmpty, name.count <= 255, !name.contains("/"),
                  name != ".", name != ".." else { throw RPCError.invalidParams("each file needs a plain name") }
            guard let encoded = item["data"]?.stringValue, let data = Data(base64Encoded: encoded) else {
                throw RPCError.invalidParams("\(name): data must be base64")
            }
            total += data.count
            guard total <= maxBytes else { throw RPCError.invalidParams("the files are larger than \(maxBytes / 1024 / 1024) MB together") }
            let type = item["type"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? SyncFile.mimeType(forFileName: name)
            return File(name: name, type: type, data: data)
        }
    }

    public static func json(_ files: [File]) -> JSONValue {
        .array(files.map { ["name": .string($0.name), "type": .string($0.type), "data": .string($0.data.base64EncodedString())] })
    }
}
