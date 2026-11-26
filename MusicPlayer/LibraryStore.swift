import Foundation
import SQLite3

struct SavedLibrary: Codable {
    var version = 1
    var tracks: [SavedTrack] = []
    var queueIDs: [UUID] = []
    var currentID: UUID?
    var position: Double = 0
    var shuffle = false
    var repeatMode = "off"
}

struct StorageError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

// A versioned snapshot in SQLite. Each write is a single atomic statement.
// The store is confined to the main actor; connections are short-lived.
@MainActor
final class LibraryStore {
    private let url: URL

    init() throws {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MusicPlayer", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("library.sqlite")
    }

    private func withDatabase<T>(_ action: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw StorageError(detail: "Could not open the library database.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS library_state (id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK else {
            throw failure(db)
        }
        return try action(db)
    }

    private func failure(_ db: OpaquePointer) -> StorageError {
        StorageError(detail: String(cString: sqlite3_errmsg(db)))
    }

    func load() throws -> SavedLibrary {
        try withDatabase { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT payload FROM library_state WHERE id = 1", -1, &statement, nil) == SQLITE_OK else { throw failure(db) }
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return SavedLibrary() }
            guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure(db) }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            let state = try JSONDecoder().decode(SavedLibrary.self, from: data)
            guard state.version == 1 else {
                throw StorageError(detail: "Unsupported library database version.")
            }
            return state
        }
    }

    func save(_ state: SavedLibrary) throws {
        let data = try JSONEncoder().encode(state)
        try withDatabase { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO library_state(id, payload) VALUES(1, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", -1, &statement, nil) == SQLITE_OK else { throw failure(db) }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let bindResult = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), transient)
            }
            guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
        }
    }
}
