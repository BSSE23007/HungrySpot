import Foundation

public typealias Money = Int64
public enum SpotError: Error, LocalizedError {
    case validation(String), forbidden, unauthenticated, database(String), notFound, conflict(String)
    public var errorDescription: String? {
        switch self {
        case .validation(let s), .database(let s), .conflict(let s): return s
        case .forbidden: return "Your account does not have permission for this action."
        case .unauthenticated: return "Please sign in again."
        case .notFound: return "This record is no longer available."
        }
    }
}
public enum Role: String, Codable, CaseIterable { case admin, cashier }
public struct User: Identifiable, Codable, Equatable {
    public var id: Int64; public var username: String; public var role: Role; public var isActive: Bool
    public init(id: Int64, username: String, role: Role, isActive: Bool = true) { self.id=id; self.username=username; self.role=role; self.isActive=isActive }
}
public struct Session: Equatable {
    public let token: UUID
    public let user: User
    // Only AuthenticationService can issue a registered session; services verify its token and persisted role.
    public init(token: UUID, user: User) { self.token=token; self.user=user }
}
public struct Category: Identifiable, Codable, Equatable {
    public var id: Int64; public var name: String; public var parentID: Int64?; public var displayOrder: Int; public var isActive: Bool; public var icon: String; public var imagePath: String?
    public init(id: Int64 = 0, name: String = "", parentID: Int64? = nil, displayOrder: Int = 0, isActive: Bool = true, icon: String = "fork.knife", imagePath: String? = nil) { self.id=id; self.name=name; self.parentID=parentID; self.displayOrder=displayOrder; self.isActive=isActive; self.icon=icon; self.imagePath=imagePath }
}
public enum ProductKind: String, Codable, CaseIterable { case normal, variant, pizza, deal }
public struct ProductVariant: Identifiable, Codable, Equatable {
    public var id: Int64; public var productID: Int64; public var name: String; public var price: Money; public var displayOrder: Int; public var isAvailable: Bool; public var toppingPrice: Money?
    public init(id: Int64 = 0, productID: Int64 = 0, name: String = "", price: Money = 0, displayOrder: Int = 0, isAvailable: Bool = true, toppingPrice: Money? = nil) { self.id=id; self.productID=productID; self.name=name; self.price=price; self.displayOrder=displayOrder; self.isAvailable=isAvailable; self.toppingPrice=toppingPrice }
}
public struct Product: Identifiable, Codable, Equatable {
    public var id: Int64; public var name: String; public var categoryID: Int64; public var subcategoryID: Int64?; public var description: String; public var kind: ProductKind; public var basePrice: Money; public var imagePath: String?; public var isAvailable: Bool; public var isActive: Bool; public var displayOrder: Int; public var variants: [ProductVariant]
    public init(id: Int64 = 0, name: String = "", categoryID: Int64 = 0, subcategoryID: Int64? = nil, description: String = "", kind: ProductKind = .normal, basePrice: Money = 0, imagePath: String? = nil, isAvailable: Bool = true, isActive: Bool = true, displayOrder: Int = 0, variants: [ProductVariant] = []) { self.id=id; self.name=name; self.categoryID=categoryID; self.subcategoryID=subcategoryID; self.description=description; self.kind=kind; self.basePrice=basePrice; self.imagePath=imagePath; self.isAvailable=isAvailable; self.isActive=isActive; self.displayOrder=displayOrder; self.variants=variants }
    public var startingPrice: Money { variants.filter(\.isAvailable).map(\.price).min() ?? basePrice }
}
public struct DealChoice: Identifiable, Codable, Equatable {
    public var id: String { "\(productID):\(variantID ?? 0)" }
    public var productID: Int64; public var variantID: Int64?
    public init(productID: Int64, variantID: Int64? = nil) { self.productID=productID; self.variantID=variantID }
}
public struct DealSlot: Identifiable, Codable, Equatable {
    public var id: Int64; public var dealID: Int64; public var label: String; public var quantity: Int; public var requiresSelection: Bool; public var choices: [DealChoice]
    public init(id: Int64 = 0, dealID: Int64 = 0, label: String = "", quantity: Int = 1, requiresSelection: Bool = false, choices: [DealChoice] = []) { self.id=id; self.dealID=dealID; self.label=label; self.quantity=quantity; self.requiresSelection=requiresSelection; self.choices=choices }
}
public struct Deal: Identifiable, Codable, Equatable {
    public var id: Int64 { productID }; public var productID: Int64; public var needsReview: Bool; public var reviewNote: String; public var slots: [DealSlot]
    public init(productID: Int64, needsReview: Bool = false, reviewNote: String = "", slots: [DealSlot] = []) { self.productID=productID; self.needsReview=needsReview; self.reviewNote=reviewNote; self.slots=slots }
}
public struct DealSelection: Codable, Equatable {
    public var slotID: Int64; public var unitIndex: Int; public var productID: Int64; public var variantID: Int64?; public var toppingQuantity: Int; public var dipSauce: Bool
    public init(slotID: Int64, unitIndex: Int, productID: Int64, variantID: Int64? = nil, toppingQuantity: Int = 0, dipSauce: Bool = false) { self.slotID=slotID; self.unitIndex=unitIndex; self.productID=productID; self.variantID=variantID; self.toppingQuantity=toppingQuantity; self.dipSauce=dipSauce }
}
public struct CartLine: Identifiable, Codable, Equatable {
    public var id: UUID; public var productID: Int64; public var variantID: Int64?; public var quantity: Int; public var toppingQuantity: Int; public var dipSauce: Bool; public var notes: String; public var dealSelections: [DealSelection]
    public init(id: UUID = UUID(), productID: Int64, variantID: Int64? = nil, quantity: Int = 1, toppingQuantity: Int = 0, dipSauce: Bool = false, notes: String = "", dealSelections: [DealSelection] = []) { self.id=id; self.productID=productID; self.variantID=variantID; self.quantity=quantity; self.toppingQuantity=toppingQuantity; self.dipSauce=dipSauce; self.notes=notes; self.dealSelections=dealSelections }
}
public enum OrderType: String, Codable, CaseIterable { case dineIn = "DINE-IN", takeaway = "TAKEAWAY", delivery = "DELIVERY" }
public enum OrderStatus: String, Codable, CaseIterable {
    case punched = "PUNCHED", preparing = "PREPARING", ready = "READY", paymentPending = "PAYMENT PENDING", paid = "PAID", completed = "COMPLETED", cancelled = "CANCELLED"
}
public enum PaymentMethod: String, Codable, CaseIterable { case cash = "CASH", card = "CARD", other = "OTHER" }
/// Paid includes both historical PAID orders and automatically COMPLETED orders.
public enum OrderPaymentFilter: String, CaseIterable {
    case all = "All", paymentPending = "Payment Pending", paid = "Paid", cancelled = "Cancelled"
}

/// Cash is tendered for an exact order total; change never becomes sales revenue.
public struct CashPaymentQuote: Equatable {
    public let total: Money
    public let tendered: Money
    public var change: Money { max(0, tendered - total) }
    public var shortage: Money { max(0, total - tendered) }
    public var canConfirm: Bool { tendered >= total }

    public init(total: Money, tendered: Money) throws {
        try ServiceValidation.amount(total, label: "Amount to collect")
        try ServiceValidation.amount(tendered, label: "Customer paid")
        self.total = total; self.tendered = tendered
    }
}
public struct OrderDraft: Codable, Equatable {
    public var requestID: UUID; public var type: OrderType; public var lines: [CartLine]; public var customerName: String; public var customerPhone: String; public var customerAddress: String; public var deliveryCharge: Money; public var discount: Money; public var notes: String
    public init(requestID: UUID = UUID(), type: OrderType = .dineIn, lines: [CartLine] = [], customerName: String = "", customerPhone: String = "", customerAddress: String = "", deliveryCharge: Money = 0, discount: Money = 0, notes: String = "") { self.requestID=requestID; self.type=type; self.lines=lines; self.customerName=customerName; self.customerPhone=customerPhone; self.customerAddress=customerAddress; self.deliveryCharge=deliveryCharge; self.discount=discount; self.notes=notes }
}
public struct OptionSnapshot: Identifiable, Codable, Equatable {
    public var id: Int64; public var name: String; public var quantity: Int; public var unitPrice: Money; public var productID: Int64?; public var variantID: Int64?
    public init(id: Int64 = 0, name: String, quantity: Int = 1, unitPrice: Money = 0, productID: Int64? = nil, variantID: Int64? = nil) { self.id=id; self.name=name; self.quantity=quantity; self.unitPrice=unitPrice; self.productID=productID; self.variantID=variantID }
}
public struct OrderItemSnapshot: Identifiable, Codable, Equatable {
    public var id: Int64; public var productID: Int64; public var productName: String; public var categoryName: String; public var variantName: String?; public var unitPrice: Money; public var extraPrice: Money; public var quantity: Int; public var notes: String; public var options: [OptionSnapshot]
    public var subtotal: Money { (unitPrice + extraPrice) * Money(quantity) }
    public init(id: Int64 = 0, productID: Int64, productName: String, categoryName: String, variantName: String? = nil, unitPrice: Money, extraPrice: Money = 0, quantity: Int = 1, notes: String = "", options: [OptionSnapshot] = []) { self.id=id; self.productID=productID; self.productName=productName; self.categoryName=categoryName; self.variantName=variantName; self.unitPrice=unitPrice; self.extraPrice=extraPrice; self.quantity=quantity; self.notes=notes; self.options=options }
}
public struct Quote: Codable, Equatable {
    public var items: [OrderItemSnapshot]; public var subtotal: Money; public var deliveryCharge: Money; public var discount: Money
    public var total: Money { subtotal + deliveryCharge - discount }
    public init(items: [OrderItemSnapshot], subtotal: Money, deliveryCharge: Money, discount: Money) { self.items=items; self.subtotal=subtotal; self.deliveryCharge=deliveryCharge; self.discount=discount }
}
public struct Payment: Identifiable, Codable, Equatable {
    public var id: Int64; public var orderID: Int64; public var amount: Money; public var method: PaymentMethod; public var cashierID: Int64; public var createdAt: Date
    public init(id: Int64, orderID: Int64, amount: Money, method: PaymentMethod, cashierID: Int64, createdAt: Date) { self.id=id; self.orderID=orderID; self.amount=amount; self.method=method; self.cashierID=cashierID; self.createdAt=createdAt }
}
public struct OrderRecord: Identifiable, Codable, Equatable {
    public var id: Int64; public var number: String; public var type: OrderType; public var status: OrderStatus; public var createdAt: Date; public var cashierID: Int64; public var cashierName: String; public var customerName: String; public var customerPhone: String; public var customerAddress: String; public var notes: String; public var cancellationReason: String; public var quote: Quote; public var payment: Payment?
    public init(id: Int64, number: String, type: OrderType, status: OrderStatus, createdAt: Date, cashierID: Int64, cashierName: String, customerName: String = "", customerPhone: String = "", customerAddress: String = "", notes: String = "", cancellationReason: String = "", quote: Quote, payment: Payment? = nil) { self.id=id; self.number=number; self.type=type; self.status=status; self.createdAt=createdAt; self.cashierID=cashierID; self.cashierName=cashierName; self.customerName=customerName; self.customerPhone=customerPhone; self.customerAddress=customerAddress; self.notes=notes; self.cancellationReason=cancellationReason; self.quote=quote; self.payment=payment }
}
public struct Expense: Identifiable, Codable, Equatable {
    public var id: Int64; public var date: Date; public var amount: Money; public var description: String
    public init(id: Int64 = 0, date: Date = Date(), amount: Money = 0, description: String = "") { self.id=id; self.date=date; self.amount=amount; self.description=description }
}
public struct AuditEntry: Identifiable {
    public var id: Int64; public var action: String; public var username: String; public var entity: String; public var details: String; public var date: Date
    public init(id: Int64, action: String, username: String, entity: String, details: String, date: Date) { self.id=id; self.action=action; self.username=username; self.entity=entity; self.details=details; self.date=date }
}
public struct ReportRow: Identifiable {
    public var id: String { name }; public var name: String; public var quantity: Int; public var amount: Money
    public init(name: String, quantity: Int, amount: Money) { self.name=name; self.quantity=quantity; self.amount=amount }
}
public struct ReportSummary {
    public var sales: Money; public var orderCount: Int; public var productsSold: Int; public var deliveryOrders: Int; public var deliveryCharges: Money; public var expenses: Money; public var topProducts: [ReportRow]; public var categories: [ReportRow]; public var dailySales: [ReportRow]
    public var afterExpenses: Money { sales - expenses }
    public init(sales: Money = 0, orderCount: Int = 0, productsSold: Int = 0, deliveryOrders: Int = 0, deliveryCharges: Money = 0, expenses: Money = 0, topProducts: [ReportRow] = [], categories: [ReportRow] = [], dailySales: [ReportRow] = []) { self.sales=sales; self.orderCount=orderCount; self.productsSold=productsSold; self.deliveryOrders=deliveryOrders; self.deliveryCharges=deliveryCharges; self.expenses=expenses; self.topProducts=topProducts; self.categories=categories; self.dailySales=dailySales }
}
public struct AppSettings: Codable, Equatable {
    public var restaurantName = "THE HUNGRY SPOT"
    public var tagline = "Eat • Enjoy • Repeat"
    public var phones = "03304573301 / 03221168559"
    public var address = "Shaheen Villas Phase #2, E Block Bajwa Market, near Family Park, Sheikhupura"
    public var hours = "1 PM – 1 AM"
    public var logoPath: String? = nil
    public var receiptFooter = "Thank You!"
    public var currencySymbol = "Rs"
    public var defaultDeliveryCharge: Money = 0
    public var quickDeliveryCharges: [Money] = [0, 5000, 10000, 15000, 20000]
    public var dipSaucePrice: Money = 5000
    public var cashierCanDiscount = false
    public var receiptPrinter = ""
    public var kitchenPrinter = ""
    public var paperWidthMM = 80
    public var autoPrintKitchen = false
    public init() {}
}
public enum MoneyFormat {
    public static func string(_ amount: Money, symbol: String = "Rs") -> String {
        let value = Decimal(amount) / 100
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 2; f.minimumFractionDigits = amount % 100 == 0 ? 0 : 2
        return "\(symbol) \(f.string(from: value as NSDecimalNumber) ?? "0")"
    }
    public static func parse(_ text: String) throws -> Money {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.range(of: #"^\d{1,8}(\.\d{1,2})?$"#, options: .regularExpression) != nil, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { throw SpotError.validation("Enter a nonnegative amount with up to two decimal places.") }
        return NSDecimalNumber(decimal: value * 100).int64Value
    }
    public static func editable(_ amount: Money) -> String { NSDecimalNumber(decimal: Decimal(amount) / 100).stringValue }
}
