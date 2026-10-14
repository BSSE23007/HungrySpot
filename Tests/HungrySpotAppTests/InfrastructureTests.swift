import AppKit
import CryptoKit
import XCTest
import HungrySpotCore
@testable import HungrySpot

final class InfrastructureTests: XCTestCase {
    private var root: URL!
    private var paths: AppPaths!
    private var database: Database!
    private var auth: AuthenticationService!
    private var admin: Session!
    private var catalog: CatalogService!
    private var backups: BackupService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HungrySpotTests-\(UUID().uuidString)")
        paths = try AppPaths(root: root)
        database = try Database(path: paths.databaseURL.path)
        try database.bootstrap()
        auth = AuthenticationService(database: database)
        admin = try auth.setupAdmin(username: "owner", password: "Test-owner-password-42!")
        catalog = CatalogService(database: database, auth: auth)
        backups = BackupService(database: database, auth: auth, paths: paths)
    }
    override func tearDownWithError() throws {
        if let database { try database.close() }
        backups = nil; catalog = nil; auth = nil; database = nil; paths = nil
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testSecondProcessStoreLockIsRejected() throws {
        XCTAssertThrowsError(try AppPaths(root: root))
    }
    func testBackupRoundTripRestoresCatalogAndInvalidatesSession() throws {
        var product = try XCTUnwrap(catalog.products(session: admin).first { $0.name == "Zinger Burger" })
        let original = product.basePrice
        let saved = try backups.create(session: admin)
        XCTAssertFalse(try backups.validate(saved).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.appendingPathComponent("database.sqlite3-wal").path))
        product.basePrice += 5000
        _ = try catalog.saveProduct(session: admin, product: product)
        XCTAssertThrowsError(try backups.restore(session: admin, from: saved, confirmed: false))
        XCTAssertEqual(try catalog.product(session: admin, id: product.id).basePrice, original + 5000)
        try backups.restore(session: admin, from: saved, confirmed: true)
        XCTAssertThrowsError(try auth.authorize(admin))
        let restoredSession = try auth.login(username: "owner", password: "Test-owner-password-42!")
        XCTAssertEqual(try catalog.product(session: restoredSession, id: product.id).basePrice, original)
        XCTAssertGreaterThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: paths.backups.path).count, 2)
    }
    func testTamperedImageAndMissingSchemaAreRejected() throws {
        let image = paths.images.appendingPathComponent("products/test.jpg")
        try Data([1, 2, 3]).write(to: image)
        let saved = try backups.create(session: admin)
        try Data([4, 5, 6]).write(to: saved.appendingPathComponent("images/products/test.jpg"))
        XCTAssertThrowsError(try backups.validate(saved))
        let other = try backups.create(session: admin)
        let foreignDB = try Database(path: other.appendingPathComponent("database.sqlite3").path)
        try foreignDB.execute(sql: "DROP TABLE expenses")
        try foreignDB.close()
        try updateManifestHash(in: other, relative: "database.sqlite3")
        XCTAssertThrowsError(try backups.validate(other))
        XCTAssertNoThrow(try auth.authorize(admin))
    }
    func testBackupRejectsMissingReferencedImagesAndRecursiveDestination() throws {
        var product = try XCTUnwrap(catalog.products(session: admin).first)
        product.imagePath = "products/missing.jpg"
        _ = try catalog.saveProduct(session: admin, product: product)
        XCTAssertThrowsError(try backups.create(session: admin))
        product.imagePath = nil; _ = try catalog.saveProduct(session: admin, product: product)
        XCTAssertThrowsError(try backups.create(session: admin, destination: paths.images))
    }
    func testCashierCannotBackUpOrRestore() throws {
        _ = try auth.saveUser(session: admin, id: nil, username: "cashier", password: "Cashier-test-password-42!", role: .cashier, isActive: true)
        let cashier = try auth.login(username: "cashier", password: "Cashier-test-password-42!")
        let saved = try backups.create(session: admin)
        XCTAssertThrowsError(try backups.create(session: cashier))
        XCTAssertThrowsError(try backups.restore(session: cashier, from: saved, confirmed: true))
    }
    func testRestoreJournalRecoversPreviousDirectories() throws {
        try database.close()
        let journal = root.appendingPathComponent(".restore-test")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("database"), to: journal.appendingPathComponent("old-database"))
        try FileManager.default.moveItem(at: paths.images, to: journal.appendingPathComponent("old-images"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("database"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.images, withIntermediateDirectories: true)
        try AppPaths.recoverInterruptedRestore(in: root)
        try database.reopen()
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM users"), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testImageImportOptimizesAndReplacementUsesNewReference() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 1100, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let source = root.appendingPathComponent("fixture.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)
        let storage = ImageStorageService(paths: paths)
        let first = try storage.importImage(from: source), second = try storage.importImage(from: source)
        XCTAssertNotEqual(first, second)
        let optimizedURL = try XCTUnwrap(storage.url(for: first))
        let optimized = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: optimizedURL)))
        XCTAssertLessThanOrEqual(max(optimized.pixelsWide, optimized.pixelsHigh), 1000)
        XCTAssertNil(storage.url(for: "../database/spot.sqlite3"))
        XCTAssertNil(storage.url(for: "/etc/passwd"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(storage.url(for: second)).path))
    }
    func testKitchenTicketHasConfigurationButNoPaymentAmounts() throws {
        let order = OrderRecord(id: 1, number: "00001", type: .delivery, status: .paid, createdAt: Date(timeIntervalSince1970: 0), cashierID: 1, cashierName: "Owner", customerName: "Customer", customerPhone: "03001234567", customerAddress: "Sample address", quote: Quote(items: [OrderItemSnapshot(productID: 1, productName: "Chicken Tikka", categoryName: "Pizza", variantName: "Medium", unitPrice: 90000, extraPrice: 20000, options: [OptionSnapshot(name: "Selected variant: Medium"), OptionSnapshot(name: "Extra Topping", quantity: 2, unitPrice: 10000)])], subtotal: 110000, deliveryCharge: 5000, discount: 0), payment: Payment(id: 1, orderID: 1, amount: 115000, method: .cash, cashierID: 1, createdAt: Date()))
        let kitchen = ReceiptText.render(order, settings: AppSettings(), kitchen: true)
        XCTAssertTrue(kitchen.contains("Extra Topping × 2"))
        XCTAssertTrue(kitchen.contains("Sample address"))
        XCTAssertFalse(kitchen.contains("TOTAL"))
        XCTAssertFalse(kitchen.contains("Rs"))
        XCTAssertFalse(kitchen.contains("CASH"))
        let receipt = ReceiptText.render(order, settings: AppSettings(), kitchen: false)
        XCTAssertTrue(receipt.contains("CASH"))
        XCTAssertTrue(receipt.contains("TOTAL:"))
        XCTAssertFalse(receipt.contains("Selected variant:"))
    }

    private func updateManifestHash(in directory: URL, relative: String) throws {
        let file = directory.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var hashes = try XCTUnwrap(manifest["files"] as? [String: String])
        hashes[relative] = SHA256.hash(data: try Data(contentsOf: directory.appendingPathComponent(relative))).map { String(format: "%02x", $0) }.joined()
        manifest["files"] = hashes
        try JSONSerialization.data(withJSONObject: manifest).write(to: file)
    }
}
