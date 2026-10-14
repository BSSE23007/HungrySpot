import Foundation

public final class PaymentService {
    private let database: Database
    private let auth: AuthenticationService
    private let orders: OrderService
    private let audit: AuditService

    public init(database: Database, auth: AuthenticationService, orders: OrderService) {
        self.database = database; self.auth = auth; self.orders = orders; self.audit = AuditService(database: database)
    }

    /// `amount` is the exact order total. Cash tender is used only for validation/change and audit.
    /// Existing callers that omit cashTendered are treated as tendering exact cash.
    public func pay(session: Session, orderID: Int64, method: PaymentMethod, amount: Money, cashTendered: Money? = nil) throws -> OrderRecord {
        try database.transaction {
            let user = try auth.authorize(session)
            try ServiceValidation.amount(amount, label: "Payment amount")
            let order = try orders.order(session: session, id: orderID)
            guard amount == order.quote.total else { throw SpotError.validation("Record the exact order total as the payment amount. Enter cash received separately.") }
            var cashQuote: CashPaymentQuote?
            if method == .cash {
                let quote = try CashPaymentQuote(total: order.quote.total, tendered: cashTendered ?? amount)
                guard quote.canConfirm else { throw SpotError.validation("Customer paid is short by \(MoneyFormat.string(quote.shortage)).") }
                cashQuote = quote
            } else if cashTendered != nil {
                throw SpotError.validation("Cash received applies only to cash payments.")
            }
            if let existing = order.payment {
                guard existing.amount == amount, existing.method == method else { throw SpotError.conflict("This order has already been paid with different payment details.") }
                return order
            }
            guard order.status == .paymentPending else { throw SpotError.conflict("Move the order to Payment pending before recording payment.") }
            try database.execute(sql: "INSERT INTO payments(order_id, amount, method, cashier_id, created_at) VALUES(?, ?, ?, ?, ?)", parameters: [.integer(orderID), .integer(amount), .text(method.rawValue), .integer(user.id), .real(Date().timeIntervalSince1970)])
            try database.execute(sql: "UPDATE orders SET status = ? WHERE id = ?", parameters: [.text(OrderStatus.completed.rawValue), .integer(orderID)])
            var paymentDetails = "\(method.rawValue), \(MoneyFormat.string(amount))"
            if let quote = cashQuote { paymentDetails += "; tendered \(MoneyFormat.string(quote.tendered)); change \(MoneyFormat.string(quote.change))" }
            try audit.record(userID: user.id, action: "Payment recorded", entity: "Order \(order.number)", details: paymentDetails)
            try audit.record(userID: user.id, action: "Order completed", entity: "Order \(order.number)", details: "PAYMENT PENDING → COMPLETED after successful payment")
            return try orders.order(session: session, id: orderID)
        }
    }
}
