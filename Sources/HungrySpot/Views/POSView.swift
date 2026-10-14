import SwiftUI
import HungrySpotCore

private struct ConfigurationRequest: Identifiable {
    let id = UUID()
    let product: Product
    let line: CartLine
}
@MainActor
struct POSView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var categoryID: Int64?
    @State private var visible: [Product] = []
    @State private var deals: [Int64: Deal] = [:]
    @State private var configuration: ConfigurationRequest?
    @FocusState private var searchFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack { PageTitle(title: "Make something delicious.", subtitle: "Choose a favourite to start an order."); Spacer(); StatusBadge(text: "LIVE MENU", color: .green) }
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(SpotTheme.gold)
                    TextField("Search menu, category or flavour…", text: $search).textFieldStyle(.plain).focused($searchFocused)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                    Text("⌘F").font(.caption).foregroundStyle(.tertiary)
                }.padding(14).background(SpotTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        categoryButton("All items", symbol: "square.grid.2x2", id: nil)
                        ForEach(app.categories.filter { $0.parentID == nil && $0.isActive }) { category in categoryButton(category.name, symbol: category.icon, id: category.id) }
                    }
                }
                if visible.isEmpty { EmptyState(symbol: "magnifyingglass", title: "No menu items found", detail: "Try another search or category. You can manage availability in Menu.") }
                else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175, maximum: 250), spacing: 14)], spacing: 14) {
                            ForEach(visible) { product in
                                POSProductCard(product: product, deal: deals[product.id]) { choose(product) }
                            }
                        }.padding(.bottom, 20)
                    }
                }
            }.padding(24).frame(maxWidth: .infinity)
            Divider()
            cart.frame(width: 340)
        }
        .onAppear { load() }
        .onChange(of: search) { _ in load() }
        .onChange(of: categoryID) { _ in load() }
        .onChange(of: app.revision) { _ in load() }
        .onChange(of: app.searchRequested) { _ in searchFocused = true }
        .onChange(of: app.draft.type) { newValue in app.draft.deliveryCharge = newValue == .delivery ? app.settings.defaultDeliveryCharge : 0 }
        .sheet(item: $configuration) { request in ItemConfigurationView(product: request.product, initial: request.line) }
    }
    private func categoryButton(_ title: String, symbol: String, id: Int64?) -> some View {
        Button { categoryID = id } label: { Label(title, systemImage: SpotTheme.symbol(symbol)).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 13).padding(.vertical, 11).background(categoryID == id ? SpotTheme.orange : SpotTheme.panel, in: Capsule()).foregroundStyle(categoryID == id ? Color.white : Color.secondary) }.buttonStyle(.plain)
    }
    private var cart: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { VStack(alignment: .leading, spacing: 3) { Text("Current order").font(.title3.bold()); Text("NEW · Not yet punched").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { app.requestNewOrder() } label: { Image(systemName: "plus.square") }.buttonStyle(.plain).help("New order · ⌘N") }
            Picker("Order type", selection: $app.draft.type) { ForEach(OrderType.allCases, id: \.self) { Text($0.rawValue).font(.caption).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            if app.draft.lines.isEmpty { EmptyState(symbol: "bag", title: "Ready when you are", detail: "Add menu items to build this order.") }
            else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(Array(app.draft.lines.enumerated()), id: \.element.id) { index, line in cartLine(index: index, line: line) }
                        if app.draft.type == .delivery { deliveryFields }
                        MultilineField(title: "Order notes", text: $app.draft.notes, height: 54)
                    }.padding(.vertical, 5)
                }
            }
            Spacer(minLength: 0)
            Divider()
            VStack(spacing: 9) {
                if let quote = app.quote {
                    totalRow("Subtotal", quote.subtotal)
                    if app.draft.type == .delivery { totalRow("Delivery", quote.deliveryCharge) }
                }
                if app.canDiscount { HStack { Text("Discount").foregroundStyle(.secondary); Spacer(); MoneyField(title: "Discount amount", amount: $app.draft.discount).frame(width: 90) } }
                else if app.draft.discount > 0 { HStack { Text("Discount").foregroundStyle(.secondary); Spacer(); Text(app.money(app.draft.discount)); Button("Remove") { app.draft.discount = 0 } } }
                if let quote = app.quote {
                    Divider()
                    HStack { Text("TOTAL").font(.headline); Spacer(); Text(app.money(quote.total)).font(.system(size: 25, weight: .bold, design: .rounded)).foregroundStyle(SpotTheme.gold) }
                }
            }
            if let error = app.quoteError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Button { app.punch() } label: { HStack { Image(systemName: "paperplane.fill"); Text("PUNCH ORDER").fontWeight(.bold); Spacer(); Image(systemName: "arrow.right") }.padding(.vertical, 9).frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(app.draft.lines.isEmpty || app.quote == nil || invalidDeliveryPhone)
            Text("Saved orders are available in Orders.").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }.padding(20).background(SpotTheme.panel.opacity(0.45))
    }
    private func cartLine(index: Int, line: CartLine) -> some View {
        let item = app.quote?.items.indices.contains(index) == true ? app.quote?.items[index] : nil
        let product = app.products.first { $0.id == line.productID }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) { Text(item?.productName ?? product?.name ?? "Menu item").fontWeight(.semibold); if let variant = item?.variantName { Text(variant).font(.caption).foregroundStyle(.secondary) } }
                Spacer(minLength: 4)
                if let item { Text(app.money(item.subtotal)).fontWeight(.semibold).monospacedDigit() }
            }
            if let item { ForEach(Array(item.options.filter { !(item.variantName != nil && $0.unitPrice == 0 && $0.name.hasPrefix("Selected variant: ")) }.enumerated()), id: \.offset) { _, option in HStack { Text("\(option.quantity) × \(option.name)"); Spacer(); if option.unitPrice > 0 { Text(app.money(option.unitPrice)) } }.font(.caption).foregroundStyle(.secondary) } }
            if !line.notes.isEmpty { Text(line.notes).font(.caption).foregroundStyle(SpotTheme.gold) }
            HStack(spacing: 12) {
                QuantityControl(title: "Quantity", value: quantityBinding(for: line), range: 1...999, showsTitle: false)
                Spacer()
                Button("Edit") { if let product { configuration = ConfigurationRequest(product: product, line: line) } }.font(.caption)
                Button(role: .destructive) { app.draft.lines.removeAll { $0.id == line.id } } label: { Image(systemName: "trash") }.help("Remove item")
            }.controlSize(.small)
            Divider().padding(.top, 5)
        }
    }
    private func quantityBinding(for line: CartLine) -> Binding<Int> {
        Binding(
            get: { app.draft.lines.first { $0.id == line.id }?.quantity ?? line.quantity },
            set: { value in
                if let index = app.draft.lines.firstIndex(where: { $0.id == line.id }) {
                    app.draft.lines[index].quantity = value
                }
            }
        )
    }
    private var invalidDeliveryPhone: Bool {
        app.draft.type == .delivery && !PakistanMobileNumber.isValid(app.draft.customerPhone)
    }
    private var deliveryFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Delivery details", systemImage: "bicycle").font(.headline)
            TextField("Customer name · required", text: $app.draft.customerName)
            TextField("Phone · required", text: $app.draft.customerPhone)
            if invalidDeliveryPhone {
                Text("Enter a valid Pakistani mobile number.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MultilineField(title: "Address · required", text: $app.draft.customerAddress, height: 54)
            Text("Delivery charge").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 63))], spacing: 6) { ForEach(app.settings.quickDeliveryCharges, id: \.self) { value in Button(app.money(value)) { app.draft.deliveryCharge = value }.controlSize(.small).tint(app.draft.deliveryCharge == value ? SpotTheme.orange : .gray) } }
            MoneyField(title: "Custom delivery amount", amount: $app.draft.deliveryCharge)
        }.textFieldStyle(.roundedBorder).padding(12).background(SpotTheme.background, in: RoundedRectangle(cornerRadius: 10))
    }
    private func totalRow(_ label: String, _ amount: Money) -> some View { HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(app.money(amount)).monospacedDigit() } }
    private func choose(_ product: Product) {
        let line = CartLine(productID: product.id)
        if product.kind == .normal { app.add(line) }
        else { configuration = ConfigurationRequest(product: product, line: line) }
    }
    private func load() {
        guard let session = app.session else { return }
        app.run {
            let products = try app.catalog.products(session: session, search: search, categoryID: categoryID, includeInactive: false)
            var loadedDeals: [Int64: Deal] = [:]
            for product in products where product.kind == .deal {
                loadedDeals[product.id] = try app.catalog.deal(session: session, productID: product.id)
            }
            deals = loadedDeals
            visible = products
        }
    }
}

@MainActor
private struct POSProductCard: View {
    @EnvironmentObject var app: AppState
    let product: Product
    let deal: Deal?
    let choose: () -> Void

    private var needsReview: Bool { product.kind == .deal && (deal == nil || deal?.needsReview == true) }
    private var componentsAvailable: Bool {
        guard product.kind == .deal else { return true }
        guard let deal, !deal.slots.isEmpty else { return false }
        return deal.slots.allSatisfy { slot in
            (1...100).contains(slot.quantity)
                && (slot.requiresSelection || slot.choices.count == 1)
                && slot.choices.contains { choiceAvailable($0) }
        }
    }
    private var canChoose: Bool { product.isAvailable && !needsReview && componentsAvailable }
    private var availabilityText: String {
        if !product.isAvailable { return "SOLD OUT" }
        if needsReview { return "NEEDS REVIEW" }
        if !componentsAvailable { return "UNAVAILABLE" }
        return "AVAILABLE"
    }
    private var componentsText: String {
        if !product.description.isEmpty { return product.description }
        guard let deal, !deal.slots.isEmpty else { return "Components have not been configured." }
        return deal.slots.map { "\($0.quantity) × \($0.label)" }.joined(separator: "\n")
    }
    private var configurationText: String {
        guard let deal else { return "Ask an administrator to configure this deal." }
        if deal.needsReview {
            return deal.reviewNote.isEmpty ? "Administrator review required before sale." : deal.reviewNote
        }
        if !componentsAvailable { return "An included item or size is unavailable." }
        let selectionLabels = deal.slots.filter(\.requiresSelection).map { "\($0.quantity) × \($0.label)" }
        if !selectionLabels.isEmpty {
            let hasPizza = deal.slots.contains { slot in
                slot.choices.contains { choice in app.products.contains { $0.id == choice.productID && $0.kind == .pizza } }
            }
            return "Choose: " + selectionLabels.joined(separator: ", ") + (hasPizza ? ". Pizza extras cost extra." : ".")
        }
        return "Included items are fixed. Review the deal before adding."
    }
    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 0) {
                imageArea
                details
            }
            .background(SpotTheme.panel, in: RoundedRectangle(cornerRadius: 13))
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(product.kind == .deal ? SpotTheme.gold.opacity(0.32) : SpotTheme.border))
            .opacity(canChoose ? 1 : 0.68)
        }
        .buttonStyle(.plain)
        .disabled(!canChoose)
        .help(product.description.isEmpty ? product.name : product.description)
    }
    private var imageArea: some View {
        ZStack(alignment: .topTrailing) {
            ProductImage(product: product).frame(height: product.kind == .deal ? 76 : 104).frame(maxWidth: .infinity)
            if product.kind == .deal || !product.isAvailable {
                StatusBadge(text: availabilityText, color: canChoose ? .green : .orange).padding(8)
            }
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(product.name)
                .font(.system(size: product.kind == .deal ? 17 : 14, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if product.kind == .deal {
                Text(componentsText)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(configurationText)
                    .font(.caption)
                    .foregroundStyle(canChoose ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text((product.variants.isEmpty ? "" : "From ") + app.money(product.startingPrice))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SpotTheme.gold)
                Spacer(minLength: 2)
                Image(systemName: "plus.circle.fill").foregroundStyle(SpotTheme.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func choiceAvailable(_ choice: DealChoice) -> Bool {
        guard let component = app.products.first(where: { $0.id == choice.productID }),
              component.isActive, component.isAvailable, component.kind != .deal,
              categoryVisible(component.categoryID),
              component.subcategoryID.map(categoryVisible) ?? true else { return false }
        if component.kind == .pizza || component.kind == .variant {
            return component.variants.contains { $0.id == choice.variantID && $0.isAvailable }
        }
        return choice.variantID == nil
    }
    private func categoryVisible(_ id: Int64) -> Bool {
        guard let category = app.categories.first(where: { $0.id == id }), category.isActive else { return false }
        guard let parentID = category.parentID else { return true }
        return app.categories.contains { $0.id == parentID && $0.isActive }
    }
}

@MainActor
struct ItemConfigurationView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let product: Product
    @State private var line: CartLine
    @State private var deal: Deal?
    @State private var preview: Quote?
    @State private var validation: String?
    init(product: Product, initial: CartLine) { self.product = product; _line = State(initialValue: initial) }
    var body: some View {
        VStack(spacing: 18) {
            SheetHeader(title: product.name, subtitle: product.description.isEmpty ? "Make this order your own." : product.description)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !product.variants.isEmpty {
                        Text("Select size / variant").font(.headline)
                        ForEach(product.variants) { variant in
                            Button { line.variantID = variant.id; if variant.toppingPrice == nil { line.toppingQuantity = 0 } } label: {
                                HStack { Image(systemName: line.variantID == variant.id ? "largecircle.fill.circle" : "circle"); Text(variant.name); Spacer(); Text(app.money(variant.price)).fontWeight(.semibold); if !variant.isAvailable { Text("Unavailable").font(.caption) } }.padding(13).background(line.variantID == variant.id ? SpotTheme.burgundy : SpotTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).disabled(!variant.isAvailable)
                        }
                    }
                    if product.kind == .pizza { pizzaExtras(toppings: $line.toppingQuantity, dip: $line.dipSauce, variant: product.variants.first { $0.id == line.variantID }) }
                    if let deal {
                        if deal.needsReview { Label(deal.reviewNote.isEmpty ? "An administrator must review this deal before it can be sold." : deal.reviewNote, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        ForEach(Array(line.dealSelections.enumerated()), id: \.offset) { index, selection in dealUnit(index: index, selection: selection, deal: deal) }
                        if deal.slots.isEmpty { Text("This deal has no configured components. Ask an administrator to complete it.").foregroundStyle(.orange) }
                    }
                    Divider()
                    QuantityControl(title: "Quantity", value: $line.quantity, range: 1...999)
                    MultilineField(title: "Kitchen notes — optional", text: $line.notes)
                }.padding(.vertical, 4)
            }
            if let preview {
                Panel { VStack(spacing: 8) {
                    if let item = preview.items.first { HStack { Text("Base per item").foregroundStyle(.secondary); Spacer(); Text(app.money(item.unitPrice)) }; HStack { Text("Extras per item").foregroundStyle(.secondary); Spacer(); Text(app.money(item.extraPrice)) } }
                    HStack { Text("Item total").font(.headline); Spacer(); Text(app.money(preview.total)).font(.title2.bold()).foregroundStyle(SpotTheme.gold) }
                } }
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(app.draft.lines.contains { $0.id == line.id } ? "Update Item" : "Add to Order") { app.add(line); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(preview == nil) }
        }.padding(26).frame(width: 580, height: 610).background(SpotTheme.background)
        .onAppear { load() }.onChange(of: line) { _ in recalculate() }
    }
    private func pizzaExtras(toppings: Binding<Int>, dip: Binding<Bool>, variant: ProductVariant?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Extra topping").fontWeight(.semibold); Spacer(); if let price = variant?.toppingPrice { Text(app.money(price) + " each").foregroundStyle(.secondary) } else { Text("Not configured for this size").font(.caption).foregroundStyle(.orange) } }
            QuantityControl(title: "Extra toppings", value: toppings, range: 0...99).disabled(variant?.toppingPrice == nil)
            Toggle("Dip sauce · +\(app.money(app.settings.dipSaucePrice))", isOn: dip)
        }.padding(14).background(SpotTheme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private func dealUnit(index: Int, selection: DealSelection, deal: Deal) -> some View {
        if let slot = deal.slots.first(where: { $0.id == selection.slotID }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(slot.label) · \(selection.unitIndex + 1) of \(slot.quantity)").font(.headline)
                Picker("Selection", selection: Binding<String>(get: { DealChoice(productID: line.dealSelections[index].productID, variantID: line.dealSelections[index].variantID).id }, set: { id in
                    if let choice = slot.choices.first(where: { $0.id == id }) { line.dealSelections[index].productID = choice.productID; line.dealSelections[index].variantID = choice.variantID; line.dealSelections[index].toppingQuantity = 0; line.dealSelections[index].dipSauce = false }
                })) { ForEach(slot.choices) { choice in Text(choiceTitle(choice)).tag(choice.id) } }.disabled(slot.choices.count < 2)
                if let selectedProduct = app.products.first(where: { $0.id == selection.productID }), selectedProduct.kind == .pizza {
                    pizzaExtras(toppings: Binding(get: { line.dealSelections[index].toppingQuantity }, set: { line.dealSelections[index].toppingQuantity = $0 }), dip: Binding(get: { line.dealSelections[index].dipSauce }, set: { line.dealSelections[index].dipSauce = $0 }), variant: selectedProduct.variants.first { $0.id == selection.variantID })
                }
            }.padding(14).background(SpotTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private func choiceTitle(_ choice: DealChoice) -> String {
        guard let product = app.products.first(where: { $0.id == choice.productID }) else { return "Unavailable item" }
        let variant = product.variants.first { $0.id == choice.variantID }
        return product.name + (variant.map { " · \($0.name)" } ?? "") + (product.isAvailable && product.isActive && (variant?.isAvailable ?? true) ? "" : " · unavailable")
    }
    private func load() {
        if line.variantID == nil { line.variantID = product.variants.first(where: \.isAvailable)?.id }
        if product.kind == .deal, let session = app.session {
            app.run {
                let loaded = try app.catalog.deal(session: session, productID: product.id); deal = loaded
                if line.dealSelections.isEmpty {
                    line.dealSelections = loaded.slots.flatMap { slot in (0..<max(0, slot.quantity)).compactMap { unit in slot.choices.first.map { DealSelection(slotID: slot.id, unitIndex: unit, productID: $0.productID, variantID: $0.variantID) } } }
                }
            }
        }
        recalculate()
    }
    private func recalculate() {
        guard let session = app.session else { return }
        do { preview = try app.pricing.calculate(session: session, draft: OrderDraft(lines: [line])); validation = nil }
        catch { preview = nil; validation = error.localizedDescription }
    }
}
