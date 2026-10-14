import Foundation

public final class AuditService {
    private let database: Database
    public init(database: Database) { self.database = database }
    public func record(userID: Int64?, action: String, entity: String, details: String) throws {
        try database.withExclusiveAccess {
            let username: String
            if let userID {
                username = try database.query(sql: "SELECT username FROM users WHERE id = ?", parameters: [.integer(userID)]).first?.string("username") ?? "Unknown"
            } else { username = "System" }
            try database.execute(sql: "INSERT INTO audit_logs(user_id,username,action,entity,details,created_at) VALUES(?,?,?,?,?,?)", parameters: [userID.map(SQLValue.integer) ?? .null, .text(username), .text(action), .text(entity), .text(details), .real(Date().timeIntervalSince1970)])
        }
    }
}
