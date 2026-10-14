import Foundation
import SQLite3

public enum SQLValue {
    case null, integer(Int64), real(Double), text(String), blob(Data)
}

public struct SQLRow {
    private let values: [String: SQLValue]
    init(_ values: [String: SQLValue]) { self.values = values }
    public func optionalInt(_ key: String) -> Int64? {
        switch values[key] { case .integer(let n): return n; case .real(let n): return Int64(n); default: return nil }
    }
    public func int(_ key: String) -> Int64 { optionalInt(key) ?? 0 }
    public func optionalString(_ key: String) -> String? {
        if case .text(let s) = values[key] { return s }; return nil
    }
    public func string(_ key: String) -> String { optionalString(key) ?? "" }
    public func double(_ key: String) -> Double {
        switch values[key] { case .real(let n): return n; case .integer(let n): return Double(n); default: return 0 }
    }
    public func data(_ key: String) -> Data {
        if case .blob(let d) = values[key] { return d }; return Data()
    }
}

/// One connection, one recursive lock. Multi-statement business operations must use transaction.
public final class Database {
    public let path: String
    public var url: URL { URL(fileURLWithPath: path) }
    private var connection: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var depth = 0
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws { self.path = path; try reopen() }
    deinit { if let connection { sqlite3_close_v2(connection) } }

    public func withExclusiveAccess<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    public func close() throws {
        try withExclusiveAccess {
            guard depth == 0 else { throw SpotError.database("Cannot close a database during a transaction.") }
            if let connection {
                guard sqlite3_close(connection) == SQLITE_OK else { throw failure("Close") }
                self.connection = nil
            }
        }
    }
    public func reopen() throws {
        try withExclusiveAccess {
            guard connection == nil else { return }
            var handle: OpaquePointer?
            guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open storage."
                if let handle { sqlite3_close_v2(handle) }
                throw SpotError.database(reason)
            }
            connection = handle
            sqlite3_busy_timeout(handle, 5000)
            do {
                try execute(sql: "PRAGMA foreign_keys = ON")
                _ = try query(sql: "PRAGMA journal_mode = WAL")
                try execute(sql: "PRAGMA synchronous = FULL")
            } catch { try? close(); throw error }
        }
    }
    private func failure(_ operation: String) -> SpotError {
        let detail = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed."
        return .database("\(operation) failed: \(detail)")
    }
    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer {
        guard let connection else { throw SpotError.database("Database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure("Read database") }
        do {
            guard sqlite3_bind_parameter_count(statement) == Int32(parameters.count) else { throw SpotError.database("Incorrect database parameter count.") }
            for (offset, value) in parameters.enumerated() {
                let i = Int32(offset + 1)
                let result: Int32
                switch value {
                case .null: result = sqlite3_bind_null(statement, i)
                case .integer(let n): result = sqlite3_bind_int64(statement, i, n)
                case .real(let n): result = sqlite3_bind_double(statement, i, n)
                case .text(let s):
                    guard s.utf8.count <= Int(Int32.max) else { throw SpotError.database("Text is too large to store.") }
                    result = s.withCString { sqlite3_bind_text(statement, i, $0, Int32(s.utf8.count), transient) }
                case .blob(let data):
                    guard data.count <= Int(Int32.max) else { throw SpotError.database("Data is too large to store.") }
                    result = data.withUnsafeBytes { raw in
                        if data.isEmpty { return sqlite3_bind_zeroblob(statement, i, 0) }
                        return sqlite3_bind_blob(statement, i, raw.baseAddress, Int32(data.count), transient)
                    }
                }
                guard result == SQLITE_OK else { throw failure("Bind database parameter") }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    public func execute(sql: String, parameters: [SQLValue] = []) throws {
        try withExclusiveAccess {
            let statement = try prepare(sql, parameters); defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("Write database") }
        }
    }
    public func query(sql: String, parameters: [SQLValue] = []) throws -> [SQLRow] {
        try withExclusiveAccess {
            let statement = try prepare(sql, parameters); defer { sqlite3_finalize(statement) }
            var rows: [SQLRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW else { throw failure("Read database") }
                var values: [String: SQLValue] = [:]
                for i in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, i))
                    switch sqlite3_column_type(statement, i) {
                    case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(statement, i))
                    case SQLITE_FLOAT: values[name] = .real(sqlite3_column_double(statement, i))
                    case SQLITE_TEXT:
                        let count = Int(sqlite3_column_bytes(statement, i))
                        if let bytes = sqlite3_column_text(statement, i) {
                            values[name] = .text(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self))
                        } else { values[name] = .text("") }
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, i))
                        values[name] = .blob(sqlite3_column_blob(statement, i).map { Data(bytes: $0, count: count) } ?? Data())
                    default: values[name] = .null
                    }
                }
                rows.append(SQLRow(values))
            }
        }
    }
    public func scalarInt(sql: String, parameters: [SQLValue] = []) throws -> Int64 {
        try withExclusiveAccess {
            let statement = try prepare(sql, parameters); defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return 0 }
            guard result == SQLITE_ROW else { throw failure("Read database") }
            return sqlite3_column_int64(statement, 0)
        }
    }
    public var lastInsertID: Int64 { withExclusiveAccess { connection.map(sqlite3_last_insert_rowid) ?? 0 } }
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try withExclusiveAccess {
            let nested = depth > 0, savepoint = "nested_\(depth)"
            try execute(sql: nested ? "SAVEPOINT \(savepoint)" : "BEGIN IMMEDIATE")
            depth += 1
            do {
                let result = try body()
                try execute(sql: nested ? "RELEASE SAVEPOINT \(savepoint)" : "COMMIT")
                depth -= 1
                return result
            } catch {
                depth -= 1
                if nested {
                    try? execute(sql: "ROLLBACK TO SAVEPOINT \(savepoint)")
                    try? execute(sql: "RELEASE SAVEPOINT \(savepoint)")
                } else { try? execute(sql: "ROLLBACK") }
                throw error
            }
        }
    }
    /// Executes trusted, bundled migration/seed SQL only. User values always use prepared statements.
    private func bundledScript(_ name: String) throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: ResourceAnchor.self)
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "sql") else { throw SpotError.database("Missing bundled database resource: \(name).sql") }
        let sql = try String(contentsOf: url, encoding: .utf8)
        guard let connection else { throw SpotError.database("Database is closed.") }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw failure("Initialize database") }
    }
    public func bootstrap() throws {
        try transaction {
            try execute(sql: "CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at REAL NOT NULL)")
            let version = try scalarInt(sql: "SELECT COALESCE(MAX(version),0) FROM schema_migrations")
            guard version <= 1 else { throw SpotError.database("This database requires a newer version of The Hungry Spot.") }
            if version < 1 {
                try bundledScript("001_schema")
                try execute(sql: "INSERT INTO schema_migrations(version,applied_at) VALUES(1,?)", parameters: [.real(Date().timeIntervalSince1970)])
            }
            if try scalarInt(sql: "SELECT COUNT(*) FROM settings WHERE key = 'initial_seed_complete'") == 0 {
                try bundledScript("seed")
                try execute(sql: "INSERT INTO settings(key,value) VALUES('initial_seed_complete','1')")
            }
            if try scalarInt(sql: "SELECT COUNT(*) FROM settings WHERE key = 'app_settings'") == 0 {
                let data = try JSONEncoder().encode(AppSettings())
                try execute(sql: "INSERT INTO settings(key,value) VALUES('app_settings',?)", parameters: [.text(String(decoding: data, as: UTF8.self))])
            }
        }
    }
    public func backup(to destination: URL) throws {
        try withExclusiveAccess {
            guard depth == 0, let connection else {
                throw SpotError.database(
                    "Backup requires an open database with no active transaction."
                )
            }

            guard destination.standardizedFileURL != url.standardizedFileURL else {
                throw SpotError.validation(
                    "Choose a separate backup destination."
                )
            }

            let fm = FileManager.default

            guard !fm.fileExists(atPath: destination.path) else {
                throw SpotError.conflict(
                    "A file already exists at this backup destination."
                )
            }

            var output: OpaquePointer?

            guard sqlite3_open_v2(
                destination.path,
                &output,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil
            ) == SQLITE_OK, let backupConnection = output else {
                if let output {
                    sqlite3_close_v2(output)
                }

                throw SpotError.database(
                    "Could not create backup database."
                )
            }

            var shouldDeleteDestination = true
            var connectionClosed = false

            defer {
                if !connectionClosed {
                    sqlite3_close_v2(backupConnection)
                }

                if shouldDeleteDestination {
                    try? fm.removeItem(at: destination)
                    try? fm.removeItem(
                        atPath: destination.path + "-wal"
                    )
                    try? fm.removeItem(
                        atPath: destination.path + "-shm"
                    )
                }
            }

            guard let backup = sqlite3_backup_init(
                backupConnection,
                "main",
                connection,
                "main"
            ) else {
                throw SpotError.database(
                    "Could not initialize SQLite backup."
                )
            }

            let result = sqlite3_backup_step(backup, -1)
            let finished = sqlite3_backup_finish(backup)

            guard result == SQLITE_DONE && finished == SQLITE_OK else {
                throw SpotError.database(
                    "SQLite backup could not complete. Please try again."
                )
            }

            // Convert the snapshot from WAL mode to a standalone database.
            guard sqlite3_exec(
                backupConnection,
                "PRAGMA journal_mode=DELETE",
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw SpotError.database(
                    "Could not finalize the standalone backup database."
                )
            }

            // Close before checking/removing SQLite sidecars. On older SQLite/
            // macOS versions the -shm file may persist until the final
            // connection to the snapshot has been closed.
            guard sqlite3_close_v2(backupConnection) == SQLITE_OK else {
                throw SpotError.database(
                    "Could not close the finalized backup database."
                )
            }

            connectionClosed = true

            // A successful standalone DELETE-mode backup has no dependency on
            // WAL/SHM sidecars. Older SQLite versions can leave an empty SHM
            // file behind after the journal-mode transition.
            let walPath = destination.path + "-wal"
            let shmPath = destination.path + "-shm"

            if fm.fileExists(atPath: walPath) {
                try fm.removeItem(atPath: walPath)
            }

            if fm.fileExists(atPath: shmPath) {
                try fm.removeItem(atPath: shmPath)
            }

            shouldDeleteDestination = false
        }
    }
}
private final class ResourceAnchor: NSObject {}
