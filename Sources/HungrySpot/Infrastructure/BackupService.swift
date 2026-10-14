import Foundation
import CryptoKit
import SQLite3
import HungrySpotCore

private struct BackupManifest: Codable {
    let formatVersion: Int
    let createdAt: Date
    let files: [String: String]
}

final class BackupService {
    private let database: Database
    private let auth: AuthenticationService
    private let paths: AppPaths
    private let fm = FileManager.default
    init(database: Database, auth: AuthenticationService, paths: AppPaths) {
        self.database = database; self.auth = auth; self.paths = paths
    }

    @discardableResult
    func create(session: Session, destination: URL? = nil) throws -> URL {
        return try database.withExclusiveAccess {
            _ = try auth.authorize(session, admin: true)
            let parent = destination ?? paths.backups
            let access = parent.startAccessingSecurityScopedResource()
            defer { if access { parent.stopAccessingSecurityScopedResource() } }
            let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL.path
            for reserved in [paths.images, paths.databaseURL.deletingLastPathComponent()] {
                let path = reserved.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolvedParent != path && !resolvedParent.hasPrefix(path + "/") else {
                    throw SpotError.validation("Choose a backup destination outside the live database and image folders.")
                }
            }
            guard !parent.pathComponents.contains(where: { $0.hasPrefix(".restore-") || $0.hasPrefix(".backup-") }) else {
                throw SpotError.validation("Choose a normal folder for the backup.")
            }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let directory = parent.appendingPathComponent("TheHungrySpot-\(stamp)-\(UUID().uuidString.prefix(6))", isDirectory: true)
            let staging = parent.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            do {
                try database.backup(to: staging.appendingPathComponent("database.sqlite3"))
                try fm.copyItem(at: paths.images, to: staging.appendingPathComponent("images"))
                let entries = try dataFiles(in: staging)
                var hashes = [String: String]()
                for (relative, url) in entries { hashes[relative] = try digest(url) }
                let manifest = BackupManifest(formatVersion: 1, createdAt: Date(), files: hashes)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
                _ = try validate(staging)
                try fm.moveItem(at: staging, to: directory)
                try AuditService(database: database).record(userID: session.user.id, action: "Backup created", entity: "database", details: directory.lastPathComponent)
                return directory
            } catch {
                if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) }
                throw error
            }
        }
    }

    func validate(_ directory: URL) throws -> String {
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let info = try manifestURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard info.isSymbolicLink != true, (info.fileSize ?? 0) <= 4 * 1024 * 1024 else {
            throw SpotError.validation("The backup manifest is invalid.")
        }
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.formatVersion == 1, manifest.files["database.sqlite3"] != nil else {
            throw SpotError.validation("This backup format is not supported.")
        }
        let files = try dataFiles(in: directory)
        guard Set(files.keys) == Set(manifest.files.keys) else {
            throw SpotError.validation("Backup files are missing or unexpected files were found.")
        }
        for (relative, url) in files {
            guard try digest(url) == manifest.files[relative] else {
                throw SpotError.validation("The backup is damaged: \(relative).")
            }
        }
        try validateDatabase(directory.appendingPathComponent("database.sqlite3"), files: Set(files.keys))
        return "Backup from \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened)); \(max(0, files.count - 1)) image assets. Current data will be replaced after a safety backup is saved."
    }

    func restore(session: Session, from source: URL, confirmed: Bool) throws {
        guard confirmed else { throw SpotError.validation("Confirm the restore before continuing.") }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try database.withExclusiveAccess {
            _ = try auth.authorize(session, admin: true)
            _ = try validate(source)
            let safety = try create(session: session)
            let journal = paths.root.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: journal, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                // Validate a private copy to prevent the source from changing during restore.
                let stagedBackup = journal.appendingPathComponent("verified")
                try fm.copyItem(at: source, to: stagedBackup)
                _ = try validate(stagedBackup)
                let newDatabase = journal.appendingPathComponent("new-database", isDirectory: true)
                try fm.createDirectory(at: newDatabase, withIntermediateDirectories: false)
                try fm.copyItem(at: stagedBackup.appendingPathComponent("database.sqlite3"), to: newDatabase.appendingPathComponent("spot.sqlite3"))
                let liveDatabase = paths.databaseURL.deletingLastPathComponent()
                try database.close()
                try fm.moveItem(at: liveDatabase, to: journal.appendingPathComponent("old-database"))
                try fm.moveItem(at: newDatabase, to: liveDatabase)
                try fm.moveItem(at: paths.images, to: journal.appendingPathComponent("old-images"))
                try fm.moveItem(at: stagedBackup.appendingPathComponent("images"), to: paths.images)
                try database.reopen()
                // Restored user IDs can differ; preserve initiator identity as text, not a false FK.
                try AuditService(database: database).record(userID: nil, action: "Database restored", entity: "database", details: "Restored by \(session.user.username). Safety backup: \(safety.lastPathComponent)")
                try Data("committed".utf8).write(to: journal.appendingPathComponent("committed"), options: .atomic)
                auth.invalidateAllSessions()
            } catch {
                do {
                    try database.close()
                    try AppPaths.recoverInterruptedRestore(in: paths.root)
                    try database.reopen()
                } catch let recoveryError {
                    auth.invalidateAllSessions()
                    throw SpotError.validation("Restore failed and automatic recovery needs attention: \(recoveryError.localizedDescription). Safety backup: \(safety.path). Quit the app and keep all data folders.")
                }
                throw SpotError.validation("Restore could not finish: \(error.localizedDescription). Your previous data was recovered. Safety backup: \(safety.lastPathComponent).")
            }
            // Cleanup is after commit. If it fails, startup retries it without rolling
            // back a successful restore or incorrectly claiming the old data is live.
            do { try fm.removeItem(at: journal) }
            catch { NSLog("Hungry Spot: committed restore journal cleanup deferred: %@", error.localizedDescription) }
        }
    }

    private func dataFiles(in directory: URL) throws -> [String: URL] {
        let root = directory.standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let rootInfo = try root.resourceValues(forKeys: keys)
        guard rootInfo.isDirectory == true, rootInfo.isSymbolicLink != true else { throw SpotError.validation("Choose a backup folder, not a link.") }
        var result = [String: URL]()
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) {
            guard ["database.sqlite3", "images", "manifest.json"].contains(item.lastPathComponent) else { throw SpotError.validation("Unexpected backup file: \(item.lastPathComponent)") }
            let info = try item.resourceValues(forKeys: keys)
            guard info.isSymbolicLink != true else { throw SpotError.validation("Backup links are not supported.") }
            if item.lastPathComponent == "manifest.json" { continue }
            if item.lastPathComponent == "database.sqlite3" {
                guard info.isRegularFile == true else { throw SpotError.validation("The backup database is missing.") }
                result["database.sqlite3"] = item
            } else {
                guard info.isDirectory == true else { throw SpotError.validation("The backup image directory is missing.") }
                var enumerationError: Error?
                guard let enumerator = fm.enumerator(at: item, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in enumerationError = error; return false }) else { throw SpotError.validation("Cannot read the backup images.") }
                while let file = enumerator.nextObject() as? URL {
                    let value = try file.resourceValues(forKeys: keys)
                    guard value.isSymbolicLink != true else { throw SpotError.validation("Backup image links are not supported.") }
                    if value.isRegularFile == true {
                        guard result.count < 100_000 else { throw SpotError.validation("This backup contains too many files.") }
                        result[String(file.path.dropFirst(root.path.count + 1))] = file
                    } else if value.isDirectory != true { throw SpotError.validation("Unsupported file in backup.") }
                }
                if let enumerationError { throw enumerationError }
            }
        }
        guard fm.fileExists(atPath: root.appendingPathComponent("images").path), result["database.sqlite3"] != nil else {
            throw SpotError.validation("The backup is incomplete.")
        }
        return result
    }

    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func validateDatabase(_ url: URL, files: Set<String>) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let connection = handle else {
            if let handle { sqlite3_close(handle) }
            throw SpotError.validation("The backup database cannot be opened.")
        }
        defer { sqlite3_close(connection) }
        func values(_ sql: String) throws -> [String] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK else { throw SpotError.validation("The backup schema is incompatible.") }
            defer { sqlite3_finalize(stmt) }
            var result = [String](); var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                if let bytes = sqlite3_column_text(stmt, 0) { result.append(String(cString: bytes)) }
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw SpotError.validation("The backup database is damaged.") }
            return result
        }
        let expectedColumns: [String: String] = [
            "schema_migrations": "version applied_at",
            "users": "id username password_hash password_salt password_iterations role is_active created_at",
            "categories": "id name parent_id display_order is_active icon image_path",
            "products": "id name category_id subcategory_id description kind base_price image_path is_available is_active display_order",
            "product_variants": "id product_id name price display_order is_available topping_price",
            "deals": "product_id needs_review review_note",
            "deal_items": "id deal_id label quantity requires_selection display_order",
            "deal_item_choices": "id deal_item_id product_id variant_id",
            "orders": "id request_id request_payload order_number type status created_at cashier_id cashier_name customer_name customer_phone customer_address notes cancellation_reason subtotal delivery_charge discount total",
            "order_items": "id order_id product_id product_name category_name variant_name unit_price extra_price quantity notes",
            "order_item_options": "id order_item_id name quantity unit_price product_id variant_id",
            "payments": "id order_id amount method cashier_id created_at",
            "expenses": "id expense_date amount description user_id",
            "settings": "key value",
            "audit_logs": "id user_id username action entity details created_at"
        ]
        for (table, columns) in expectedColumns {
            let actual = try Set(values("SELECT name FROM pragma_table_info('\(table)')"))
            guard Set(columns.split(separator: " ").map(String.init)).isSubset(of: actual) else {
                throw SpotError.validation("The backup has an incompatible \(table) table.")
            }
        }
        guard try values("PRAGMA integrity_check") == ["ok"], try values("PRAGMA foreign_key_check").isEmpty,
              try values("SELECT MAX(version) FROM schema_migrations") == ["1"],
              (try values("SELECT COUNT(*) FROM users WHERE role='admin' AND is_active=1").first.flatMap(Int.init) ?? 0) > 0,
              try values("SELECT value FROM settings WHERE key='initial_seed_complete'") == ["1"] else {
            throw SpotError.validation("The backup failed integrity, version, or administrator checks.")
        }
        guard let settingsJSON = try values("SELECT value FROM settings WHERE key='app_settings'").first else { throw SpotError.validation("The backup is missing restaurant settings.") }
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(settingsJSON.utf8))
        guard [58, 80].contains(settings.paperWidthMM), !settings.restaurantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.currencySymbol.isEmpty, settings.quickDeliveryCharges.count <= 12,
              ([settings.defaultDeliveryCharge, settings.dipSaucePrice] + settings.quickDeliveryCharges).allSatisfy({ $0 >= 0 && $0 <= 9_999_999_999 }) else { throw SpotError.validation("The backup contains invalid restaurant settings.") }
        var references = try values("SELECT image_path FROM products WHERE image_path IS NOT NULL UNION SELECT image_path FROM categories WHERE image_path IS NOT NULL")
        if let logo = settings.logoPath { references.append(logo) }
        for relative in references {
            guard !relative.hasPrefix("/"), !relative.contains("\\"), !relative.split(separator: "/").contains(".."), files.contains("images/" + relative) else {
                throw SpotError.validation("The backup is missing a referenced image asset.")
            }
        }
        guard try values("SELECT id FROM orders WHERE subtotal != COALESCE((SELECT SUM((unit_price+extra_price)*quantity) FROM order_items WHERE order_id=orders.id),0) OR total != subtotal+delivery_charge-discount LIMIT 1").isEmpty,
              try values("SELECT o.id FROM orders o LEFT JOIN payments p ON p.order_id=o.id WHERE (o.status IN ('PAID','COMPLETED') AND p.id IS NULL) OR (p.id IS NOT NULL AND (p.amount != o.total OR o.status NOT IN ('PAID','COMPLETED'))) LIMIT 1").isEmpty else {
            throw SpotError.validation("The backup contains inconsistent order or payment totals.")
        }
    }
}
