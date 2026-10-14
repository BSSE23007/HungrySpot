import SwiftUI
import HungrySpotCore

/// Presentation choice only: report data and daily collections are unchanged.
enum SalesDisplayMode: String, CaseIterable, Identifiable {
    case grossSales = "Gross Sales"
    case afterExpenses = "After Expenses"

    var id: String { rawValue }
    var title: String {
        self == .grossSales ? "Gross Sales" : "Sales After Recorded Expenses"
    }

    func amount(in report: ReportSummary) -> Money {
        switch self {
        case .grossSales: return report.sales
        case .afterExpenses: return report.afterExpenses
        }
    }
}

@MainActor
struct SalesResultPanel: View {
    @EnvironmentObject var app: AppState
    @Binding var mode: SalesDisplayMode
    let report: ReportSummary

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                modeControl
                selectedResult
                explanation
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modeControl: some View {
        HStack(spacing: 12) {
            Text("Sales View").font(.subheadline.bold())
            Picker("Sales View", selection: $mode) {
                ForEach(SalesDisplayMode.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 320)
            Spacer(minLength: 0)
        }
    }

    private var selectedResult: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(mode.title).font(.headline)
            Text(app.money(mode.amount(in: report)))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(SpotTheme.gold).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Gross Sales = collected sales before recorded expenses.")
            Text("After Expenses = Sales − Recorded Expenses.")
            Text("This is not accounting net profit. Cost of goods and other accounting adjustments may not be included.")
        }.font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum ReportPeriod: String, CaseIterable, Identifiable {
    case today = "Today", yesterday = "Yesterday", week = "This Week", lastWeek = "Last Week", month = "This Month", lastMonth = "Last Month", custom = "Custom", all = "All Time"
    var id: String { rawValue }
    func bounds(start: Date, end: Date, now: Date = Date()) -> (Date, Date) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        switch self {
        case .today: return (day, tomorrow)
        case .yesterday: return (calendar.date(byAdding: .day, value: -1, to: day)!, day)
        case .week: let interval = calendar.dateInterval(of: .weekOfYear, for: now)!; return (interval.start, interval.end)
        case .lastWeek: let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: now)!; let interval = calendar.dateInterval(of: .weekOfYear, for: previous)!; return (interval.start, interval.end)
        case .month: let interval = calendar.dateInterval(of: .month, for: now)!; return (interval.start, interval.end)
        case .lastMonth: let previous = calendar.date(byAdding: .month, value: -1, to: now)!; let interval = calendar.dateInterval(of: .month, for: previous)!; return (interval.start, interval.end)
        case .custom: return (calendar.startOfDay(for: start), calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!)
        case .all: return (Date(timeIntervalSince1970: 0), tomorrow)
        }
    }
}
@MainActor
struct DateRangeControl: View {
    @Binding var period: ReportPeriod
    @Binding var start: Date
    @Binding var end: Date
    var body: some View {
        HStack(spacing: 12) {
            Picker("Period", selection: $period) { ForEach(ReportPeriod.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 200)
            if period == .custom { DatePicker("From", selection: $start, displayedComponents: .date); DatePicker("Through", selection: $end, in: start..., displayedComponents: .date) }
            Spacer(minLength: 0)
        }.onChange(of: start) { value in if end < value { end = value } }
    }
}
@MainActor
struct MetricCard: View {
    let label: String
    let value: String
    let symbol: String
    var accent: Color = SpotTheme.gold
    var body: some View { Panel { VStack(alignment: .leading, spacing: 16) { HStack { Image(systemName: symbol).foregroundStyle(accent); Spacer(); Text(label).font(.caption).foregroundStyle(.secondary) }; Text(value).font(.system(size: 25, weight: .bold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading) } }
}
@MainActor
struct DashboardView: View {
    @EnvironmentObject var app: AppState
    @State private var period = ReportPeriod.today
    @State private var start = Date()
    @State private var end = Date()
    @State private var report = ReportSummary()
    @State private var salesMode = SalesDisplayMode.grossSales
    @State private var recent: [OrderRecord] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { PageTitle(title: "A fresh view of your restaurant.", subtitle: Date().formatted(.dateTime.weekday(.wide).month(.wide).day())); Spacer(); Button { app.route = .pos } label: { Label("Open POS", systemImage: "arrow.up.right") }.buttonStyle(.borderedProminent).controlSize(.large) }
                DateRangeControl(period: $period, start: $start, end: $end)
                SalesResultPanel(mode: $salesMode, report: report)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    MetricCard(label: "Collected sales", value: app.money(report.sales), symbol: "banknote", accent: SpotTheme.orange)
                    MetricCard(label: "Paid orders", value: "\(report.orderCount)", symbol: "receipt")
                    MetricCard(label: "Products sold", value: "\(report.productsSold)", symbol: "bag")
                    MetricCard(label: "Delivery orders", value: "\(report.deliveryOrders)", symbol: "bicycle")
                    MetricCard(label: "Delivery charges", value: app.money(report.deliveryCharges), symbol: "shippingbox")
                    MetricCard(label: "Recorded expenses", value: app.money(report.expenses), symbol: "arrow.up.right", accent: .pink)
                }
                HStack(alignment: .top, spacing: 16) {
                    Panel { VStack(alignment: .leading, spacing: 18) { Text("Daily collections · before expenses").font(.headline); SalesChart(rows: report.dailySales).frame(height: 220) }.frame(maxWidth: .infinity) }
                    Panel { VStack(alignment: .leading, spacing: 18) { Text("Top products").font(.headline); if report.topProducts.isEmpty { Text("Collected sales will appear here.").foregroundStyle(.secondary) }; ForEach(Array(report.topProducts.prefix(5).enumerated()), id: \.offset) { index, row in HStack { Text(String(format: "%02d", index + 1)).font(.caption.bold()).foregroundStyle(SpotTheme.orange).frame(width: 24); VStack(alignment: .leading, spacing: 4) { Text(row.name).lineLimit(1); Text("\(row.quantity) sold").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(app.money(row.amount)).fontWeight(.semibold) } } }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 250) }
                }
                Panel { VStack(alignment: .leading, spacing: 16) { HStack { Text("Latest orders").font(.headline); Spacer(); Button("See all") { app.route = .orders } }; ForEach(recent) { order in Button { app.selectedOrderID = order.id; app.route = .orders } label: { HStack { Text(order.number).fontWeight(.semibold).frame(width: 110, alignment: .leading); Text(order.type.rawValue).font(.caption).foregroundStyle(.secondary); Spacer(); StatusBadge(text: order.status.rawValue, color: order.status.color); Text(app.money(order.quote.total)).frame(width: 100, alignment: .trailing) }.padding(.vertical, 5) }.buttonStyle(.plain) }; if recent.isEmpty { Text("Your first punched order will appear here.").foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading) }
                Panel { ReportRows(title: "Category performance", rows: report.categories) }
            }.padding(26)
        }.onAppear { load() }.onChange(of: period) { _ in load() }.onChange(of: start) { _ in load() }.onChange(of: end) { _ in load() }.onChange(of: app.revision) { _ in load() }
    }
    private func load() {
        guard let session = app.session else { return }
        let range = period.bounds(start: start, end: end)
        app.run { report = try app.reporting.summary(session: session, from: range.0, to: range.1); recent = try app.orders.orders(session: session, limit: 6) }
    }
}
@MainActor
struct SalesChart: View {
    @EnvironmentObject var app: AppState
    let rows: [ReportRow]
    private let maximumBars = 31

    /// Include every date, combining consecutive report rows for long periods.
    /// Report totals have already been checked for overflow by ReportingService.
    static func groupedRows(_ rows: [ReportRow], maximumBars: Int = 31) -> [ReportRow] {
        guard !rows.isEmpty else { return [] }
        let ordered = rows.sorted { $0.name < $1.name }
        let groupSize = (ordered.count - 1) / max(1, maximumBars) + 1
        return stride(from: 0, to: ordered.count, by: groupSize).map { offset in
            let group = ordered[offset..<min(offset + groupSize, ordered.count)]
            let first = ordered[offset].name
            let last = ordered[min(offset + groupSize, ordered.count) - 1].name
            return ReportRow(name: first == last ? first : "\(first) – \(last)",
                             quantity: group.reduce(0) { $0 + $1.quantity },
                             amount: group.reduce(0) { $0 + $1.amount })
        }
    }

    var body: some View {
        if rows.isEmpty { EmptyState(symbol: "chart.bar", title: "No collections yet", detail: "Paid orders in this period will populate the chart.") }
        else {
            let bars = Self.groupedRows(rows, maximumBars: maximumBars)
            let largest = max(1, bars.map(\.amount).max() ?? 1)
            VStack(alignment: .leading, spacing: 12) {
                Text(rows.count > maximumBars
                     ? "All \(rows.count) dates with paid sales, combined into \(bars.count) consecutive ranges. Scroll to see every range."
                     : "Daily totals for all \(rows.count) dates with paid sales. Scroll to see every date.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(bars) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(row.name).font(.caption).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Text(app.money(row.amount)).font(.caption.bold()).monospacedDigit()
                                }
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(SpotTheme.background)
                                        Capsule().fill(SpotTheme.orange)
                                            .frame(width: geometry.size.width * CGFloat(Double(row.amount) / Double(largest)))
                                    }
                                }.frame(height: 9)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(row.name), \(row.quantity) paid orders")
                            .accessibilityValue(app.money(row.amount))
                        }
                    }.padding(.trailing, 10)
                }
            }
        }
    }
}
@MainActor
struct ReportRows: View {
    @EnvironmentObject var app: AppState
    let title: String
    let rows: [ReportRow]
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            HStack { Text("Name"); Spacer(); Text("Quantity").frame(width: 75, alignment: .trailing); Text("Amount").frame(width: 120, alignment: .trailing) }.font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(rows) { row in HStack { Text(row.name); Spacer(); Text("\(row.quantity)").frame(width: 75, alignment: .trailing); Text(app.money(row.amount)).monospacedDigit().frame(width: 120, alignment: .trailing) } }
            if rows.isEmpty { Text("No paid sales in this period.").foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
@MainActor
struct SalesView: View {
    @EnvironmentObject var app: AppState
    @State private var period = ReportPeriod.month
    @State private var start = Date()
    @State private var end = Date()
    @State private var report = ReportSummary()
    @State private var salesMode = SalesDisplayMode.grossSales
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title: "Sales reports", subtitle: "Collected payments by local calendar date. Unpaid and cancelled orders are excluded.")
                DateRangeControl(period: $period, start: $start, end: $end)
                SalesResultPanel(mode: $salesMode, report: report)
                HStack { MetricCard(label: "Total collected", value: app.money(report.sales), symbol: "banknote"); MetricCard(label: "Recorded expenses", value: app.money(report.expenses), symbol: "arrow.up.right"); MetricCard(label: "After recorded expenses", value: app.money(report.afterExpenses), symbol: "chart.bar") }
                Text("Sales After Recorded Expenses is not net profit. Discounts are allocated across products and categories; those amounts exclude delivery charges, which are included in collections.").font(.caption).foregroundStyle(.secondary)
                Panel {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Daily collections · before expenses").font(.headline)
                        SalesChart(rows: report.dailySales).frame(height: 260)
                    }
                }
                Panel { ReportRows(title: "Products", rows: report.topProducts) }
                Panel { ReportRows(title: "Categories", rows: report.categories) }
                Panel { ReportRows(title: "Daily collections", rows: report.dailySales) }
            }.padding(26)
        }.onAppear { load() }.onChange(of: period) { _ in load() }.onChange(of: start) { _ in load() }.onChange(of: end) { _ in load() }.onChange(of: app.revision) { _ in load() }
    }
    private func load() { guard let session = app.session else { return }; let range = period.bounds(start: start, end: end); app.run { report = try app.reporting.summary(session: session, from: range.0, to: range.1) } }
}
@MainActor
struct ExpensesView: View {
    @EnvironmentObject var app: AppState
    @State private var period = ReportPeriod.month
    @State private var start = Date()
    @State private var end = Date()
    @State private var rows: [Expense] = []
    @State private var total: Money = 0
    @State private var adding = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { PageTitle(title: "Recorded expenses", subtitle: "Keep a clear record of money spent on the restaurant."); Spacer(); Button { adding = true } label: { Label("Add Expense", systemImage: "plus") }.buttonStyle(.borderedProminent) }
            DateRangeControl(period: $period, start: $start, end: $end)
            HStack { Text("TOTAL IN PERIOD").font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Text(app.money(total)).font(.title.bold()).foregroundStyle(SpotTheme.gold) }
            Table(rows) { TableColumn("Date") { Text($0.date, format: .dateTime.year().month(.abbreviated).day()) }.width(140); TableColumn("Description", value: \.description); TableColumn("Amount") { Text(app.money($0.amount)).monospacedDigit() }.width(130) }.overlay { if rows.isEmpty { EmptyState(symbol: "banknote", title: "No expenses recorded", detail: "Add salaries, utilities, supplies and other expenses as they occur.") } }
        }.padding(26).onAppear { load() }.onChange(of: period) { _ in load() }.onChange(of: start) { _ in load() }.onChange(of: end) { _ in load() }.onChange(of: app.revision) { _ in load() }.sheet(isPresented: $adding) { ExpenseEditor() }
    }
    private func load() { guard let session = app.session else { return }; let range = period.bounds(start: start, end: end); app.run { rows = try app.expenses.expenses(session: session, from: range.0, to: range.1); total = try app.reporting.summary(session: session, from: range.0, to: range.1).expenses } }
}
@MainActor
struct ExpenseEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var expense = Expense()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeader(title: "Add expense", subtitle: "This entry becomes part of your financial and audit history.")
            DatePicker("Date", selection: $expense.date, displayedComponents: .date)
            FieldRow("Amount (\(app.settings.currencySymbol))") { MoneyField(title: "Amount", amount: $expense.amount).frame(width: 160) }
            MultilineField(title: "Description — for example, electricity", text: $expense.description, height: 80)
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Save Expense") { guard let session = app.session else { return }; if app.run({ _ = try app.expenses.add(session: session, expense: expense); app.revision += 1 }) { dismiss() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(expense.amount <= 0 || expense.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(26).frame(width: 490)
    }
}
@MainActor
struct AuditView: View {
    @EnvironmentObject var app: AppState
    @State private var entries: [AuditEntry] = []
    @State private var search = ""
    @State private var limit = 500
    private var filtered: [AuditEntry] { search.isEmpty ? entries : entries.filter { "\($0.username) \($0.action) \($0.entity) \($0.details)".localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { PageTitle(title: "Audit log", subtitle: "A history of important changes and transactions."); Spacer(); Button("Refresh") { load() } }
            TextField("Search user, action or details…", text: $search).textFieldStyle(.roundedBorder)
            Table(filtered) {
                TableColumn("When") { Text($0.date.formatted(date: .abbreviated, time: .shortened)).font(.caption) }.width(155)
                TableColumn("User", value: \.username).width(95)
                TableColumn("Action", value: \.action).width(150)
                TableColumn("Entity", value: \.entity).width(100)
                TableColumn("Details") { Text($0.details).textSelection(.enabled).help($0.details) }
            }
            HStack { Text("Showing up to \(limit) latest entries").font(.caption).foregroundStyle(.secondary); Spacer(); if entries.count >= limit { Button("Load More") { limit += 500; load() } } }
        }.padding(26).onAppear { load() }.onChange(of: app.revision) { _ in load() }
    }
    private func load() { guard let session = app.session else { return }; app.run { entries = try app.catalog.audit(session: session, limit: limit) } }
}
