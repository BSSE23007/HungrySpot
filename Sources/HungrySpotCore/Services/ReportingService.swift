import Foundation

public final class ReportingService {
    private let database: Database
    private let auth: AuthenticationService
    public init(database: Database, auth: AuthenticationService) { self.database = database; self.auth = auth }

    /// Collections belong to the payment date, even when the order is later completed.
    /// Category/product amounts are net of an exactly allocated discount; delivery is separate.
    public func summary(session: Session, from: Date, to: Date) throws -> ReportSummary {
        try database.transaction {
            _ = try auth.authorize(session, admin: true)
            try ServiceValidation.dateRange(from: from, to: to)
            let range: [SQLValue] = [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]
            let collected = try database.query(sql: """
                SELECT o.id, o.type, o.subtotal, o.delivery_charge, o.discount, o.total, p.amount, p.created_at
                FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE p.created_at >= ? AND p.created_at < ? AND o.status IN ('PAID', 'COMPLETED')
                ORDER BY p.created_at, o.id
                """, parameters: range)
            let itemRows = try database.query(sql: """
                SELECT i.* FROM order_items i JOIN orders o ON o.id = i.order_id JOIN payments p ON p.order_id = o.id
                WHERE p.created_at >= ? AND p.created_at < ? AND o.status IN ('PAID', 'COMPLETED')
                ORDER BY i.order_id, i.id
                """, parameters: range)
            let groupedItems = Dictionary(grouping: itemRows, by: { $0.int("order_id") })
            var result = ReportSummary()
            var products: [String: ReportRow] = [:]
            var categories: [String: ReportRow] = [:]
            var days: [String: ReportRow] = [:]
            let dayFormat = DateFormatter(); dayFormat.locale = Locale(identifier: "en_US_POSIX")
            dayFormat.calendar = Calendar(identifier: .gregorian); dayFormat.timeZone = .current; dayFormat.dateFormat = "yyyy-MM-dd"
            for order in collected {
                let subtotal = order.int("subtotal"), discount = order.int("discount"), delivery = order.int("delivery_charge"), amount = order.int("amount")
                try ServiceValidation.amount(subtotal, label: "Stored subtotal")
                try ServiceValidation.amount(discount, label: "Stored discount")
                try ServiceValidation.amount(delivery, label: "Stored delivery charge")
                try ServiceValidation.amount(amount, label: "Stored payment")
                guard discount <= subtotal, amount == (try ServiceValidation.add(subtotal, delivery)) - discount, amount == order.int("total") else { throw SpotError.database("A collected order has inconsistent totals.") }
                result.sales = try ServiceValidation.add(result.sales, amount)
                result.orderCount += 1
                if order.string("type") == OrderType.delivery.rawValue { result.deliveryOrders += 1 }
                result.deliveryCharges = try ServiceValidation.add(result.deliveryCharges, delivery)
                let day = dayFormat.string(from: Date(timeIntervalSince1970: order.double("created_at")))
                try accumulate(&days, name: day, quantity: 1, amount: amount)
                let items = groupedItems[order.int("id")] ?? []
                guard !items.isEmpty else { throw SpotError.database("A collected order has no line items.") }
                var lineAmounts: [Money] = []
                var calculatedSubtotal: Money = 0
                for item in items {
                    let quantity = item.int("quantity")
                    guard (1...999).contains(quantity) else { throw SpotError.database("A collected item has an invalid quantity.") }
                    try ServiceValidation.amount(item.int("unit_price"), label: "Stored item price")
                    try ServiceValidation.amount(item.int("extra_price"), label: "Stored extras price")
                    let gross = try ServiceValidation.multiply(ServiceValidation.add(item.int("unit_price"), item.int("extra_price")), by: Int(quantity))
                    calculatedSubtotal = try ServiceValidation.add(calculatedSubtotal, gross)
                    lineAmounts.append(gross)
                }
                guard calculatedSubtotal == subtotal else { throw SpotError.database("A collected order does not match its line items.") }
                let discounts = try allocatedDiscount(discount, amounts: lineAmounts, subtotal: subtotal)
                for (index, item) in items.enumerated() {
                    let quantity = Int(item.int("quantity"))
                    let (count, overflow) = result.productsSold.addingReportingOverflow(quantity)
                    guard !overflow else { throw SpotError.validation("The report quantity is too large.") }
                    result.productsSold = count
                    let net = lineAmounts[index] - discounts[index]
                    try accumulate(&products, name: item.string("product_name"), quantity: quantity, amount: net)
                    try accumulate(&categories, name: item.string("category_name"), quantity: quantity, amount: net)
                }
            }
            for expense in try database.query(sql: "SELECT amount FROM expenses WHERE expense_date >= ? AND expense_date < ?", parameters: range) {
                let amount = expense.int("amount")
                try ServiceValidation.amount(amount, label: "Stored expense", positive: true)
                result.expenses = try ServiceValidation.add(result.expenses, amount)
            }
            result.topProducts = Array(products.values.sorted(by: performanceOrder).prefix(10))
            result.categories = categories.values.sorted(by: performanceOrder)
            result.dailySales = days.values.sorted { $0.name < $1.name }
            return result
        }
    }

    private func performanceOrder(_ lhs: ReportRow, _ rhs: ReportRow) -> Bool {
        lhs.amount == rhs.amount ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : lhs.amount > rhs.amount
    }

    private func accumulate(_ rows: inout [String: ReportRow], name: String, quantity: Int, amount: Money) throws {
        var row = rows[name] ?? ReportRow(name: name, quantity: 0, amount: 0)
        let (count, overflow) = row.quantity.addingReportingOverflow(quantity)
        guard !overflow else { throw SpotError.validation("The report quantity is too large.") }
        row.quantity = count; row.amount = try ServiceValidation.add(row.amount, amount); rows[name] = row
    }

    /// Largest-remainder allocation preserves every paisa, with stable line-order tie breaking.
    /// Full-width multiplication avoids overflow when two valid monetary amounts are multiplied.
    private func allocatedDiscount(_ discount: Money, amounts: [Money], subtotal: Money) throws -> [Money] {
        guard discount > 0, subtotal > 0 else { return amounts.map { _ in 0 } }
        var allocated: [Money] = [], remainders: [UInt64] = []
        var sum: Money = 0
        for amount in amounts {
            let wide = UInt64(amount).multipliedFullWidth(by: UInt64(discount))
            let divided = UInt64(subtotal).dividingFullWidth(wide)
            let share = Money(divided.quotient)
            allocated.append(share); remainders.append(divided.remainder)
            sum = try ServiceValidation.add(sum, share)
        }
        let remaining = discount - sum
        guard remaining >= 0, remaining <= Money(amounts.count) else { throw SpotError.database("Could not allocate the saved discount.") }
        let priority = amounts.indices.sorted { remainders[$0] == remainders[$1] ? $0 < $1 : remainders[$0] > remainders[$1] }
        for index in priority.prefix(Int(remaining)) { allocated[index] += 1 }
        return allocated
    }
}
