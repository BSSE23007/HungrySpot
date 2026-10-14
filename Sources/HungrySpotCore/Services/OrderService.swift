import Foundation

public final class OrderService {
    private let database: Database
    private let auth: AuthenticationService
    private let pricing: PricingService
    private let audit: AuditService

    public init(database: Database, auth: AuthenticationService, catalog: CatalogService) {
        self.database = database; self.auth = auth
        self.pricing = PricingService(catalog: catalog); self.audit = AuditService(database: database)
    }

    public func punch(session: Session, draft: OrderDraft) throws -> OrderRecord {
        try database.transaction {
            let user = try auth.authorize(session)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let payload = String(decoding: try encoder.encode(draft), as: UTF8.self)
            if let existing = try database.query(sql: "SELECT id, request_payload, cashier_id FROM orders WHERE request_id = ?", parameters: [.text(draft.requestID.uuidString)]).first {
                guard existing.string("request_payload") == payload else { throw SpotError.conflict("This order request was already saved with different contents. Start a new order.") }
                guard existing.int("cashier_id") == user.id || user.role == .admin else { throw SpotError.forbidden }
                return try load(id: existing.int("id"))
            }
            guard !draft.lines.isEmpty else { throw SpotError.validation("Add at least one item before punching the order.") }
            let delivery = draft.type == .delivery
            let customerName = try ServiceValidation.text(draft.customerName, label: "Customer name", maximum: 200, required: delivery)
            let customerPhone: String
            if delivery { customerPhone = try PakistanMobileNumber.normalized(draft.customerPhone) }
            else { customerPhone = try ServiceValidation.text(draft.customerPhone, label: "Customer phone", maximum: 50) }
            let customerAddress = try ServiceValidation.text(draft.customerAddress, label: "Customer address", maximum: 1_000, required: delivery)
            let notes = try ServiceValidation.text(draft.notes, label: "Order notes", maximum: 2_000)
            let quote = try pricing.calculate(session: session, draft: draft)
            let now = Date()
            try database.execute(sql: """
                INSERT INTO orders(request_id, request_payload, order_number, type, status, created_at, cashier_id, cashier_name,
                customer_name, customer_phone, customer_address, notes, cancellation_reason, subtotal, delivery_charge, discount, total)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, parameters: [.text(draft.requestID.uuidString), .text(payload), .text("PENDING-\(draft.requestID.uuidString)"),
                    .text(draft.type.rawValue), .text(OrderStatus.punched.rawValue), .real(now.timeIntervalSince1970), .integer(user.id), .text(user.username),
                    .text(customerName), .text(customerPhone), .text(customerAddress), .text(notes), .text(""),
                    .integer(quote.subtotal), .integer(quote.deliveryCharge), .integer(quote.discount), .integer(quote.total)])
            let orderID = database.lastInsertID
            let orderNumber = String(format: "HS-%06lld", orderID)
            try database.execute(sql: "UPDATE orders SET order_number = ? WHERE id = ?", parameters: [.text(orderNumber), .integer(orderID)])
            for item in quote.items {
                try database.execute(sql: """
                    INSERT INTO order_items(order_id, product_id, product_name, category_name, variant_name, unit_price, extra_price, quantity, notes)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, parameters: [.integer(orderID), .integer(item.productID), .text(item.productName), .text(item.categoryName),
                        item.variantName.map(SQLValue.text) ?? .null, .integer(item.unitPrice), .integer(item.extraPrice), .integer(Int64(item.quantity)), .text(item.notes)])
                let itemID = database.lastInsertID
                for option in item.options {
                    try database.execute(sql: """
                        INSERT INTO order_item_options(order_item_id, name, quantity, unit_price, product_id, variant_id)
                        VALUES(?, ?, ?, ?, ?, ?)
                        """, parameters: [.integer(itemID), .text(option.name), .integer(Int64(option.quantity)), .integer(option.unitPrice),
                            option.productID.map(SQLValue.integer) ?? .null, option.variantID.map(SQLValue.integer) ?? .null])
                }
            }
            try audit.record(userID: user.id, action: "Order punched", entity: "Order \(orderNumber)", details: "Total \(MoneyFormat.string(quote.total)); \(draft.type.rawValue)")
            return try load(id: orderID)
        }
    }

    /// Date bounds use creation timestamps, including the start and excluding the end.
    /// Omit both bounds for all dates; the Orders screen supplies the Mac's local day by default.
    public func orders(session: Session, search: String = "", activeOnly: Bool = false, type: OrderType? = nil, payment: OrderPaymentFilter = .all, from: Date? = nil, to: Date? = nil, limit: Int = 200, offset: Int = 0) throws -> [OrderRecord] {
        try database.transaction {
            _ = try auth.authorize(session)
            guard (1...500).contains(limit), offset >= 0 else { throw SpotError.validation("Invalid order page.") }
            let term = try ServiceValidation.text(search, label: "Search", maximum: 200)
            var sql = "SELECT id FROM orders WHERE 1 = 1"
            var parameters: [SQLValue] = []
            if activeOnly { sql += " AND status NOT IN ('COMPLETED', 'CANCELLED')" }
            if let type = type {
                sql += " AND type = ?"
                parameters.append(.text(type.rawValue))
            }
            switch payment {
            case .all: break
            case .paymentPending:
                sql += " AND status = ? AND NOT EXISTS (SELECT 1 FROM payments p WHERE p.order_id = orders.id)"
                parameters.append(.text(OrderStatus.paymentPending.rawValue))
            case .paid:
                sql += " AND status IN ('PAID', 'COMPLETED') AND EXISTS (SELECT 1 FROM payments p WHERE p.order_id = orders.id AND p.amount = orders.total)"
            case .cancelled:
                sql += " AND status = ?"
                parameters.append(.text(OrderStatus.cancelled.rawValue))
            }
            if let from = from, let to = to {
                try ServiceValidation.dateRange(from: from, to: to)
                sql += " AND created_at >= ? AND created_at < ?"
                parameters += [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]
            } else if from != nil || to != nil {
                throw SpotError.validation("Choose both the start and end of the order date range.")
            }
            if !term.isEmpty {
                sql += " AND (instr(lower(order_number), lower(?)) > 0 OR instr(lower(customer_name), lower(?)) > 0 OR instr(customer_phone, ?) > 0)"
                parameters += [.text(term), .text(term), .text(term)]
            }
            sql += " ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?"
            parameters += [.integer(Int64(limit)), .integer(Int64(offset))]
            return try database.query(sql: sql, parameters: parameters).map { try load(id: $0.int("id")) }
        }
    }

    public func order(session: Session, id: Int64) throws -> OrderRecord {
        try database.transaction {
            _ = try auth.authorize(session)
            return try load(id: id)
        }
    }

    public func transition(session: Session, id: Int64, to status: OrderStatus, reason: String = "") throws -> OrderRecord {
        try database.transaction {
            let user = try auth.authorize(session)
            let current = try load(id: id)
            if current.status == status { return current }
            var cancellationReason = ""
            if status == .cancelled {
                guard [.punched, .preparing, .ready, .paymentPending].contains(current.status), current.payment == nil else {
                    throw SpotError.conflict("Paid, completed and cancelled orders cannot be cancelled.")
                }
                cancellationReason = try ServiceValidation.text(reason, label: "Cancellation reason", maximum: 1_000, required: true)
            } else {
                let allowed: Bool
                switch (current.status, status) {
                case (.punched, .paymentPending), (.preparing, .paymentPending), (.ready, .paymentPending), (.paid, .completed): allowed = true
                default: allowed = false
                }
                guard allowed else { throw SpotError.conflict("That order status change is not allowed. Move an unpaid order to Payment pending, then record payment to complete it.") }
            }
            try database.execute(sql: "UPDATE orders SET status = ?, cancellation_reason = ? WHERE id = ?", parameters: [.text(status.rawValue), .text(cancellationReason), .integer(id)])
            try audit.record(userID: user.id, action: status == .cancelled ? "Order cancelled" : "Order status changed", entity: "Order \(current.number)", details: "\(current.status.rawValue) → \(status.rawValue)\(cancellationReason.isEmpty ? "" : "; \(cancellationReason)")")
            return try load(id: id)
        }
    }

    private func load(id: Int64) throws -> OrderRecord {
        guard let row = try database.query(sql: "SELECT * FROM orders WHERE id = ?", parameters: [.integer(id)]).first else { throw SpotError.notFound }
        guard let type = OrderType(rawValue: row.string("type")), let status = OrderStatus(rawValue: row.string("status")) else { throw SpotError.database("This order contains an invalid type or status.") }
        let optionRows = try database.query(sql: """
            SELECT op.* FROM order_item_options op JOIN order_items i ON i.id = op.order_item_id
            WHERE i.order_id = ? ORDER BY op.id
            """, parameters: [.integer(id)])
        var optionsByItem: [Int64: [OptionSnapshot]] = [:]
        for option in optionRows {
            let quantity = option.int("quantity")
            guard quantity > 0, quantity <= 1_000 else { throw SpotError.database("An order option contains an invalid quantity.") }
            try ServiceValidation.amount(option.int("unit_price"), label: "Stored option price")
            optionsByItem[option.int("order_item_id"), default: []].append(OptionSnapshot(id: option.int("id"), name: option.string("name"), quantity: Int(quantity), unitPrice: option.int("unit_price"), productID: option.optionalInt("product_id"), variantID: option.optionalInt("variant_id")))
        }
        var items: [OrderItemSnapshot] = []
        var subtotal: Money = 0
        for item in try database.query(sql: "SELECT * FROM order_items WHERE order_id = ? ORDER BY id", parameters: [.integer(id)]) {
            let quantity = item.int("quantity")
            guard (1...999).contains(quantity) else { throw SpotError.database("An order item contains an invalid quantity.") }
            let unitPrice = item.int("unit_price"), extraPrice = item.int("extra_price")
            try ServiceValidation.amount(unitPrice, label: "Stored item price")
            try ServiceValidation.amount(extraPrice, label: "Stored extras price")
            let itemTotal = try ServiceValidation.multiply(ServiceValidation.add(unitPrice, extraPrice), by: Int(quantity))
            subtotal = try ServiceValidation.add(subtotal, itemTotal)
            let itemOptions = optionsByItem[item.int("id")] ?? []
            var optionsTotal: Money = 0
            for option in itemOptions { optionsTotal = try ServiceValidation.add(optionsTotal, ServiceValidation.multiply(option.unitPrice, by: option.quantity)) }
            guard optionsTotal == extraPrice else { throw SpotError.database("Stored item extras do not match their snapshots.") }
            items.append(OrderItemSnapshot(id: item.int("id"), productID: item.int("product_id"), productName: item.string("product_name"), categoryName: item.string("category_name"), variantName: item.optionalString("variant_name"), unitPrice: unitPrice, extraPrice: extraPrice, quantity: Int(quantity), notes: item.string("notes"), options: itemOptions))
        }
        let delivery = row.int("delivery_charge"), discount = row.int("discount")
        try ServiceValidation.amount(subtotal, label: "Stored subtotal")
        try ServiceValidation.amount(delivery, label: "Stored delivery charge")
        try ServiceValidation.amount(discount, label: "Stored discount")
        guard !items.isEmpty, discount <= subtotal, subtotal == row.int("subtotal"), type == .delivery || delivery == 0 else { throw SpotError.database("Stored order totals are inconsistent.") }
        let quote = Quote(items: items, subtotal: subtotal, deliveryCharge: delivery, discount: discount)
        let checkedTotal = try ServiceValidation.add(subtotal, delivery) - discount
        try ServiceValidation.amount(checkedTotal, label: "Stored order total")
        guard checkedTotal == row.int("total") else { throw SpotError.database("Stored order total does not match its items.") }
        var payment: Payment?
        if let p = try database.query(sql: "SELECT * FROM payments WHERE order_id = ?", parameters: [.integer(id)]).first {
            guard let method = PaymentMethod(rawValue: p.string("method")), p.int("amount") == checkedTotal else { throw SpotError.database("Stored payment does not match the order.") }
            payment = Payment(id: p.int("id"), orderID: id, amount: p.int("amount"), method: method, cashierID: p.int("cashier_id"), createdAt: Date(timeIntervalSince1970: p.double("created_at")))
        }
        guard (status == .paid || status == .completed) == (payment != nil) else { throw SpotError.database("Stored payment and order status are inconsistent.") }
        return OrderRecord(id: id, number: row.string("order_number"), type: type, status: status, createdAt: Date(timeIntervalSince1970: row.double("created_at")), cashierID: row.int("cashier_id"), cashierName: row.string("cashier_name"), customerName: row.string("customer_name"), customerPhone: row.string("customer_phone"), customerAddress: row.string("customer_address"), notes: row.string("notes"), cancellationReason: row.string("cancellation_reason"), quote: quote, payment: payment)
    }
}
