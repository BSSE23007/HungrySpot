import Foundation
import XCTest
@testable import HungrySpotCore

final class CommerceTests: XCTestCase {
    private var database: Database!
    private var auth: AuthenticationService!
    private var catalog: CatalogService!
    private var pricing: PricingService!
    private var orders: OrderService!
    private var payments: PaymentService!
    private var reports: ReportingService!
    private var expenses: ExpenseService!
    private var admin: Session!

    override func setUpWithError() throws {
        database = try Database(path: ":memory:")
        try database.bootstrap()
        auth = AuthenticationService(database: database)
        admin = try auth.setupAdmin(username: "owner", password: "A-strong-test-password-42!")
        catalog = CatalogService(database: database, auth: auth)
        pricing = PricingService(catalog: catalog)
        orders = OrderService(database: database, auth: auth, catalog: catalog)
        payments = PaymentService(database: database, auth: auth, orders: orders)
        reports = ReportingService(database: database, auth: auth)
        expenses = ExpenseService(database: database, auth: auth)
    }

    override func tearDownWithError() throws { try database.close() }

    private func product(_ name: String) throws -> Product {
        try XCTUnwrap(catalog.products(session: admin, includeInactive: true).first { $0.name == name }, "Missing seeded product: \(name)")
    }
    private func variant(_ product: Product, _ name: String) throws -> ProductVariant {
        try XCTUnwrap(product.variants.first { $0.name == name }, "Missing variant: \(name)")
    }
    private func burgerDraft(quantity: Int = 1) throws -> OrderDraft {
        OrderDraft(lines: [CartLine(productID: try product("Zinger Burger").id, quantity: quantity)])
    }
    private func pending(_ draft: OrderDraft) throws -> OrderRecord {
        let order = try orders.punch(session: admin, draft: draft)
        return try orders.transition(session: admin, id: order.id, to: .paymentPending)
    }
    private func cashier() throws -> Session {
        _ = try auth.saveUser(session: admin, id: nil, username: "cashier", password: "A-strong-cashier-password-42!", role: .cashier, isActive: true)
        return try auth.login(username: "cashier", password: "A-strong-cashier-password-42!")
    }
    private func allSales() throws -> ReportSummary {
        try reports.summary(session: admin, from: .distantPast, to: .distantFuture)
    }
    private func pizzaBundle(quantity: Int = 2) throws -> (Product, Deal, Product, ProductVariant) {
        let pizza = try product("Chicken Tikka"), large = try variant(pizza, "Large")
        let category = try XCTUnwrap(catalog.categories(session: admin).first { $0.name == "Deals" })
        let bundle = try catalog.saveProduct(session: admin, product: Product(name: "Test pizza bundle", categoryID: category.id, kind: .deal, basePrice: 200_000))
        try catalog.saveDeal(session: admin, deal: Deal(productID: bundle.id, slots: [DealSlot(label: "Pizza", quantity: quantity, requiresSelection: true, choices: [DealChoice(productID: pizza.id, variantID: large.id)])]))
        return (bundle, try catalog.deal(session: admin, productID: bundle.id), pizza, large)
    }

    func testEmptyPreviewButCannotPunchEmptyOrder() throws {
        XCTAssertEqual(try pricing.calculate(session: admin, draft: OrderDraft()).total, 0)
        XCTAssertThrowsError(try orders.punch(session: admin, draft: OrderDraft()))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM orders"), 0)
    }

    func testPizzaSizePricesAndMultipleToppingsAndDip() throws {
        let pizza = try product("Chicken Tikka")
        for (size, base, topping) in [("Small", Money(50_000), Money(5_000)), ("Medium", 90_000, 10_000), ("Large", 125_000, 15_000)] {
            let selected = try variant(pizza, size)
            let quote = try pricing.calculate(session: admin, draft: OrderDraft(lines: [CartLine(productID: pizza.id, variantID: selected.id, quantity: 2, toppingQuantity: 2, dipSauce: true)]))
            XCTAssertEqual(quote.items[0].unitPrice, base)
            XCTAssertEqual(quote.items[0].extraPrice, 2 * topping + 5_000)
            XCTAssertEqual(quote.total, 2 * (base + 2 * topping + 5_000))
            XCTAssertEqual(quote.items[0].options.first { $0.name == "Extra Topping" }?.quantity, 2)
        }
    }

    func testCrownAndLasagniaHaveNoSmallAndRejectForeignVariant() throws {
        let small = try variant(product("Chicken Tikka"), "Small")
        for name in ["Crown Crust", "Lasagnia Pizza"] {
            let pizza = try product(name)
            XCTAssertEqual(Set(pizza.variants.map(\.name)), Set(["Medium", "Large"]))
            XCTAssertThrowsError(try pricing.calculate(session: admin, draft: OrderDraft(lines: [CartLine(productID: pizza.id, variantID: small.id)])))
        }
    }

    func testPizzaRequiresVariantAndNormalProductRejectsPizzaExtras() throws {
        let pizza = try product("Chicken Tikka"), burger = try product("Zinger Burger")
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: OrderDraft(lines: [CartLine(productID: pizza.id)])))
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: OrderDraft(lines: [CartLine(productID: burger.id, toppingQuantity: 1)])))
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: OrderDraft(lines: [CartLine(productID: burger.id, dipSauce: true)])))
    }

    func testArbitraryPizzaSizeNeedsExplicitToppingPrice() throws {
        var pizza = try product("Chicken Tikka")
        pizza.variants.append(ProductVariant(productID: pizza.id, name: "Party", price: 200_000))
        pizza = try catalog.saveProduct(session: admin, product: pizza)
        let party = try variant(pizza, "Party")
        XCTAssertEqual(try pricing.calculate(session: admin, draft: OrderDraft(lines: [CartLine(productID: pizza.id, variantID: party.id)])).total, 200_000)
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: OrderDraft(lines: [CartLine(productID: pizza.id, variantID: party.id, toppingQuantity: 1)])))
    }

    func testAvailabilityRevalidatedAtPunchAfterPreview() throws {
        let draft = try burgerDraft()
        XCTAssertEqual(try pricing.calculate(session: admin, draft: draft).total, 35_000)
        var burger = try product("Zinger Burger"); burger.isAvailable = false
        _ = try catalog.saveProduct(session: admin, product: burger)
        XCTAssertThrowsError(try orders.punch(session: admin, draft: draft))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM orders"), 0)
    }

    func testDisabledAncestorAndUnavailableVariantRejected() throws {
        let pizza = try product("Chicken Tikka"), medium = try variant(pizza, "Medium")
        let draft = OrderDraft(lines: [CartLine(productID: pizza.id, variantID: medium.id)])
        try database.execute(sql: "UPDATE product_variants SET is_available = 0 WHERE id = ?", parameters: [.integer(medium.id)])
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: draft))
        try database.execute(sql: "UPDATE product_variants SET is_available = 1 WHERE id = ?", parameters: [.integer(medium.id)])
        try database.execute(sql: "UPDATE categories SET is_active = 0 WHERE id = ?", parameters: [.integer(pizza.categoryID)])
        XCTAssertThrowsError(try orders.punch(session: admin, draft: draft))
    }

    func testAmountsAndQuantitiesCannotOverflow() throws {
        var draft = try burgerDraft(quantity: Int.max)
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: draft))
        draft.lines[0].quantity = 0
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: draft))
        draft.lines[0].quantity = 1; draft.deliveryCharge = Int64.max; draft.type = .delivery
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: draft))
        draft.deliveryCharge = 0; draft.discount = -1
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: draft))
        XCTAssertThrowsError(try ServiceValidation.add(Int64.max, 1))
        XCTAssertThrowsError(try ServiceValidation.multiply(Int64.max, by: 2))
        var burger = try product("Zinger Burger"); burger.basePrice = ServiceValidation.maximumAmount
        _ = try catalog.saveProduct(session: admin, product: burger)
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: burgerDraft(quantity: 2)))
    }

    func testDeliveryValidationTotalsAndDiscountBound() throws {
        var draft = try burgerDraft(quantity: 2)
        draft.type = .delivery; draft.deliveryCharge = 10_000; draft.discount = 5_000
        XCTAssertEqual(try pricing.calculate(session: admin, draft: draft).total, 75_000)
        XCTAssertThrowsError(try orders.punch(session: admin, draft: draft))
        draft.customerName = " Customer "; draft.customerPhone = "03301234567"; draft.customerAddress = "Street 1"
        let order = try orders.punch(session: admin, draft: draft)
        XCTAssertEqual(order.customerName, "Customer"); XCTAssertEqual(order.quote.subtotal, 70_000)
        XCTAssertEqual(order.quote.deliveryCharge, 10_000); XCTAssertEqual(order.quote.total, 75_000)
        draft.requestID = UUID(); draft.discount = 70_001
        XCTAssertThrowsError(try orders.punch(session: admin, draft: draft))
        draft.discount = 0; draft.type = .takeaway
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: draft))
    }

    func testCashierDiscountUsesPersistedRoleAndAdminSetting() throws {
        let session = try cashier()
        let forgedUser = User(id: session.user.id, username: session.user.username, role: .admin)
        let forged = Session(token: session.token, user: forgedUser)
        var draft = try burgerDraft(); draft.discount = 500
        XCTAssertThrowsError(try pricing.calculate(session: forged, draft: draft))
        var settings = try catalog.settings(session: admin); settings.cashierCanDiscount = true
        try catalog.saveSettings(session: admin, settings: settings)
        XCTAssertEqual(try pricing.calculate(session: session, draft: draft).total, 34_500)
    }

    func testDealFixedPriceAndEveryPizzaExtrasAreIndependent() throws {
        let (bundle, deal, pizza, large) = try pizzaBundle()
        let slot = try XCTUnwrap(deal.slots.first)
        let choices = [DealSelection(slotID: slot.id, unitIndex: 0, productID: pizza.id, variantID: large.id, toppingQuantity: 2), DealSelection(slotID: slot.id, unitIndex: 1, productID: pizza.id, variantID: large.id, dipSauce: true)]
        let quote = try pricing.calculate(session: admin, draft: OrderDraft(lines: [CartLine(productID: bundle.id, quantity: 2, dealSelections: choices)]))
        XCTAssertEqual(quote.items[0].unitPrice, 200_000)
        XCTAssertEqual(quote.items[0].extraPrice, 35_000)
        XCTAssertEqual(quote.total, 470_000)
        XCTAssertEqual(quote.items[0].options.filter { $0.unitPrice == 0 }.count, 2)
        XCTAssertTrue(quote.items[0].options.contains { $0.name.contains("Pizza 1") && $0.name.contains("Extra Topping") })
        XCTAssertTrue(quote.items[0].options.contains { $0.name.contains("Pizza 2") && $0.name.contains("Dip Sauce") })
    }

    func testDealMissingDuplicateWrongAndOutOfRangeSelectionsRejected() throws {
        let (bundle, deal, pizza, large) = try pizzaBundle()
        let slot = try XCTUnwrap(deal.slots.first)
        let first = DealSelection(slotID: slot.id, unitIndex: 0, productID: pizza.id, variantID: large.id)
        let second = DealSelection(slotID: slot.id, unitIndex: 1, productID: pizza.id, variantID: large.id)
        let badVariant = try variant(pizza, "Medium")
        let bad = DealSelection(slotID: slot.id, unitIndex: 1, productID: pizza.id, variantID: badVariant.id)
        let outside = DealSelection(slotID: slot.id, unitIndex: 2, productID: pizza.id, variantID: large.id)
        for selections in [[], [first], [first, first], [first, bad], [first, second, outside]] {
            XCTAssertThrowsError(try pricing.calculate(session: admin, draft: OrderDraft(lines: [CartLine(productID: bundle.id, dealSelections: selections)])))
        }
        try database.execute(sql: "UPDATE products SET is_available = 0 WHERE id = ?", parameters: [.integer(pizza.id)])
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: OrderDraft(lines: [CartLine(productID: bundle.id, dealSelections: [first, second])])) )
    }

    func testDealsNeedingReviewCannotBeSold() throws {
        let bundles = try catalog.products(session: admin).filter { $0.kind == .deal }
        var reviewedCount = 0
        for bundle in bundles {
            let deal = try catalog.deal(session: admin, productID: bundle.id)
            if deal.needsReview {
                reviewedCount += 1
                XCTAssertThrowsError(try pricing.calculate(session: admin, draft: OrderDraft(lines: [CartLine(productID: bundle.id)])))
            }
        }
        XCTAssertGreaterThan(reviewedCount, 0)
    }

    func testPunchRecalculatesCatalogThenPreservesAllSnapshots() throws {
        var pizza = try product("Chicken Tikka"), medium = try variant(pizza, "Medium")
        let draft = OrderDraft(lines: [CartLine(productID: pizza.id, variantID: medium.id, toppingQuantity: 2, dipSauce: true)])
        XCTAssertEqual(try pricing.calculate(session: admin, draft: draft).total, 115_000)
        medium.price = 100_000
        pizza.variants = pizza.variants.map { $0.id == medium.id ? medium : $0 }
        _ = try catalog.saveProduct(session: admin, product: pizza)
        let saved = try orders.punch(session: admin, draft: draft)
        XCTAssertEqual(saved.quote.total, 125_000)
        pizza.name = "Renamed pizza"; pizza.variants = pizza.variants.map { var v = $0; v.price += 10_000; return v }
        _ = try catalog.saveProduct(session: admin, product: pizza)
        var settings = try catalog.settings(session: admin); settings.dipSaucePrice = 9_000
        try catalog.saveSettings(session: admin, settings: settings)
        let loaded = try orders.order(session: admin, id: saved.id)
        XCTAssertEqual(loaded.quote.total, 125_000)
        XCTAssertEqual(loaded.quote.items[0].productName, "Chicken Tikka")
        XCTAssertEqual(loaded.quote.items[0].variantName, "Medium")
        XCTAssertEqual(loaded.quote.items[0].options.first { $0.name == "Dip Sauce" }?.unitPrice, 5_000)
        XCTAssertThrowsError(try database.execute(sql: "DELETE FROM product_variants WHERE id = ?", parameters: [.integer(medium.id)]))
    }

    func testPunchRetryIsIdempotentAndChangedPayloadRejected() throws {
        let draft = try burgerDraft()
        let first = try orders.punch(session: admin, draft: draft)
        var burger = try product("Zinger Burger"); burger.basePrice = 40_000; burger.isAvailable = false
        _ = try catalog.saveProduct(session: admin, product: burger)
        let retry = try orders.punch(session: admin, draft: draft)
        XCTAssertEqual(first.id, retry.id); XCTAssertEqual(retry.quote.total, 35_000)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM orders"), 1)
        var changed = draft; changed.lines[0].quantity = 2
        XCTAssertThrowsError(try orders.punch(session: admin, draft: changed))
    }

    func testPunchRollsBackEveryRowOnInsertFailureAndCanRetry() throws {
        let draft = try burgerDraft()
        try database.execute(sql: "CREATE TRIGGER test_reject_item BEFORE INSERT ON order_items BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        XCTAssertThrowsError(try orders.punch(session: admin, draft: draft))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM orders"), 0)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM order_items"), 0)
        try database.execute(sql: "DROP TRIGGER test_reject_item")
        XCTAssertEqual(try orders.punch(session: admin, draft: draft).status, .punched)
    }

    func testStateMachineAndCancellationReason() throws {
        let order = try orders.punch(session: admin, draft: burgerDraft())
        XCTAssertThrowsError(try orders.transition(session: admin, id: order.id, to: .preparing))
        XCTAssertThrowsError(try orders.transition(session: admin, id: order.id, to: .ready))
        XCTAssertThrowsError(try orders.transition(session: admin, id: order.id, to: .paid))
        XCTAssertThrowsError(try orders.transition(session: admin, id: order.id, to: .completed))
        XCTAssertThrowsError(try orders.transition(session: admin, id: order.id, to: .cancelled))
        let cancelled = try orders.transition(session: admin, id: order.id, to: .cancelled, reason: "Customer cancelled")
        XCTAssertEqual(cancelled.cancellationReason, "Customer cancelled")
        XCTAssertThrowsError(try orders.transition(session: admin, id: order.id, to: .preparing))
        XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total))
        XCTAssertEqual(try allSales().sales, 0)
    }

    func testPaymentExactAmountPendingStateAndIdempotentRetry() throws {
        let order = try orders.punch(session: admin, draft: burgerDraft())
        XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: 35_000))
        XCTAssertEqual(try orders.transition(session: admin, id: order.id, to: .paymentPending).status, .paymentPending)
        XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: 34_999))
        XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: 35_001))
        XCTAssertEqual(try allSales().sales, 0)
        let paid = try payments.pay(session: admin, orderID: order.id, method: .cash, amount: 35_000)
        XCTAssertEqual(paid.status, .completed); XCTAssertEqual(paid.payment?.amount, 35_000)
        XCTAssertEqual(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: 35_000).payment?.id, paid.payment?.id)
        XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .card, amount: 35_000))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM payments"), 1)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM audit_logs WHERE action = 'Payment recorded'"), 1)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM audit_logs WHERE action = 'Order completed'"), 1)
        XCTAssertThrowsError(try orders.transition(session: admin, id: order.id, to: .cancelled, reason: "Not permitted"))
    }

    func testPaymentAndStatusRollBackTogetherWhenAuditFails() throws {
        let order = try pending(burgerDraft())
        try database.execute(sql: "CREATE TRIGGER test_reject_payment_audit BEFORE INSERT ON audit_logs WHEN NEW.action = 'Payment recorded' BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM payments"), 0)
        XCTAssertEqual(try orders.order(session: admin, id: order.id).status, .paymentPending)
        try database.execute(sql: "DROP TRIGGER test_reject_payment_audit")
        XCTAssertEqual(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total).status, .completed)
    }

    func testCompletedSalesStayCollectedAndUnpaidExcluded() throws {
        let paid = try pending(burgerDraft(quantity: 2))
        _ = try orders.punch(session: admin, draft: burgerDraft())
        XCTAssertEqual(try allSales().sales, 0)
        XCTAssertEqual(try payments.pay(session: admin, orderID: paid.id, method: .card, amount: paid.quote.total).status, .completed)
        XCTAssertEqual(try allSales().sales, 70_000)
        let report = try allSales()
        XCTAssertEqual(report.sales, 70_000); XCTAssertEqual(report.orderCount, 1); XCTAssertEqual(report.productsSold, 2)
        XCTAssertEqual(report.topProducts.first?.amount, 70_000)
        XCTAssertFalse(try orders.orders(session: admin, activeOnly: true).contains { $0.id == paid.id })
    }

    func testReportAllocatesDiscountPreciselyAndSeparatesDelivery() throws {
        let burger = try product("Zinger Burger"), drink = try product("500 ml")
        var draft = OrderDraft(type: .delivery, lines: [CartLine(productID: burger.id), CartLine(productID: drink.id)], customerName: "Customer", customerPhone: "03300000000", customerAddress: "Main Road", deliveryCharge: 5_000, discount: 1)
        let order = try pending(draft)
        _ = try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total)
        let report = try allSales()
        XCTAssertEqual(report.sales, 51_999); XCTAssertEqual(report.deliveryCharges, 5_000); XCTAssertEqual(report.deliveryOrders, 1)
        XCTAssertEqual(report.categories.reduce(0) { $0 + $1.amount }, 46_999)
        XCTAssertEqual(report.topProducts.reduce(0) { $0 + $1.amount }, 46_999)
        XCTAssertEqual(report.topProducts.first { $0.name == "Zinger Burger" }?.amount, 34_999)
        draft.requestID = UUID(); draft.discount = 47_000
        let freeFood = try pending(draft)
        _ = try payments.pay(session: admin, orderID: freeFood.id, method: .cash, amount: 5_000)
        XCTAssertEqual(try allSales().categories.reduce(0) { $0 + $1.amount }, 46_999)
    }

    func testReportRangeUsesPaymentDateAndHalfOpenBoundary() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000), end = start.addingTimeInterval(86_400)
        let first = try pending(burgerDraft()), second = try pending(burgerDraft())
        _ = try payments.pay(session: admin, orderID: first.id, method: .cash, amount: first.quote.total)
        _ = try payments.pay(session: admin, orderID: second.id, method: .cash, amount: second.quote.total)
        try database.execute(sql: "UPDATE payments SET created_at = ? WHERE order_id = ?", parameters: [.real(start.timeIntervalSince1970), .integer(first.id)])
        try database.execute(sql: "UPDATE payments SET created_at = ? WHERE order_id = ?", parameters: [.real(end.timeIntervalSince1970), .integer(second.id)])
        let report = try reports.summary(session: admin, from: start, to: end)
        XCTAssertEqual(report.orderCount, 1); XCTAssertEqual(report.sales, 35_000)
        XCTAssertEqual(report.dailySales.reduce(0) { $0 + $1.amount }, 35_000)
        XCTAssertThrowsError(try reports.summary(session: admin, from: end, to: start))
    }

    func testExpenseTotalsAndAdminOnlyServices() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000), end = start.addingTimeInterval(86_400)
        _ = try expenses.add(session: admin, expense: Expense(date: start, amount: 12_500, description: "Gas"))
        _ = try expenses.add(session: admin, expense: Expense(date: end, amount: 5_000, description: "Outside range"))
        XCTAssertEqual(try expenses.expenses(session: admin, from: start, to: end).count, 1)
        let report = try reports.summary(session: admin, from: start, to: end)
        XCTAssertEqual(report.expenses, 12_500); XCTAssertEqual(report.afterExpenses, -12_500)
        XCTAssertThrowsError(try expenses.add(session: admin, expense: Expense(amount: 0, description: "Invalid")))
        XCTAssertThrowsError(try expenses.add(session: admin, expense: Expense(amount: 100, description: " ")))
        let session = try cashier()
        XCTAssertThrowsError(try expenses.add(session: session, expense: Expense(amount: 100, description: "Forbidden")))
        XCTAssertThrowsError(try expenses.expenses(session: session, from: start, to: end))
        XCTAssertThrowsError(try reports.summary(session: session, from: start, to: end))
    }

    func testInvalidatedSessionCannotPricePunchPayOrReadOrders() throws {
        let draft = try burgerDraft(), order = try pending(draft)
        auth.logout(admin)
        XCTAssertThrowsError(try pricing.calculate(session: admin, draft: draft))
        XCTAssertThrowsError(try orders.punch(session: admin, draft: draft))
        XCTAssertThrowsError(try orders.order(session: admin, id: order.id))
        XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total))
    }

    func testDuplicateCartLineIdentityAndUnsafeNotesAreRejected() throws {
        var draft = try burgerDraft()
        draft.lines.append(draft.lines[0])
        XCTAssertThrowsError(try orders.punch(session: admin, draft: draft))
        draft.lines.removeLast()
        draft.lines[0].notes = "No onions\u{001B}[2J"
        XCTAssertThrowsError(try orders.punch(session: admin, draft: draft))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM orders"), 0)
    }

    func testOtherCashierCannotReplayAnotherCashiersRequest() throws {
        let draft = try burgerDraft()
        let original = try orders.punch(session: admin, draft: draft)
        let other = try cashier()
        XCTAssertThrowsError(try orders.punch(session: other, draft: draft))
        XCTAssertEqual(try orders.order(session: admin, id: original.id).cashierID, admin.user.id)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM orders"), 1)
    }

    func testOrderSearchTreatsWildcardsAndSQLAsLiteralText() throws {
        var draft = try burgerDraft()
        draft.customerName = "Customer 100%_special"
        let matching = try orders.punch(session: admin, draft: draft)
        _ = try orders.punch(session: admin, draft: burgerDraft())
        XCTAssertEqual(try orders.orders(session: admin, search: "%_").map(\.id), [matching.id])
        XCTAssertEqual(try orders.orders(session: admin, search: "CUSTOMER").map(\.id), [matching.id])
        XCTAssertTrue(try orders.orders(session: admin, search: "' OR 1=1 --").isEmpty)
        let pageOne = try orders.orders(session: admin, limit: 1)
        let pageTwo = try orders.orders(session: admin, limit: 1, offset: 1)
        XCTAssertEqual(pageOne.count, 1); XCTAssertEqual(pageTwo.count, 1)
        XCTAssertNotEqual(pageOne[0].id, pageTwo[0].id)
    }

    func testFixedDealComponentsAreSavedWithoutAddingTheirRetailPrice() throws {
        let burger = try product("Zinger Burger"), drink = try product("500 ml")
        let category = try XCTUnwrap(catalog.categories(session: admin).first { $0.name == "Deals" })
        let bundle = try catalog.saveProduct(session: admin, product: Product(name: "Fixed test bundle", categoryID: category.id, kind: .deal, basePrice: 75_000))
        try catalog.saveDeal(session: admin, deal: Deal(productID: bundle.id, slots: [
            DealSlot(label: "Burger", quantity: 2, choices: [DealChoice(productID: burger.id)]),
            DealSlot(label: "Drink", choices: [DealChoice(productID: drink.id)])
        ]))
        let order = try orders.punch(session: admin, draft: OrderDraft(lines: [CartLine(productID: bundle.id)]))
        XCTAssertEqual(order.quote.total, 75_000)
        XCTAssertEqual(order.quote.items[0].options.count, 3)
        XCTAssertEqual(order.quote.items[0].options.reduce(0) { $0 + $1.unitPrice }, 0)
        XCTAssertEqual(order.quote.items[0].options.filter { $0.productID == burger.id }.count, 2)
    }

    func testDealOptionSnapshotsSurviveLaterDealAndPizzaEdits() throws {
        let (bundle, deal, originalPizza, large) = try pizzaBundle(quantity: 1)
        let slot = try XCTUnwrap(deal.slots.first)
        let selection = DealSelection(slotID: slot.id, unitIndex: 0, productID: originalPizza.id, variantID: large.id, toppingQuantity: 2, dipSauce: true)
        let order = try orders.punch(session: admin, draft: OrderDraft(lines: [CartLine(productID: bundle.id, dealSelections: [selection])]))
        var pizza = originalPizza; pizza.name = "Changed flavour"
        _ = try catalog.saveProduct(session: admin, product: pizza)
        var changed = deal; changed.slots[0].label = "Changed slot"
        try catalog.saveDeal(session: admin, deal: changed)
        let loaded = try orders.order(session: admin, id: order.id)
        XCTAssertEqual(loaded.quote.total, 235_000)
        XCTAssertTrue(loaded.quote.items[0].options.contains { $0.name == "Pizza 1: Chicken Tikka (Large)" })
        XCTAssertTrue(loaded.quote.items[0].options.contains { $0.name == "Pizza 1 • Extra Topping" && $0.quantity == 2 && $0.unitPrice == 15_000 })
    }

    func testPaidReportKeepsHistoricalProductAndCategoryNames() throws {
        let order = try pending(burgerDraft())
        _ = try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total)
        var burger = try product("Zinger Burger"); burger.name = "New burger name"; burger.basePrice = 99_999
        _ = try catalog.saveProduct(session: admin, product: burger)
        var category = try XCTUnwrap(catalog.categories(session: admin).first { $0.id == burger.categoryID })
        category.name = "New category name"
        _ = try catalog.saveCategory(session: admin, category: category)
        let report = try allSales()
        XCTAssertEqual(report.sales, 35_000)
        XCTAssertEqual(report.topProducts.first?.name, "Zinger Burger")
        XCTAssertEqual(report.categories.first?.name, "Burgers")
    }

    func testDiscountAllocationHandlesLargeProductsWithoutIntegerOverflow() throws {
        var burger = try product("Zinger Burger"), drink = try product("500 ml")
        burger.basePrice = 6_000_000_000; drink.basePrice = 3_000_000_000
        _ = try catalog.saveProduct(session: admin, product: burger)
        _ = try catalog.saveProduct(session: admin, product: drink)
        let draft = OrderDraft(lines: [CartLine(productID: burger.id), CartLine(productID: drink.id)], discount: 3_000_000_000)
        let order = try pending(draft)
        _ = try payments.pay(session: admin, orderID: order.id, method: .card, amount: order.quote.total)
        let report = try allSales()
        XCTAssertEqual(report.sales, 6_000_000_000)
        XCTAssertEqual(report.topProducts.first { $0.name == "Zinger Burger" }?.amount, 4_000_000_000)
        XCTAssertEqual(report.topProducts.first { $0.name == "500 ml" }?.amount, 2_000_000_000)
    }

    func testFullyDiscountedOrderStillRecordsExactlyOneZeroPayment() throws {
        var draft = try burgerDraft(); draft.discount = 35_000
        let order = try pending(draft)
        XCTAssertEqual(order.quote.total, 0)
        XCTAssertEqual(try payments.pay(session: admin, orderID: order.id, method: .other, amount: 0).status, .completed)
        _ = try payments.pay(session: admin, orderID: order.id, method: .other, amount: 0)
        let report = try allSales()
        XCTAssertEqual(report.sales, 0); XCTAssertEqual(report.orderCount, 1); XCTAssertEqual(report.productsSold, 1)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM payments"), 1)
    }

    func testCorruptStoredExtrasAreRejectedBeforePayment() throws {
        let pizza = try product("Chicken Tikka"), medium = try variant(pizza, "Medium")
        let order = try pending(OrderDraft(lines: [CartLine(productID: pizza.id, variantID: medium.id, toppingQuantity: 1)]))
        try database.execute(sql: "UPDATE order_item_options SET unit_price = unit_price + 1 WHERE unit_price > 0")
        XCTAssertThrowsError(try orders.order(session: admin, id: order.id))
        XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM payments"), 0)
    }

    func testExpenseWriteRollsBackWhenAuditCannotBeSaved() throws {
        try database.execute(sql: "CREATE TRIGGER test_reject_expense_audit BEFORE INSERT ON audit_logs WHEN NEW.action = 'Expense added' BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        XCTAssertThrowsError(try expenses.add(session: admin, expense: Expense(amount: 2_500, description: "Supplies")))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM expenses"), 0)
    }

    func testDeliveryPhoneIsValidatedByServiceAndStoredNormalized() throws {
        var draft = try burgerDraft()
        draft.type = .delivery; draft.customerName = "Customer"; draft.customerAddress = "Main Road"
        for invalid in ["", "0300", "030045733012", "030A4573301", "02104573301", "0300+4573301"] {
            draft.customerPhone = invalid
            XCTAssertThrowsError(try orders.punch(session: admin, draft: draft), invalid)
        }
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM orders"), 0)
        for number in ["03004573301", "0300-4573301", "+923004573301", "923004573301"] {
            draft.requestID = UUID(); draft.customerPhone = number
            let saved = try orders.punch(session: admin, draft: draft)
            XCTAssertEqual(saved.customerPhone, "03004573301")
            XCTAssertEqual(try orders.punch(session: admin, draft: draft).id, saved.id)
        }
    }

    func testExactAndOverTenderedCashRecordOnlyOrderTotal() throws {
        for tendered in [Money(35_000), 50_000] {
            let order = try pending(burgerDraft())
            let paid = try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total, cashTendered: tendered)
            XCTAssertEqual(paid.status, .completed)
            XCTAssertEqual(paid.payment?.amount, 35_000)
            let retry = try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total, cashTendered: tendered)
            XCTAssertEqual(retry.payment?.id, paid.payment?.id)
        }
        XCTAssertEqual(try allSales().sales, 70_000)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT SUM(amount) FROM payments"), 70_000)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM audit_logs WHERE action = 'Order completed'"), 2)
    }

    func testUnderTenderedAndInvalidCashCannotBeRecordedThroughService() throws {
        let order = try pending(burgerDraft())
        for tendered in [Money(0), 34_999, -1, Int64.max] {
            XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total, cashTendered: tendered))
        }
        XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .card, amount: order.quote.total, cashTendered: 50_000))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM payments"), 0)
        XCTAssertEqual(try orders.order(session: admin, id: order.id).status, .paymentPending)
    }

    func testCompletionAuditFailureRollsBackPaymentStatusAndPaymentAudit() throws {
        let order = try pending(burgerDraft())
        try database.execute(sql: "CREATE TRIGGER test_reject_completion_audit BEFORE INSERT ON audit_logs WHEN NEW.action = 'Order completed' BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total, cashTendered: 50_000))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM payments"), 0)
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM audit_logs WHERE action = 'Payment recorded'"), 0)
        XCTAssertEqual(try orders.order(session: admin, id: order.id).status, .paymentPending)
        try database.execute(sql: "DROP TRIGGER test_reject_completion_audit")
        XCTAssertEqual(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total, cashTendered: 50_000).status, .completed)
    }

    func testCompletionUpdateFailureRollsBackPayment() throws {
        let order = try pending(burgerDraft())
        try database.execute(sql: "CREATE TRIGGER test_reject_completion BEFORE UPDATE OF status ON orders WHEN NEW.status = 'COMPLETED' BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM payments"), 0)
        XCTAssertEqual(try orders.order(session: admin, id: order.id).status, .paymentPending)
    }

    func testLegacyPreparingReadyAndPaidOrdersRemainReadable() throws {
        for status in [OrderStatus.preparing, .ready] {
            let order = try orders.punch(session: admin, draft: burgerDraft())
            try database.execute(sql: "UPDATE orders SET status = ? WHERE id = ?", parameters: [.text(status.rawValue), .integer(order.id)])
            XCTAssertEqual(try orders.order(session: admin, id: order.id).status, status)
            XCTAssertEqual(try orders.transition(session: admin, id: order.id, to: .paymentPending).status, .paymentPending)
            XCTAssertEqual(try payments.pay(session: admin, orderID: order.id, method: .card, amount: order.quote.total).status, .completed)
        }
        let historical = try pending(burgerDraft())
        _ = try payments.pay(session: admin, orderID: historical.id, method: .cash, amount: historical.quote.total)
        try database.execute(sql: "UPDATE orders SET status = 'PAID' WHERE id = ?", parameters: [.integer(historical.id)])
        XCTAssertEqual(try orders.order(session: admin, id: historical.id).status, .paid)
        XCTAssertThrowsError(try orders.transition(session: admin, id: historical.id, to: .cancelled, reason: "Invalid"))
        XCTAssertTrue(try orders.orders(session: admin, payment: .paid).contains { $0.id == historical.id })
        XCTAssertEqual(try allSales().sales, 105_000)
        XCTAssertEqual(try allSales().orderCount, 3)
        XCTAssertEqual(try orders.transition(session: admin, id: historical.id, to: .completed).status, .completed)
        XCTAssertEqual(try allSales().sales, 105_000)
    }

    func testLegacyAndPendingUnpaidOrdersStillRequireCancellationReason() throws {
        for status in [OrderStatus.preparing, .ready, .paymentPending] {
            let order = try orders.punch(session: admin, draft: burgerDraft())
            try database.execute(sql: "UPDATE orders SET status = ? WHERE id = ?", parameters: [.text(status.rawValue), .integer(order.id)])
            XCTAssertThrowsError(try orders.transition(session: admin, id: order.id, to: .cancelled, reason: "  "))
            let cancelled = try orders.transition(session: admin, id: order.id, to: .cancelled, reason: "Customer cancelled")
            XCTAssertEqual(cancelled.status, .cancelled)
            XCTAssertEqual(cancelled.cancellationReason, "Customer cancelled")
            XCTAssertThrowsError(try payments.pay(session: admin, orderID: order.id, method: .cash, amount: order.quote.total))
        }
    }

    func testOrderTypeAndPaymentFiltersUseDatabaseTogether() throws {
        var dineIn = try burgerDraft(), takeaway = try burgerDraft(), delivery = try burgerDraft()
        dineIn.customerName = "Dining guest"; takeaway.type = .takeaway; delivery.type = .delivery
        delivery.customerName = "Delivery guest"; delivery.customerPhone = "03004573301"; delivery.customerAddress = "Main Road"
        let open = try orders.punch(session: admin, draft: dineIn)
        let collected = try pending(takeaway)
        _ = try payments.pay(session: admin, orderID: collected.id, method: .card, amount: collected.quote.total)
        let pendingDelivery = try pending(delivery)
        delivery.requestID = UUID()
        let cancelled = try orders.punch(session: admin, draft: delivery)
        _ = try orders.transition(session: admin, id: cancelled.id, to: .cancelled, reason: "Customer cancelled")
        XCTAssertEqual(try orders.orders(session: admin, type: .dineIn).map(\.id), [open.id])
        XCTAssertEqual(try orders.orders(session: admin, type: .takeaway).map(\.id), [collected.id])
        XCTAssertEqual(Set(try orders.orders(session: admin, type: .delivery).map(\.id)), Set([pendingDelivery.id, cancelled.id]))
        XCTAssertEqual(try orders.orders(session: admin, payment: .paymentPending).map(\.id), [pendingDelivery.id])
        XCTAssertEqual(try orders.orders(session: admin, payment: .paid).map(\.id), [collected.id])
        XCTAssertEqual(try orders.orders(session: admin, payment: .cancelled).map(\.id), [cancelled.id])
        XCTAssertEqual(try orders.orders(session: admin, search: "DELIVERY", type: .delivery, payment: .paymentPending).map(\.id), [pendingDelivery.id])
        XCTAssertEqual(try orders.orders(session: admin, search: "0300457", type: .delivery, payment: .cancelled).map(\.id), [cancelled.id])
        XCTAssertTrue(try orders.orders(session: admin, type: .dineIn, payment: .paid).isEmpty)
    }

    func testOrderLocalDayBoundariesAndAllDatesIncludePaidAndCancelled() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Karachi"))
        let reference = Date(timeIntervalSince1970: 1_790_000_000)
        let start = calendar.startOfDay(for: reference)
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        let previous = try pending(burgerDraft())
        let atStart = try pending(burgerDraft())
        let beforeEnd = try orders.punch(session: admin, draft: burgerDraft())
        let nextDay = try orders.punch(session: admin, draft: burgerDraft())
        _ = try payments.pay(session: admin, orderID: previous.id, method: .cash, amount: previous.quote.total)
        _ = try payments.pay(session: admin, orderID: atStart.id, method: .cash, amount: atStart.quote.total)
        _ = try orders.transition(session: admin, id: beforeEnd.id, to: .cancelled, reason: "No longer needed")
        for (id, date) in [(previous.id, start.addingTimeInterval(-1)), (atStart.id, start), (beforeEnd.id, end.addingTimeInterval(-1)), (nextDay.id, end)] {
            try database.execute(sql: "UPDATE orders SET created_at = ? WHERE id = ?", parameters: [.real(date.timeIntervalSince1970), .integer(id)])
        }
        XCTAssertEqual(try orders.orders(session: admin, from: start, to: end).map(\.id), [beforeEnd.id, atStart.id])
        XCTAssertEqual(try orders.orders(session: admin, payment: .paid, from: start, to: end).map(\.id), [atStart.id])
        XCTAssertEqual(try orders.orders(session: admin, payment: .cancelled, from: start, to: end).map(\.id), [beforeEnd.id])
        XCTAssertEqual(try orders.orders(session: admin).count, 4)
        XCTAssertEqual(try orders.orders(session: admin, payment: .paid).map(\.id), [atStart.id, previous.id])
    }

    func testCombinedOrderFiltersRetainStablePaginationAndLiteralSearch() throws {
        var draft = try burgerDraft()
        draft.type = .delivery; draft.customerName = "Family 100%_special"; draft.customerPhone = "03004573301"; draft.customerAddress = "Street 2"
        let start = Date(timeIntervalSince1970: 1_790_000_000), end = Date(timeIntervalSince1970: 1_790_086_400)
        var expected: [Int64] = []
        for _ in 0..<3 {
            draft.requestID = UUID()
            let order = try pending(draft)
            expected.insert(order.id, at: 0)
            try database.execute(sql: "UPDATE orders SET created_at = ? WHERE id = ?", parameters: [.real(start.timeIntervalSince1970), .integer(order.id)])
        }
        _ = try pending(burgerDraft())
        var actual: [Int64] = []
        for offset in 0..<3 {
            let page = try orders.orders(session: admin, search: "%_", type: .delivery, payment: .paymentPending, from: start, to: end, limit: 1, offset: offset)
            actual.append(contentsOf: page.map(\.id))
        }
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(try orders.orders(session: admin, search: "' OR 1=1 --", type: .delivery, payment: .paymentPending, from: start, to: end).isEmpty)
        XCTAssertTrue(try orders.orders(session: admin, type: .delivery, payment: .paymentPending, from: start, to: end, limit: 1, offset: 3).isEmpty)
    }

    func testOrderFiltersValidateDateBoundsPaginationAndSession() throws {
        let start = Date(), end = start.addingTimeInterval(1)
        XCTAssertThrowsError(try orders.orders(session: admin, from: start))
        XCTAssertThrowsError(try orders.orders(session: admin, to: end))
        XCTAssertThrowsError(try orders.orders(session: admin, from: end, to: start))
        XCTAssertThrowsError(try orders.orders(session: admin, from: start, to: start))
        XCTAssertThrowsError(try orders.orders(session: admin, from: Date(timeIntervalSince1970: .infinity), to: end))
        XCTAssertThrowsError(try orders.orders(session: admin, limit: 0))
        XCTAssertThrowsError(try orders.orders(session: admin, limit: 501))
        XCTAssertThrowsError(try orders.orders(session: admin, offset: -1))
        auth.logout(admin)
        XCTAssertThrowsError(try orders.orders(session: admin, type: .delivery, payment: .paid, from: start, to: end))
    }
}
