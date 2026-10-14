import SwiftUI
import HungrySpotCore

// Recomputed using the Mac's calendar; a local day can be 23, 24 or 25 hours.
enum OrderDateScope: String, CaseIterable {
    case today = "Today", allDates = "All Dates"

    func bounds(now: Date = Date(), calendar: Calendar = .current) throws -> DateInterval? {
        guard self == .today else { return nil }
        guard let interval = calendar.dateInterval(of: .day, for: now) else {
            throw SpotError.validation("Could not determine today's date range. Refresh Orders to retry.")
        }
        return interval
    }
}

@MainActor
struct OrdersView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var rows: [OrderRecord] = []
    @State private var search = ""
    @State private var orderType: OrderType?
    @State private var paymentFilter = OrderPaymentFilter.all
    @State private var dateScope = OrderDateScope.today
    @State private var loadedDay = Calendar.current.startOfDay(for: Date())
    @State private var offset = 0
    @State private var hasOlder = false
    private let pageSize = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            filters
            orderBrowser
        }
        .padding(24)
        .onAppear { load() }
        .onChange(of: search) { _ in resetPage() }
        .onChange(of: orderType) { _ in resetPage() }
        .onChange(of: paymentFilter) { _ in resetPage() }
        .onChange(of: dateScope) { _ in resetPage() }
        .onChange(of: app.revision) { _ in load() }
        .onChange(of: scenePhase) { phase in if phase == .active { load() } }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            if dateScope == .today && Calendar.current.startOfDay(for: now) != loadedDay { resetPage() }
        }
    }
    private var header: some View {
        HStack {
            PageTitle(title: "Orders", subtitle: "Save, collect payment and complete.")
            Spacer()
            Button { load() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Button { app.requestNewOrder() } label: { Label("New Order", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
    }
    private var filters: some View {
        VStack(spacing: 10) {
            TextField("Search order number, customer or phone…", text: $search).textFieldStyle(.roundedBorder)
            HStack(spacing: 16) {
                Picker("Type", selection: $orderType) {
                    Text("All").tag(nil as OrderType?)
                    Text("Dine-In").tag(OrderType.dineIn as OrderType?)
                    Text("Takeaway").tag(OrderType.takeaway as OrderType?)
                    Text("Delivery").tag(OrderType.delivery as OrderType?)
                }.pickerStyle(.segmented)
                Picker("Date", selection: $dateScope) {
                    ForEach(OrderDateScope.allCases, id: \.self) { scope in Text(scope.rawValue).tag(scope) }
                }.pickerStyle(.segmented).frame(width: 220)
            }
            Picker("Payment", selection: $paymentFilter) {
                Text("All").tag(OrderPaymentFilter.all)
                Text("Payment Pending").tag(OrderPaymentFilter.paymentPending)
                Text("Paid").tag(OrderPaymentFilter.paid)
                Text("Cancelled").tag(OrderPaymentFilter.cancelled)
            }.pickerStyle(.segmented)
        }
    }
    private var orderBrowser: some View {
        HSplitView {
            VStack(spacing: 0) {
                if rows.isEmpty {
                    EmptyState(symbol: "list.bullet.rectangle", title: "No matching orders", detail: "Change your filters, choose All Dates for history, or create a new order in POS.")
                } else {
                    List(rows, selection: $app.selectedOrderID) { order in
                        OrderListRow(order: order).tag(order.id)
                    }.listStyle(.inset)
                }
                pagination
            }.frame(minWidth: 300, idealWidth: 360, maxWidth: 430)
            if let id = app.selectedOrderID {
                OrderDetailView(orderID: id).id(id).frame(minWidth: 380, maxWidth: .infinity)
            } else {
                EmptyState(symbol: "receipt", title: "Select an order", detail: "See items, payment, cancellation and printing here.")
            }
        }.background(SpotTheme.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
    private var pagination: some View {
        HStack {
            Button("Newer") { offset = max(0, offset - pageSize); app.selectedOrderID = nil; load() }.disabled(offset == 0)
            Spacer()
            Text("Page \(offset / pageSize + 1)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Older") { offset += pageSize; app.selectedOrderID = nil; load() }.disabled(!hasOlder)
        }.padding(10)
    }
    private func resetPage() { offset = 0; app.selectedOrderID = nil; load() }
    private func load() {
        guard let session = app.session else { return }
        app.run {
            let interval = try dateScope.bounds()
            loadedDay = Calendar.current.startOfDay(for: Date())
            let page = try app.orders.orders(session: session, search: search, type: orderType,
                                             payment: paymentFilter, from: interval?.start, to: interval?.end,
                                             limit: pageSize + 1, offset: offset)
            hasOlder = page.count > pageSize
            rows = Array(page.prefix(pageSize))
            // Keep an explicitly opened detail visible after payment (or a Dashboard
            // selection). Changing any filter or page explicitly clears that selection.
        }
    }
}
@MainActor
private struct OrderListRow: View {
    @EnvironmentObject var app: AppState
    let order: OrderRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text(order.number).font(.headline); Spacer(); Text(app.money(order.quote.total)).fontWeight(.semibold).monospacedDigit() }
            HStack { Text(order.type.rawValue).font(.caption).foregroundStyle(.secondary); Spacer(); StatusBadge(text: order.status.rawValue, color: order.status.color) }
            HStack {
                Text(order.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Spacer()
                Text(order.customerName.isEmpty ? order.cashierName : order.customerName).lineLimit(1)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 9)
    }
}
@MainActor
struct OrderDetailView: View {
    @EnvironmentObject var app: AppState
    let orderID: Int64
    @State private var order: OrderRecord?
    @State private var paymentSheet = false
    @State private var cancelSheet = false
    @State private var reason = ""
    var body: some View {
        Group {
            if let order {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top) { VStack(alignment: .leading, spacing: 6) { Text(order.number).font(.title.bold()); Text(order.createdAt, format: .dateTime.year().month(.abbreviated).day().hour().minute()).foregroundStyle(.secondary); Text("\(order.type.rawValue) · \(order.cashierName)").font(.caption).foregroundStyle(.secondary) }; Spacer(); StatusBadge(text: order.status.rawValue, color: order.status.color) }
                        if order.type == .delivery { Panel { VStack(alignment: .leading, spacing: 7) { Label("Delivery", systemImage: "bicycle").font(.headline); Text(order.customerName); Text(order.customerPhone); Text(order.customerAddress).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) } }
                        ForEach(Array(order.quote.items.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top) { Text("\(item.quantity) × \(item.productName)").fontWeight(.semibold); Spacer(); Text(app.money(item.subtotal)).monospacedDigit() }
                                if let name = item.variantName { Text(name).font(.caption).foregroundStyle(.secondary) }
                                ForEach(Array(item.options.filter { !(item.variantName != nil && $0.unitPrice == 0 && $0.name.hasPrefix("Selected variant: ")) }.enumerated()), id: \.offset) { _, option in HStack { Text("\(option.quantity) × \(option.name)"); Spacer(); if option.unitPrice > 0 { Text(app.money(option.unitPrice) + " each") } }.font(.caption).foregroundStyle(.secondary) }
                                if !item.notes.isEmpty { Label(item.notes, systemImage: "text.bubble").font(.caption).foregroundStyle(SpotTheme.gold) }
                                Divider().padding(.top, 8)
                            }
                        }
                        if !order.notes.isEmpty { Label(order.notes, systemImage: "note.text").foregroundStyle(SpotTheme.gold) }
                        VStack(spacing: 10) { amountRow("Subtotal", order.quote.subtotal); amountRow("Delivery charge", order.quote.deliveryCharge); amountRow("Discount", order.quote.discount); HStack { Text("TOTAL").font(.headline); Spacer(); Text(app.money(order.quote.total)).font(.title2.bold()).foregroundStyle(SpotTheme.gold) } }
                        if let payment = order.payment { Label("Collected by \(payment.method.rawValue) · \(payment.createdAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption) }
                        if !order.cancellationReason.isEmpty { Label("Cancellation: " + order.cancellationReason, systemImage: "xmark.circle").foregroundStyle(.red) }
                        Divider()
                        HStack { Button { app.print(order, kitchen: true) } label: { Label("Kitchen Ticket", systemImage: "printer") }; Button { app.print(order, kitchen: false) } label: { Label("Receipt", systemImage: "printer.fill") } }
                        HStack {
                            if order.payment == nil && order.status != .cancelled { Button("Cancel Order", role: .destructive) { reason = ""; cancelSheet = true } }
                            Spacer()
                            if order.status == .paymentPending { Button("Take Payment") { paymentSheet = true }.buttonStyle(.borderedProminent).controlSize(.large) }
                            else if let next = order.status.next { Button(next == .completed ? "Complete Legacy Paid Order" : "Mark Payment Pending") { transition(next) }.buttonStyle(.borderedProminent).controlSize(.large) }
                        }
                    }.padding(24)
                }
            } else { EmptyState(symbol: "receipt", title: "Order unavailable", detail: "Refresh Orders to try loading this order again.") }
        }
        .onAppear { load() }.onChange(of: app.revision) { _ in load() }
        .sheet(isPresented: $paymentSheet) { if let order { PaymentView(order: order) } }
        .sheet(isPresented: $cancelSheet) {
            VStack(alignment: .leading, spacing: 20) {
                SheetHeader(title: "Cancel this order?", subtitle: "This will retain the order and record the cancellation reason.")
                MultilineField(title: "Reason for cancellation", text: $reason)
                HStack { Button("Keep Order") { cancelSheet = false }.keyboardShortcut(.cancelAction); Spacer(); Button("Cancel Order", role: .destructive) { transition(.cancelled); if order?.status == .cancelled { cancelSheet = false } }.disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(26).frame(width: 480)
        }
    }
    private func amountRow(_ label: String, _ amount: Money) -> some View { HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(app.money(amount)).monospacedDigit() } }
    private func load() { guard let session = app.session else { return }; app.run { order = try app.orders.order(session: session, id: orderID); app.printTarget = order } }
    private func transition(_ status: OrderStatus) { guard let session = app.session else { return }; app.run { order = try app.orders.transition(session: session, id: orderID, to: status, reason: reason); app.printTarget = order; app.revision += 1 } }
}
@MainActor
struct PaymentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let order: OrderRecord
    @State private var method = PaymentMethod.cash
    @State private var printReceipt = true
    @State private var customerPaid: Money = 0
    @State private var isSaving = false

    private var cashQuote: CashPaymentQuote? { try? CashPaymentQuote(total: order.quote.total, tendered: customerPaid) }
    private var canConfirm: Bool { !isSaving && (method != .cash || cashQuote?.canConfirm == true) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { paymentForm.padding(28) }
            Divider()
            paymentActions.padding(20)
        }.frame(width: 546, height: 570).background(SpotTheme.background)
    }
    private var paymentForm: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetHeader(title: "Take payment", subtitle: "Order \(order.number) · \(order.type.rawValue)")
            totals
            Picker("Payment method", selection: $method) {
                ForEach(PaymentMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if method == .cash { cashFields }
            Toggle("Print customer receipt after payment", isOn: $printReceipt)
            Text("Confirm after receiving payment. The order will complete automatically. Only the amount due is recorded as the sale.")
                .foregroundStyle(.secondary).font(.caption)
        }
    }
    private var paymentActions: some View {
        HStack {
            Button("Back") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
            Spacer()
            Button("Confirm Payment") { pay() }.buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction).disabled(!canConfirm)
        }
    }
    private var totals: some View {
        Panel {
            VStack(spacing: 12) {
                row("Subtotal", order.quote.subtotal)
                row("Delivery", order.quote.deliveryCharge)
                row("Discount", order.quote.discount)
                Divider()
                HStack {
                    Text("To Collect").font(.headline)
                    Spacer()
                    Text(app.money(order.quote.total)).font(.largeTitle.bold()).foregroundStyle(SpotTheme.gold)
                }
            }
        }
    }
    private var cashFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Customer Paid").fontWeight(.semibold)
                MoneyField(title: "Cash received (\(app.settings.currencySymbol))", amount: $customerPaid)
                Button("Exact") { customerPaid = order.quote.total }.help("Use the exact amount due")
            }
            if let cash = cashQuote {
                if cash.canConfirm {
                    HStack { Text("Change"); Spacer(); Text(app.money(cash.change)).font(.title2.bold()).monospacedDigit() }
                        .foregroundStyle(.green)
                } else {
                    HStack { Text("Still to collect"); Spacer(); Text(app.money(cash.shortage)).font(.title2.bold()).monospacedDigit() }
                        .foregroundStyle(SpotTheme.orange)
                    Text("Customer Paid must cover the full amount due.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Enter a valid cash amount.").font(.caption).foregroundStyle(SpotTheme.orange)
            }
        }
    }
    private func row(_ label: String, _ amount: Money) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(app.money(amount)).monospacedDigit() }
    }
    private func pay() {
        guard let session = app.session, canConfirm else { return }
        isSaving = true
        let success = app.run {
            let paid = try app.payments.pay(session: session, orderID: order.id, method: method,
                                             amount: order.quote.total, cashTendered: method == .cash ? customerPaid : nil)
            app.printTarget = paid
            app.revision += 1
            app.notice = "Payment recorded. Order \(paid.number) completed."
            if printReceipt { app.print(paid, kitchen: false) }
        }
        isSaving = false
        if success { dismiss() }
    }
}
