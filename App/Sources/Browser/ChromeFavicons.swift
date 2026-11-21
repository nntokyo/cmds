import Foundation
import SQLite3
import CmdsCore

/// The icons Chrome keeps for pages (`<profile>/Favicons`, SQLite: `icon_mapping` page → icon, `favicon_bitmaps`), so
/// the bookmarks bar shows every bookmark's icon, not only those of sites visited in cmds (#376). Read only: the file
/// is copied with its write-ahead log (Chrome keeps it open and writes to it) into a private temporary folder, read
/// there, then deleted; folders a crash left behind go at the next read.
enum ChromeFavicons {
    /// Larger databases are not copied.
    static let maxDatabaseBytes = 200 << 20
    /// Icons read at most (one per bookmark).
    static let maxIcons = 2_000
    /// One icon at most this big (a bookmark bar icon is small)…
    static let maxIconBytes = 64 << 10
    /// …and all together at most this much.
    static let maxTotalBytes = 32 << 20
    static let folderPrefix = "cmds-favicons-"

    /// Removes copies left by an earlier run that ended before deleting its own.
    static func removeLeftovers(olderThan age: TimeInterval = 600) {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix(folderPrefix) {
            let url = temp.appendingPathComponent(name)
            guard let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(date) > age else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// PNG data of the icon closest to 32 px for each of `urls` that Chrome has one for.
    static func icons(profileFolder: URL, urls: [String]) -> [String: Data] {
        let source = profileFolder.appendingPathComponent("Favicons")
        guard !urls.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= maxDatabaseBytes else { return [:] }
        removeLeftovers()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(folderPrefix + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("Favicons"))
            // Recent icons may still be in the log only.
            for suffix in ["-wal", "-journal"] {
                let extra = profileFolder.appendingPathComponent("Favicons" + suffix)
                if let attributes = try? FileManager.default.attributesOfItem(atPath: extra.path),
                   attributes[.type] as? FileAttributeType == .typeRegular,
                   ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= maxDatabaseBytes {
                    try? FileManager.default.copyItem(at: extra, to: folder.appendingPathComponent("Favicons" + suffix))
                }
            }
        } catch {
            return [:]
        }
        // The copy, not Chrome's file: opened so SQLite can read the log into it.
        var db: OpaquePointer?
        let uri = "file:" + folder.appendingPathComponent("Favicons").path
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url = ?1 AND length(b.image_data) <= ?2 ORDER BY abs(b.width - 32) LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [:] }
        defer { sqlite3_finalize(statement) }
        sqlite3_exec(db, "PRAGMA query_only = 1", nil, nil, nil)
        var result: [String: Data] = [:]
        var total = 0
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for url in urls.prefix(maxIcons) {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, url, -1, transient)
            sqlite3_bind_int(statement, 2, Int32(min(Favicon.maxBytes, maxIconBytes)))
            guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            total += count
            guard total <= maxTotalBytes else { break }
            result[url] = Data(bytes: bytes, count: count)
        }
        return result
    }
}
