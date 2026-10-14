import Foundation

public final class AuthenticationService {
    private let database: Database
    private let audit: AuditService
    // Accessed only under the database's recursive lock, matching all service lock order.
    private var tokens: [UUID: Int64] = [:]
    private var failures: [String: (count: Int, since: Date)] = [:]
    public init(database: Database) { self.database = database; self.audit = AuditService(database: database) }

    public func needsSetup() throws -> Bool { try database.scalarInt(sql: "SELECT COUNT(*) FROM users") == 0 }
    public func setupAdmin(username: String, password: String) throws -> Session {
        try database.transaction {
            guard try needsSetup() else { throw SpotError.conflict("The administrator account has already been created.") }
            let name = try validUsername(username), secured = try PasswordHasher.create(password)
            try database.execute(sql: "INSERT INTO users(username,password_hash,password_salt,password_iterations,role,is_active,created_at) VALUES(?,?,?,?, 'admin',1,?)", parameters: [.text(name), .blob(secured.hash), .blob(secured.salt), .integer(Int64(PasswordHasher.iterations)), .real(Date().timeIntervalSince1970)])
            let user = try loadUser(database.lastInsertID)
            try audit.record(userID: user.id, action: "Administrator setup", entity: "User \(user.id)", details: "First administrator created.")
            return issue(user)
        }
    }
    public func login(username: String, password: String) throws -> Session {
        try database.withExclusiveAccess {
            let name = username.trimmingCharacters(in: .whitespacesAndNewlines), key = name.lowercased(), now = Date()
            if let failure = failures[key], failure.count >= 5, now.timeIntervalSince(failure.since) < 60 {
                throw SpotError.validation("Too many sign-in attempts. Please wait one minute and try again.")
            }
            let row = try database.query(sql: "SELECT * FROM users WHERE username = ? COLLATE NOCASE", parameters: [.text(name)]).first
            let valid: Bool
            if let row, row.int("is_active") == 1 {
                valid = try PasswordHasher.verify(password, hash: row.data("password_hash"), salt: row.data("password_salt"), rounds: Int(row.int("password_iterations")))
            } else {
                // Keep unknown-account work comparable to a normal password check.
                _ = try PasswordHasher.verify(password, hash: Data(repeating: 0, count: 32), salt: Data(repeating: 0, count: 32), rounds: PasswordHasher.iterations)
                valid = false
            }
            guard valid, let row else {
                let previous = failures[key]
                failures[key] = previous.map { now.timeIntervalSince($0.since) < 60 ? ($0.count + 1, $0.since) : (1, now) } ?? (1, now)
                throw SpotError.validation("Username or password is incorrect.")
            }
            failures[key] = nil
            let user = try userFromRow(row)
            try audit.record(userID: user.id, action: "Login", entity: "User \(user.id)", details: "\(user.role.rawValue.capitalized) signed in.")
            return issue(user)
        }
    }
    public func logout(_ session: Session) { database.withExclusiveAccess { tokens[session.token] = nil } }
    public func invalidateAllSessions() { database.withExclusiveAccess { tokens.removeAll(); failures.removeAll() } }
    public func authorize(_ session: Session, admin: Bool = false) throws -> User {
        try database.withExclusiveAccess {
            guard let id = tokens[session.token], id == session.user.id else { throw SpotError.unauthenticated }
            let user: User
            do { user = try loadUser(id) } catch SpotError.notFound { tokens[session.token] = nil; throw SpotError.unauthenticated }
            guard user.isActive else { tokens[session.token] = nil; throw SpotError.unauthenticated }
            guard !admin || user.role == .admin else { throw SpotError.forbidden }
            return user
        }
    }
    public func users(session: Session) throws -> [User] {
        try database.withExclusiveAccess {
            _ = try authorize(session, admin: true)
            return try database.query(sql: "SELECT id,username,role,is_active FROM users ORDER BY username COLLATE NOCASE").map(userFromRow)
        }
    }
    public func saveUser(session: Session, id: Int64?, username: String, password: String?, role: Role, isActive: Bool) throws -> User {
        try database.transaction {
            let actor = try authorize(session, admin: true), name = try validUsername(username)
            if let id {
                let previous = try loadUser(id)
                if previous.role == .admin && previous.isActive && (role != .admin || !isActive) {
                    guard try database.scalarInt(sql: "SELECT COUNT(*) FROM users WHERE role='admin' AND is_active=1") > 1 else {
                        throw SpotError.validation("Keep at least one active administrator account.")
                    }
                }
                try ensureUnique(name, excluding: id)
                try database.execute(sql: "UPDATE users SET username=?,role=?,is_active=? WHERE id=?", parameters: [.text(name), .text(role.rawValue), .integer(isActive ? 1 : 0), .integer(id)])
                if let password, !password.isEmpty { try setPassword(id: id, password: password) }
                try audit.record(userID: actor.id, action: "User changed", entity: "User \(id)", details: "Account \(name); role \(role.rawValue); active \(isActive).")
                tokens = tokens.filter { $0.value != id }
                return try loadUser(id)
            }
            guard let password, !password.isEmpty else { throw SpotError.validation("A password is required for a new account.") }
            try ensureUnique(name, excluding: nil)
            let secured = try PasswordHasher.create(password)
            try database.execute(sql: "INSERT INTO users(username,password_hash,password_salt,password_iterations,role,is_active,created_at) VALUES(?,?,?,?,?,?,?)", parameters: [.text(name), .blob(secured.hash), .blob(secured.salt), .integer(Int64(PasswordHasher.iterations)), .text(role.rawValue), .integer(isActive ? 1 : 0), .real(Date().timeIntervalSince1970)])
            let user = try loadUser(database.lastInsertID)
            try audit.record(userID: actor.id, action: "User created", entity: "User \(user.id)", details: "Account \(name); role \(role.rawValue).")
            return user
        }
    }
    public func changePassword(session: Session, currentPassword: String, newPassword: String) throws {
        try database.transaction {
            let user = try authorize(session)
            guard let row = try database.query(sql: "SELECT * FROM users WHERE id=?", parameters: [.integer(user.id)]).first,
                  try PasswordHasher.verify(currentPassword, hash: row.data("password_hash"), salt: row.data("password_salt"), rounds: Int(row.int("password_iterations"))) else {
                throw SpotError.validation("The current password is incorrect.")
            }
            try setPassword(id: user.id, password: newPassword)
            try audit.record(userID: user.id, action: "Password changed", entity: "User \(user.id)", details: "Account password changed; other sessions invalidated.")
            tokens = tokens.filter { $0.value != user.id || $0.key == session.token }
        }
    }
    private func setPassword(id: Int64, password: String) throws {
        let secured = try PasswordHasher.create(password)
        try database.execute(sql: "UPDATE users SET password_hash=?,password_salt=?,password_iterations=? WHERE id=?", parameters: [.blob(secured.hash), .blob(secured.salt), .integer(Int64(PasswordHasher.iterations)), .integer(id)])
    }
    private func issue(_ user: User) -> Session { let token = UUID(); tokens[token] = user.id; return Session(token: token, user: user) }
    private func loadUser(_ id: Int64) throws -> User {
        guard let row = try database.query(sql: "SELECT id,username,role,is_active FROM users WHERE id=?", parameters: [.integer(id)]).first else { throw SpotError.notFound }
        return try userFromRow(row)
    }
    private func userFromRow(_ row: SQLRow) throws -> User {
        guard let role = Role(rawValue: row.string("role")) else { throw SpotError.database("Invalid account role.") }
        return User(id: row.int("id"), username: row.string("username"), role: role, isActive: row.int("is_active") == 1)
    }
    private func validUsername(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$"#, options: .regularExpression) != nil else { throw SpotError.validation("Username must be 3–64 letters, digits, dots, underscores or hyphens and start with a letter or digit.") }
        return value
    }
    private func ensureUnique(_ name: String, excluding id: Int64?) throws {
        let count = try database.scalarInt(sql: "SELECT COUNT(*) FROM users WHERE username=? COLLATE NOCASE AND id != ?", parameters: [.text(name), .integer(id ?? 0)])
        guard count == 0 else { throw SpotError.conflict("That username is already in use.") }
    }
}
