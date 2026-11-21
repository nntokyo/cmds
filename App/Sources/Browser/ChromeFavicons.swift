import Foundation
import SQLite3
import CmdsCore

/// The icons Chrome keeps for pages (`<profile>/Favicons`, SQLite: `icon_mapping` page → icon, `favicon_bitmaps`), so
/// the bookmarks bar shows every bookmark's icon, not only those of sites visited in cmds (#376). Read only: the file
/// is copied (Chrome keeps it open and writes to it) and the copy opened read-only and immutable, then deleted.
enum ChromeFavicons {
    /// Larger databases are not copied.
    static let maxDatabaseBytes = 200 << 20
    /// Icons read at most (one per bookmark).
    static let maxIcons = 2_000

    /// PNG data of the icon closest to 32 px for each of `urls` that Chrome has one for.
    static func icons(profileFolder: URL, urls: [String]) -> [String: Data] {
        let source = profileFolder.appendingPathComponent("Favicons")
        guard !urls.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= maxDatabaseBytes else { return [:] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-favicons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("Favicons"))
        } catch {
            return [:]
        }
        var db: OpaquePointer?
        let uri = "file:" + folder.appendingPathComponent("Favicons").path + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
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
        var result: [String: Data] = [:]
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for url in urls.prefix(maxIcons) {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, url, -1, transient)
            sqlite3_bind_int(statement, 2, Int32(Favicon.maxBytes))
            guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { continue }
            result[url] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }
        return result
    }
}
