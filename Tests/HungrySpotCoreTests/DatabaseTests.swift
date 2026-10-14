import Foundation
import SQLite3
import XCTest
@testable import HungrySpotCore

final class DatabaseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HungrySpotDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testBootstrapSeedsExactCountsWithNoDefaultUserOrDemonstrationOrders() throws {
        let database = try Database(path: ":memory:"); defer { try? database.close() }
        try database.bootstrap()
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM categories WHERE parent_id IS NULL"), 9)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM categories WHERE parent_id IS NOT NULL"), 8)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM products"), 62)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM product_variants"), 49)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM deals"), 14)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM users"), 0)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM orders"), 0)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM payments"), 0)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM settings WHERE key='initial_seed_complete' AND value='1'"), 1)
        let row = try XCTUnwrap(database.query(sql: "SELECT value FROM settings WHERE key='app_settings'").first)
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(row.string("value").utf8))
        XCTAssertEqual(settings.dipSaucePrice, 5_000); XCTAssertEqual(settings.currencySymbol, "Rs")
        XCTAssertEqual(try database.query(sql: "PRAGMA integrity_check").first?.string("integrity_check"), "ok")
        XCTAssertTrue(try database.query(sql: "PRAGMA foreign_key_check").isEmpty)
    }

    func testBootstrapDoesNotRestoreDeletedSeedRowsOrOverwriteAdminEdits() throws {
        let database = try Database(path: ":memory:"); defer { try? database.close() }
        try database.bootstrap()
        try database.execute(sql: "UPDATE products SET name='Owner edited burger',base_price=43210 WHERE name='Anda Shami Burger'")
        try database.execute(sql: "DELETE FROM products WHERE name='300 ml'")
        try database.execute(sql: "UPDATE settings SET value='owner-value' WHERE key='app_settings'")
        try database.bootstrap(); try database.bootstrap()
        XCTAssertEqual(try database.scalarInt(sql: "SELECT base_price FROM products WHERE name='Owner edited burger'"), 43_210)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM products"), 61)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM products WHERE name='300 ml'"), 0)
        XCTAssertEqual(try database.query(sql: "SELECT value FROM settings WHERE key='app_settings'").first?.string("value"), "owner-value")
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM schema_migrations"), 1)
    }

    func testFutureSchemaVersionIsRejectedWithoutChangingData() throws {
        let database = try Database(path: ":memory:"); defer { try? database.close() }
        try database.bootstrap()
        try database.execute(sql: "INSERT INTO schema_migrations(version,applied_at) VALUES(2,0)")
        XCTAssertThrowsError(try database.bootstrap())
        XCTAssertEqual(try database.scalarInt(sql: "SELECT MAX(version) FROM schema_migrations"), 2)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM products"), 62)
    }

    func testNestedSavepointRollbackDoesNotDiscardOuterTransaction() throws {
        let database = try Database(path: ":memory:"); defer { try? database.close() }
        try database.execute(sql: "CREATE TABLE transaction_test(id INTEGER PRIMARY KEY,value TEXT)")
        try database.transaction {
            try database.execute(sql: "INSERT INTO transaction_test VALUES(1,'before')")
            XCTAssertThrowsError(try database.transaction {
                try database.execute(sql: "INSERT INTO transaction_test VALUES(2,'rolled back')")
                throw SpotError.validation("test failure")
            })
            try database.execute(sql: "INSERT INTO transaction_test VALUES(3,'after')")
        }
        XCTAssertEqual(try database.query(sql: "SELECT id FROM transaction_test ORDER BY id").map { $0.int("id") }, [1, 3])
        XCTAssertThrowsError(try database.transaction {
            try database.transaction { try database.execute(sql: "INSERT INTO transaction_test VALUES(4,'nested commit')") }
            throw SpotError.validation("outer failure")
        })
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM transaction_test"), 2)
        XCTAssertThrowsError(try database.transaction { try database.close() })
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM transaction_test"), 2)
    }

    func testPreparedParametersPreserveUnicodeNullBytesAndBinaryData() throws {
        let database = try Database(path: ":memory:"); defer { try? database.close() }
        try database.execute(sql: "CREATE TABLE typed_test(id INTEGER PRIMARY KEY,text_value TEXT,blob_value BLOB,optional_value INTEGER,real_value REAL)")
        let text = "Eat • Enjoy • Repeat 🍔\0continued", blob = Data([0, 1, 127, 128, 255])
        try database.execute(sql: "INSERT INTO typed_test VALUES(?,?,?,?,?)", parameters: [.integer(1), .text(text), .blob(blob), .null, .real(2.5)])
        let row = try XCTUnwrap(database.query(sql: "SELECT * FROM typed_test WHERE id=?", parameters: [.integer(1)]).first)
        XCTAssertEqual(row.string("text_value"), text); XCTAssertEqual(row.data("blob_value"), blob)
        XCTAssertNil(row.optionalInt("optional_value")); XCTAssertEqual(row.double("real_value"), 2.5)
        XCTAssertThrowsError(try database.execute(sql: "INSERT INTO typed_test(id) VALUES(?)", parameters: []))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM typed_test"), 1)
    }

    func testFileReopenPreservesCatalogSettingsAndForeignKeyEnforcement() throws {
        let database = try Database(path: directory.appendingPathComponent("live.sqlite3").path)
        defer { try? database.close() }
        try database.bootstrap()
        try database.execute(sql: "UPDATE products SET base_price=56789 WHERE name='Chicken Paratha'")
        try database.close()
        XCTAssertThrowsError(try database.query(sql: "SELECT * FROM products"))
        try database.reopen(); try database.bootstrap()
        XCTAssertEqual(try database.scalarInt(sql: "SELECT base_price FROM products WHERE name='Chicken Paratha'"), 56_789)
        XCTAssertEqual(try database.scalarInt(sql: "PRAGMA foreign_keys"), 1)
        XCTAssertThrowsError(try database.execute(sql: "DELETE FROM categories WHERE name='Burgers'"))
    }

    func testOnlineBackupIncludesCommittedWALAndReadonlyOpenCreatesNoSidecars() throws {
        let database = try Database(path: directory.appendingPathComponent("live.sqlite3").path)
        defer { try? database.close() }
        try database.bootstrap()
        _ = try database.query(sql: "PRAGMA wal_autocheckpoint=0")
        try database.execute(sql: "UPDATE products SET base_price=67890 WHERE name='Chicken Paratha'")
        let destination = directory.appendingPathComponent("snapshot.sqlite3")
        try database.backup(to: destination)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(destination.path, &raw, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let connection = try XCTUnwrap(raw)
        defer { sqlite3_close_v2(connection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT base_price FROM products WHERE name='Chicken Paratha'", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(statement, 0), 67_890)
        sqlite3_finalize(statement); statement = nil
        XCTAssertEqual(sqlite3_prepare_v2(connection, "PRAGMA journal_mode", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let mode = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        XCTAssertEqual(mode, "delete")
        sqlite3_finalize(statement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + "-shm"))
        XCTAssertThrowsError(try database.backup(to: destination))
        XCTAssertThrowsError(try database.backup(to: database.url))
        XCTAssertThrowsError(try database.transaction { try database.backup(to: self.directory.appendingPathComponent("inside-transaction.sqlite3")) })
    }
}
