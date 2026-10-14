import Foundation
import XCTest
@testable import HungrySpotCore

final class AuthenticationTests: XCTestCase {
    private var database: Database!
    private var auth: AuthenticationService!
    private let password = "A-strong-test-password-42!"

    override func setUpWithError() throws {
        database = try Database(path: ":memory:")
        try database.bootstrap()
        auth = AuthenticationService(database: database)
    }
    override func tearDownWithError() throws { try database.close() }

    private func administrator() throws -> Session {
        try auth.setupAdmin(username: "owner", password: password)
    }
    private func cashier(admin: Session) throws -> Session {
        _ = try auth.saveUser(session: admin, id: nil, username: "cashier", password: password, role: .cashier, isActive: true)
        return try auth.login(username: "cashier", password: password)
    }
    private func forbidden(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case SpotError.forbidden = error else { return XCTFail("Expected a role denial, got \(error)", file: file, line: line) }
        }
    }
    private func unauthenticated(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case SpotError.unauthenticated = error else { return XCTFail("Expected an invalid session, got \(error)", file: file, line: line) }
        }
    }

    func testFirstRunHasNoDefaultCredentialsAndOnlyOneSetup() throws {
        XCTAssertTrue(try auth.needsSetup())
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM users"), 0)
        XCTAssertThrowsError(try auth.setupAdmin(username: "owner", password: "short"))
        XCTAssertTrue(try auth.needsSetup())
        let admin = try administrator()
        XCTAssertFalse(try auth.needsSetup())
        XCTAssertEqual(try auth.authorize(admin, admin: true).role, .admin)
        XCTAssertThrowsError(try auth.setupAdmin(username: "another", password: password))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM users"), 1)
    }

    func testSaltedPasswordHashLoginAndUniqueUsernames() throws {
        let admin = try administrator()
        _ = try auth.saveUser(session: admin, id: nil, username: "cashier", password: password, role: .cashier, isActive: true)
        let rows = try database.query(sql: "SELECT password_hash,password_salt,password_iterations FROM users ORDER BY id")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].data("password_hash").count, 32)
        XCTAssertEqual(rows[0].data("password_salt").count, 32)
        XCTAssertEqual(rows[0].int("password_iterations"), 600_000)
        XCTAssertNotEqual(rows[0].data("password_hash"), Data(password.utf8))
        XCTAssertNotEqual(rows[0].data("password_hash"), rows[1].data("password_hash"))
        XCTAssertNotEqual(rows[0].data("password_salt"), rows[1].data("password_salt"))
        XCTAssertEqual(try auth.login(username: "  OWNER  ", password: password).user.id, admin.user.id)
        XCTAssertThrowsError(try auth.login(username: "owner", password: "wrong-password"))
        XCTAssertThrowsError(try auth.saveUser(session: admin, id: nil, username: "OWNER", password: password, role: .cashier, isActive: true))
        XCTAssertThrowsError(try auth.saveUser(session: admin, id: nil, username: "bad name", password: password, role: .cashier, isActive: true))
    }

    func testUnknownUserAndKnownUserFailuresHaveSameMessageAndThrottle() throws {
        _ = try administrator()
        var messages: [String] = []
        for name in ["owner", "missing"] {
            do { _ = try auth.login(username: name, password: "wrong-password") }
            catch { messages.append(error.localizedDescription) }
        }
        XCTAssertEqual(messages, ["Username or password is incorrect.", "Username or password is incorrect."])
        for _ in 0..<4 { XCTAssertThrowsError(try auth.login(username: "owner", password: "wrong-password")) }
        XCTAssertThrowsError(try auth.login(username: "OWNER", password: password)) { error in
            XCTAssertTrue(error.localizedDescription.contains("one minute"))
        }
    }

    func testCashierCannotAcquireAdministratorRightsByForgingSessionUser() throws {
        let admin = try administrator(), clerk = try cashier(admin: admin)
        let forged = Session(token: clerk.token, user: User(id: clerk.user.id, username: "owner", role: .admin))
        XCTAssertEqual(try auth.authorize(forged).role, .cashier)
        let catalog = CatalogService(database: database, auth: auth)
        let product = try XCTUnwrap(catalog.products(session: admin).first)
        let category = try XCTUnwrap(catalog.categories(session: admin).first)
        forbidden { _ = try auth.users(session: forged) }
        forbidden { _ = try auth.saveUser(session: forged, id: nil, username: "intruder", password: self.password, role: .admin, isActive: true) }
        forbidden { _ = try catalog.products(session: forged, includeInactive: true) }
        forbidden { _ = try catalog.categories(session: forged, includeInactive: true) }
        forbidden { _ = try catalog.saveProduct(session: forged, product: product) }
        forbidden { _ = try catalog.duplicateProduct(session: forged, id: product.id) }
        forbidden { try catalog.deleteProduct(session: forged, id: product.id) }
        forbidden { _ = try catalog.saveCategory(session: forged, category: category) }
        forbidden { try catalog.deleteCategory(session: forged, id: category.id) }
        forbidden { try catalog.saveDeal(session: forged, deal: Deal(productID: product.id)) }
        forbidden { try catalog.saveSettings(session: forged, settings: AppSettings()) }
        forbidden { _ = try catalog.audit(session: forged) }
        XCTAssertFalse(try catalog.products(session: clerk).isEmpty)
        XCTAssertEqual(try catalog.settings(session: clerk).restaurantName, "THE HUNGRY SPOT")
    }

    func testRandomTokensIdentityMismatchLogoutAndRestoreInvalidation() throws {
        let admin = try administrator(), clerk = try cashier(admin: admin)
        unauthenticated { _ = try self.auth.authorize(Session(token: UUID(), user: admin.user)) }
        unauthenticated { _ = try self.auth.authorize(Session(token: clerk.token, user: admin.user)) }
        auth.logout(clerk)
        unauthenticated { _ = try self.auth.authorize(clerk) }
        XCTAssertNoThrow(try auth.authorize(admin))
        auth.invalidateAllSessions()
        unauthenticated { _ = try self.auth.authorize(admin) }
    }

    func testPersistedRoleAndActiveStatusAreRecheckedOnEveryOperation() throws {
        let admin = try administrator()
        try database.execute(sql: "UPDATE users SET role='cashier' WHERE id=?", parameters: [.integer(admin.user.id)])
        forbidden { _ = try self.auth.authorize(admin, admin: true) }
        XCTAssertEqual(try auth.authorize(admin).role, .cashier)
        try database.execute(sql: "UPDATE users SET is_active=0 WHERE id=?", parameters: [.integer(admin.user.id)])
        unauthenticated { _ = try self.auth.authorize(admin) }
    }

    func testCannotDeactivateOrDemoteTheLastAdministrator() throws {
        let admin = try administrator()
        XCTAssertThrowsError(try auth.saveUser(session: admin, id: admin.user.id, username: "owner", password: nil, role: .cashier, isActive: true))
        XCTAssertThrowsError(try auth.saveUser(session: admin, id: admin.user.id, username: "owner", password: nil, role: .admin, isActive: false))
        XCTAssertEqual(try auth.authorize(admin, admin: true).role, .admin)
        _ = try auth.saveUser(session: admin, id: nil, username: "second-admin", password: password, role: .admin, isActive: true)
        _ = try auth.saveUser(session: admin, id: admin.user.id, username: "owner", password: nil, role: .cashier, isActive: true)
        unauthenticated { _ = try self.auth.authorize(admin) }
        XCTAssertEqual(try auth.login(username: "owner", password: password).user.role, .cashier)
    }

    func testAccountChangesInvalidateSessionsAndInactiveAccountsCannotLogin() throws {
        let admin = try administrator(), clerk = try cashier(admin: admin)
        _ = try auth.saveUser(session: admin, id: clerk.user.id, username: "cashier", password: nil, role: .cashier, isActive: false)
        unauthenticated { _ = try self.auth.authorize(clerk) }
        XCTAssertThrowsError(try auth.login(username: "cashier", password: password))
        XCTAssertNoThrow(try auth.authorize(admin, admin: true))
    }

    func testPasswordChangeKeepsCurrentSessionAndRevokesOtherSessions() throws {
        let admin = try administrator(), other = try auth.login(username: "owner", password: password)
        let replacement = "A-new-secure-password-42!"
        XCTAssertThrowsError(try auth.changePassword(session: admin, currentPassword: "incorrect", newPassword: replacement))
        try auth.changePassword(session: admin, currentPassword: password, newPassword: replacement)
        XCTAssertNoThrow(try auth.authorize(admin, admin: true))
        unauthenticated { _ = try self.auth.authorize(other) }
        XCTAssertThrowsError(try auth.login(username: "owner", password: password))
        XCTAssertNoThrow(try auth.login(username: "owner", password: replacement))
        let log = try database.query(sql: "SELECT details FROM audit_logs").map { $0.string("details") }.joined()
        XCTAssertFalse(log.contains(password)); XCTAssertFalse(log.contains(replacement))
    }

    func testAccountMutationRollsBackIfAuditCannotBeSaved() throws {
        let admin = try administrator(), clerk = try cashier(admin: admin)
        try database.execute(sql: "CREATE TRIGGER reject_user_audit BEFORE INSERT ON audit_logs WHEN NEW.action='User changed' BEGIN SELECT RAISE(ABORT, 'test audit failure'); END")
        XCTAssertThrowsError(try auth.saveUser(session: admin, id: clerk.user.id, username: "changed", password: nil, role: .cashier, isActive: false))
        XCTAssertEqual(try auth.authorize(clerk).username, "cashier")
        XCTAssertTrue(try auth.authorize(clerk).isActive)
    }
}
