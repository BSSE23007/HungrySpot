import AppKit
import SwiftUI
import HungrySpotCore

enum AppRoute: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", pos = "POS", orders = "Orders", menu = "Menu", categories = "Categories", deals = "Deals", sales = "Sales", expenses = "Expenses", audit = "Audit Log", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: return "chart.bar.xaxis"
        case .pos: return "square.grid.2x2"
        case .orders: return "list.bullet.rectangle"
        case .menu: return "menucard"
        case .categories: return "square.stack.3d.up"
        case .deals: return "gift"
        case .sales: return "chart.xyaxis.line"
        case .expenses: return "banknote"
        case .audit: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
    var adminOnly: Bool { self != .pos && self != .orders && self != .menu }
}

struct AppMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

@MainActor
final class AppState: ObservableObject {
    let paths: AppPaths
    let database: Database
    let auth: AuthenticationService
    let catalog: CatalogService
    let pricing: PricingService
    let orders: OrderService
    let payments: PaymentService
    let reporting: ReportingService
    let expenses: ExpenseService
    let images: ImageStorageService
    let backups: BackupService
    let printer: NativePrinterService

    @Published var needsSetup: Bool
    @Published var session: Session?
    @Published var route: AppRoute = .pos
    @Published var settings = AppSettings()
    @Published var categories: [HungrySpotCore.Category] = []
    @Published var products: [Product] = []
    @Published var draft = OrderDraft() { didSet { updateQuote() } }
    @Published var quote: Quote?
    @Published var quoteError: String?
    @Published var revision = 0
    @Published var searchRequested = 0
    @Published var alert: AppMessage?
    @Published var notice: String?
    @Published var selectedOrderID: Int64?
    @Published var printTarget: OrderRecord?
    @Published var newOrderRequested = false

    init() throws {
        paths = try AppPaths()
        database = try Database(path: paths.databaseURL.path)
        try database.bootstrap()
        auth = AuthenticationService(database: database)
        catalog = CatalogService(database: database, auth: auth)
        pricing = PricingService(catalog: catalog)
        orders = OrderService(database: database, auth: auth, catalog: catalog)
        payments = PaymentService(database: database, auth: auth, orders: orders)
        reporting = ReportingService(database: database, auth: auth)
        expenses = ExpenseService(database: database, auth: auth)
        images = ImageStorageService(paths: paths)
        backups = BackupService(database: database, auth: auth, paths: paths)
        printer = NativePrinterService()
        needsSetup = try auth.needsSetup()
    }

    var isAdmin: Bool { session?.user.role == .admin }
    var routes: [AppRoute] { AppRoute.allCases.filter { isAdmin || !$0.adminOnly } }
    var canDiscount: Bool { isAdmin || settings.cashierCanDiscount }
    func money(_ value: Money) -> String { MoneyFormat.string(value, symbol: settings.currencySymbol) }

    @discardableResult
    func run(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return true }
        catch {
            if case SpotError.unauthenticated = error { clearSession() }
            alert = AppMessage(title: "Action could not be completed", detail: error.localizedDescription)
            NSLog("Hungry Spot: %@", String(describing: error))
            return false
        }
    }

    func signIn(username: String, password: String, setup: Bool) {
        do {
            let issued = try setup ? auth.setupAdmin(username: username, password: password) : auth.login(username: username, password: password)
            session = issued
            needsSetup = false
            try reloadCatalog()
            resetDraft()
            route = issued.user.role == .admin ? .dashboard : .pos
        } catch {
            if let session { auth.logout(session) }
            clearSession()
            alert = AppMessage(title: "Sign in could not be completed", detail: error.localizedDescription)
        }
    }

    func logout() {
        if let session { auth.logout(session) }
        clearSession()
    }

    func clearSession() {
        session = nil
        draft = OrderDraft()
        quote = nil
        quoteError = nil
        products = []
        categories = []
        selectedOrderID = nil
        printTarget = nil
        notice = nil
        alert = nil
        newOrderRequested = false
        route = .pos
        settings = AppSettings()
        do { needsSetup = try auth.needsSetup() }
        catch { alert = AppMessage(title: "Could not read account status", detail: error.localizedDescription) }
    }

    func reloadCatalog() throws {
        guard let session else { throw SpotError.unauthenticated }
        settings = try catalog.settings(session: session)
        categories = try catalog.categories(session: session, includeInactive: isAdmin)
        products = try catalog.products(session: session, includeInactive: isAdmin)
        revision += 1
        updateQuote()
    }

    func updateQuote() {
        guard let session else { quote = nil; return }
        do {
            quote = try pricing.calculate(session: session, draft: draft)
            quoteError = nil
        } catch { quote = nil; quoteError = error.localizedDescription }
    }

    func resetDraft() {
        draft = OrderDraft()
        route = .pos
    }

    func requestNewOrder() {
        if draft.lines.isEmpty { resetDraft() } else { newOrderRequested = true }
    }

    func add(_ line: CartLine) {
        if let index = draft.lines.firstIndex(where: { $0.id == line.id }) { draft.lines[index] = line }
        else { draft.lines.append(line) }
    }

    func punch() {
        guard let session else { return }
        run {
            let saved = try orders.punch(session: session, draft: draft)
            draft = OrderDraft()
            selectedOrderID = saved.id
            printTarget = saved
            route = .orders
            revision += 1
            notice = "Order \(saved.number) saved. Kitchen ticket is ready."
            if settings.autoPrintKitchen { print(saved, kitchen: true) }
        }
    }

    func print(_ order: OrderRecord, kitchen: Bool) {
        guard let session else { return }
        do {
            let current = try orders.order(session: session, id: order.id)
            printTarget = current
            try printer.printOrder(current, settings: settings, kitchen: kitchen)
        }
        catch {
            if case SpotError.unauthenticated = error { clearSession() }
            alert = AppMessage(title: "Printing did not finish", detail: "Order \(order.number) remains saved. Use the Print Kitchen Ticket or Print Receipt button to retry.\n\n\(error.localizedDescription)")
        }
    }
}
