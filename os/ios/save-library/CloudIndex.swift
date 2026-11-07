import Foundation
import SQLite3

/// Rebuildable local cache. The JSON records in Drive are the portable source of truth.
final class CloudIndex {
    struct RemoteFile {
        let id: String
        let name: String
        let parent: String?
        let modified: String?
    }

    private var db: OpaquePointer?

    init(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(db, 5000)
        try run("PRAGMA journal_mode=WAL")
        try run("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try run("CREATE TABLE IF NOT EXISTS files (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent TEXT, modified TEXT)")
        try run("CREATE INDEX IF NOT EXISTS files_parent_name ON files(parent, name)")
        try run("CREATE TABLE IF NOT EXISTS objects (digest TEXT PRIMARY KEY, file_id TEXT NOT NULL)")
        try run("CREATE TABLE IF NOT EXISTS records (record_id TEXT PRIMARY KEY, character_id TEXT NOT NULL, digest TEXT NOT NULL, file_id TEXT NOT NULL, json TEXT NOT NULL)")
        try run("CREATE INDEX IF NOT EXISTS records_character ON records(character_id)")
        try run("CREATE TABLE IF NOT EXISTS tombstones (character_id TEXT NOT NULL, digest TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY(character_id,digest))")
        try run("CREATE TABLE IF NOT EXISTS local_files (path TEXT PRIMARY KEY, modified TEXT NOT NULL, size TEXT NOT NULL, digest TEXT NOT NULL)")
    }

    deinit { sqlite3_close(db) }

    private func failure() -> NSError {
        NSError(domain: "CloudIndex", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }

    private func run(_ sql: String, _ values: [String?] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            if let value {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            } else { sqlite3_bind_null(statement, Int32(index + 1)) }
        }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw failure() }
    }

    private func query(_ sql: String, _ values: [String?] = []) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            if let value {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            } else { sqlite3_bind_null(statement, Int32(index + 1)) }
        }
        var rows: [[String?]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return rows
    }

    func state(_ key: String) throws -> String? {
        try query("SELECT value FROM state WHERE key=?", [key]).first?.first ?? nil
    }

    func setState(_ key: String, _ value: String?) throws {
        if let value {
            try run("INSERT OR REPLACE INTO state(key,value) VALUES(?,?)", [key, value])
        } else { try run("DELETE FROM state WHERE key=?", [key]) }
    }

    func resetRemoteCache() throws {
        try run("DELETE FROM files")
        try run("DELETE FROM objects")
        try run("DELETE FROM records")
        try run("DELETE FROM tombstones")
        try run("DELETE FROM state WHERE key IN ('driveRootID','changeToken') OR key LIKE 'head:%'")
    }

    func upsert(_ file: RemoteFile) throws {
        try run("INSERT OR REPLACE INTO files(id,name,parent,modified) VALUES(?,?,?,?)",
                [file.id, file.name, file.parent, file.modified])
    }

    func removeFile(_ id: String) throws {
        try run("DELETE FROM files WHERE id=?", [id])
        try run("DELETE FROM objects WHERE file_id=?", [id])
        try run("DELETE FROM records WHERE file_id=?", [id])
    }

    func file(named name: String, in parent: String) throws -> RemoteFile? {
        guard let row = try query("SELECT id,name,parent,modified FROM files WHERE parent=? AND name=? LIMIT 1",
                                  [parent, name]).first else { return nil }
        return RemoteFile(id: row[0]!, name: row[1]!, parent: row[2], modified: row[3])
    }

    func files(in parent: String, suffix: String) throws -> [RemoteFile] {
        try query("SELECT id,name,parent,modified FROM files WHERE parent=? AND name LIKE ?",
                  [parent, "%" + suffix]).map {
            RemoteFile(id: $0[0]!, name: $0[1]!, parent: $0[2], modified: $0[3])
        }
    }

    func objectID(for digest: String) throws -> String? {
        try query("SELECT file_id FROM objects WHERE digest=?", [digest]).first?.first ?? nil
    }

    func setObject(_ digest: String, id: String) throws {
        try run("INSERT OR REPLACE INTO objects(digest,file_id) VALUES(?,?)", [digest, id])
    }

    func record(_ record: CloudSavePoint, fileID: String) throws {
        let json = String(data: try CloudCoding.encoder().encode(record), encoding: .utf8)!
        try run("INSERT OR REPLACE INTO records(record_id,character_id,digest,file_id,json) VALUES(?,?,?,?,?)",
                [record.id, record.characterID, record.digest, fileID, json])
    }

    func hasRecord(_ id: String) throws -> Bool {
        !(try query("SELECT record_id FROM records WHERE record_id=?", [id])).isEmpty
    }

    func records() throws -> [CloudSavePoint] {
        try query("SELECT r.json FROM records r LEFT JOIN tombstones t ON r.character_id=t.character_id AND r.digest=t.digest WHERE t.digest IS NULL").compactMap {
            guard let json = $0[0] else { return nil }
            return try? CloudCoding.decoder().decode(CloudSavePoint.self, from: Data(json.utf8))
        }
    }

    func tombstones() throws -> [CloudTombstone] {
        try query("SELECT json FROM tombstones").compactMap {
            guard let json = $0[0] else { return nil }
            return try? CloudCoding.decoder().decode(CloudTombstone.self, from: Data(json.utf8))
        }
    }

    func hasTombstone(characterID: String, digest: String) throws -> Bool {
        !(try query("SELECT digest FROM tombstones WHERE character_id=? AND digest=?",
                    [characterID, digest])).isEmpty
    }

    func tombstone(_ value: CloudTombstone) throws {
        let json = String(data: try CloudCoding.encoder().encode(value), encoding: .utf8)!
        try run("INSERT OR REPLACE INTO tombstones(character_id,digest,json) VALUES(?,?,?)",
                [value.characterID, value.digest, json])
    }

    func digest(of file: URL) throws -> String {
        let values = try FileManager.default.attributesOfItem(atPath: file.path)
        let modified = String((values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let size = String((values[.size] as? NSNumber)?.uint64Value ?? 0)
        let path = file.standardizedFileURL.path
        if let row = try query("SELECT modified,size,digest FROM local_files WHERE path=?", [path]).first,
           row[0] == modified, row[1] == size, let digest = row[2] { return digest }
        let digest = CloudIdentity.digest(try Data(contentsOf: file))
        try run("INSERT OR REPLACE INTO local_files(path,modified,size,digest) VALUES(?,?,?,?)",
                [path, modified, size, digest])
        return digest
    }
}
