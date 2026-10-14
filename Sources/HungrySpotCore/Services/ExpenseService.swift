import Foundation

public final class ExpenseService {
    private let database: Database
    private let auth: AuthenticationService
    private let audit: AuditService
    public init(database: Database, auth: AuthenticationService) {
        self.database = database; self.auth = auth; self.audit = AuditService(database: database)
    }

    public func expenses(session: Session, from: Date, to: Date) throws -> [Expense] {
        try database.transaction {
            _ = try auth.authorize(session, admin: true)
            try ServiceValidation.dateRange(from: from, to: to)
            return try database.query(sql: "SELECT id, expense_date, amount, description FROM expenses WHERE expense_date >= ? AND expense_date < ? ORDER BY expense_date DESC, id DESC", parameters: [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]).map {
                Expense(id: $0.int("id"), date: Date(timeIntervalSince1970: $0.double("expense_date")), amount: $0.int("amount"), description: $0.string("description"))
            }
        }
    }

    public func add(session: Session, expense: Expense) throws -> Expense {
        try database.transaction {
            let user = try auth.authorize(session, admin: true)
            guard expense.id == 0 else { throw SpotError.validation("Existing expenses cannot be overwritten. Add a new expense.") }
            guard expense.date.timeIntervalSince1970.isFinite else { throw SpotError.validation("Choose a valid expense date.") }
            try ServiceValidation.amount(expense.amount, label: "Expense amount", positive: true)
            let description = try ServiceValidation.text(expense.description, label: "Expense description", maximum: 1_000, required: true)
            try database.execute(sql: "INSERT INTO expenses(expense_date, amount, description, user_id) VALUES(?, ?, ?, ?)", parameters: [.real(expense.date.timeIntervalSince1970), .integer(expense.amount), .text(description), .integer(user.id)])
            let result = Expense(id: database.lastInsertID, date: expense.date, amount: expense.amount, description: description)
            try audit.record(userID: user.id, action: "Expense added", entity: "Expense \(result.id)", details: "\(description): \(MoneyFormat.string(expense.amount))")
            return result
        }
    }
}
