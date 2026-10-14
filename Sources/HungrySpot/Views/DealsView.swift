import SwiftUI
import HungrySpotCore

private struct DealEditRequest: Identifiable {
    var id: Int64 { product.id }
    let product: Product
    let deal: Deal
}
private struct SlotDraft: Identifiable {
    let id = UUID()
    var value: DealSlot
}

@MainActor
struct DealsView: View {
    @EnvironmentObject var app: AppState
    @State private var bundles: [Int64: Deal] = [:]
    @State private var editing: DealEditRequest?
    @State private var creating: Product?
    @State private var search = ""
    private var rows: [Product] { app.products.filter { $0.kind == .deal && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { PageTitle(title: "Deals & bundles", subtitle: "Set included items and eligible flavours for each offer."); Spacer(); Button { creating = Product(categoryID: app.categories.first { $0.name == "Deals" && $0.parentID == nil }?.id ?? app.categories.first { $0.parentID == nil }?.id ?? 0, kind: .deal) } label: { Label("Add Deal", systemImage: "plus") }.buttonStyle(.borderedProminent) }
            Panel { Label("Deals marked for review cannot be sold. Confirm pizza sizes and eligible flavours against your own offers before enabling them.", systemImage: "checkmark.shield").foregroundStyle(SpotTheme.gold).frame(maxWidth: .infinity, alignment: .leading) }
            TextField("Search deals…", text: $search).textFieldStyle(.roundedBorder)
            List(rows) { product in
                HStack(spacing: 15) {
                    ProductImage(product: product).frame(width: 65, height: 58).clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(product.name).font(.headline)
                        Text(product.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let bundle = bundles[product.id] { Text("\(bundle.slots.count) component groups").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(app.money(product.basePrice)).fontWeight(.bold).foregroundStyle(SpotTheme.gold)
                    if !product.isActive { StatusBadge(text: "ARCHIVED", color: .gray) }
                    else if bundles[product.id]?.needsReview != false { StatusBadge(text: "NEEDS REVIEW", color: .orange) }
                    else { StatusBadge(text: product.isAvailable ? "READY" : "SOLD OUT", color: product.isAvailable ? .green : .orange) }
                    Button("Configure") { if let deal = bundles[product.id] { editing = DealEditRequest(product: product, deal: deal) } }
                }.padding(.vertical, 10)
            }.listStyle(.inset)
            Text("Edit names, prices, photos and availability in Menu. Each pizza inside a deal can be configured separately by the cashier.").font(.caption).foregroundStyle(.secondary)
        }.padding(26).onAppear { load() }.onChange(of: app.revision) { _ in load() }
        .sheet(item: $editing) { DealEditor(product: $0.product, deal: $0.deal) }
        .sheet(item: $creating) { ProductEditor(product: $0) }
    }
    private func load() { guard let session = app.session else { return }; app.run { var loaded: [Int64: Deal] = [:]; for product in app.products where product.kind == .deal { loaded[product.id] = try app.catalog.deal(session: session, productID: product.id) }; bundles = loaded } }
}

@MainActor
struct DealEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let product: Product
    @State private var slots: [SlotDraft]
    @State private var holdForReview: Bool
    @State private var reviewNote: String
    @State private var validation: String?
    @State private var confirming = false
    init(product: Product, deal: Deal) {
        self.product = product
        _slots = State(initialValue: deal.slots.map { SlotDraft(value: $0) })
        _holdForReview = State(initialValue: deal.needsReview)
        _reviewNote = State(initialValue: deal.reviewNote)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: product.name, subtitle: "Fixed bundle price: \(app.money(product.basePrice)). Pizza extras are added separately.")
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Toggle("Hold for administrator review", isOn: $holdForReview)
                    MultilineField(title: "Review note / unresolved details", text: $reviewNote)
                    if holdForReview { Label("This deal remains unavailable for sale until review is cleared and confirmed.", systemImage: "pause.circle").font(.caption).foregroundStyle(.orange) }
                    ForEach($slots) { $slot in
                        DealSlotEditor(slot: $slot.value) { slots.removeAll { $0.id == slot.id } }
                    }
                    Button { slots.append(SlotDraft(value: DealSlot(dealID: product.id, label: "New component"))) } label: { Label("Add Component Group", systemImage: "plus.circle") }
                    Text("For two pizzas, use one pizza group with quantity 2. Each pizza then gets its own flavour and extras selection. A fixed item, such as one drink size, needs one eligible choice.").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(holdForReview ? "Save for Review" : "Review & Enable") { if holdForReview { save() } else { confirming = true } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 770, height: 610).background(SpotTheme.background)
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(title: "Confirm this deal", subtitle: "\(product.name) · \(app.money(product.basePrice))")
                Text("Confirm that these component quantities, sizes and flavour choices match the offer you intend to sell.").foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        ForEach(slots) { slot in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(slot.value.quantity) × \(slot.value.label)").font(.headline)
                                Text(slot.value.choices.isEmpty ? "No choices configured" : slot.value.choices.map { choiceTitle($0) }.joined(separator: ", ")).foregroundStyle(slot.value.choices.isEmpty ? Color.orange : Color.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 330)
                Text("After confirmation, this deal can be sold when its product and chosen components are active and available.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Back to Editing") { confirming = false }.keyboardShortcut(.cancelAction); Spacer(); Button("Confirm & Save Deal") { confirming = false; save() }.buttonStyle(.borderedProminent).disabled(slots.isEmpty || slots.contains { $0.value.choices.isEmpty }) }
            }.padding(26).frame(width: 570, height: 610)
        }
    }
    private func choiceTitle(_ choice: DealChoice) -> String {
        guard let product = app.products.first(where: { $0.id == choice.productID }) else { return "Missing product" }
        return product.name + (product.variants.first { $0.id == choice.variantID }.map { " · \($0.name)" } ?? "")
    }
    private func save() {
        guard let session = app.session else { return }
        do {
            try app.catalog.saveDeal(session: session, deal: Deal(productID: product.id, needsReview: holdForReview, reviewNote: reviewNote, slots: slots.map(\.value)))
            try app.reloadCatalog(); app.notice = holdForReview ? "Deal saved and held for review." : "Deal components confirmed and saved."; dismiss()
        } catch { validation = error.localizedDescription }
    }
}

@MainActor
private struct DealSlotEditor: View {
    @EnvironmentObject var app: AppState
    @Binding var slot: DealSlot
    let remove: () -> Void
    @State private var productID: Int64?
    @State private var variantID: Int64?
    private var selectedProduct: Product? { app.products.first { $0.id == productID } }
    private var candidate: DealChoice? {
        guard let selectedProduct else { return nil }
        if selectedProduct.kind == .pizza || selectedProduct.kind == .variant {
            guard let variantID, selectedProduct.variants.contains(where: { $0.id == variantID }) else { return nil }
            return DealChoice(productID: selectedProduct.id, variantID: variantID)
        }
        return DealChoice(productID: selectedProduct.id)
    }
    private var canAdd: Bool {
        guard let candidate else { return false }
        return !slot.choices.contains(candidate) && (slot.requiresSelection || slot.choices.isEmpty)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { TextField("Component label", text: $slot.label).font(.headline); Spacer(); Button(role: .destructive, action: remove) { Image(systemName: "trash") }.help("Remove component group") }
            HStack {
                QuantityControl(title: "Quantity", value: $slot.quantity, range: 1...100)
                Spacer()
                Toggle("Cashier chooses each item", isOn: $slot.requiresSelection)
            }
            if !slot.requiresSelection { Text("Fixed component: select exactly one product and size.").font(.caption).foregroundStyle(.secondary) }
            ForEach(slot.choices) { choice in
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(SpotTheme.gold)
                    Text(title(choice)).font(.subheadline)
                    Spacer()
                    Button { slot.choices.removeAll { $0.id == choice.id } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Remove eligible choice")
                }.padding(9).background(SpotTheme.background, in: RoundedRectangle(cornerRadius: 7))
            }
            HStack {
                Picker("Product", selection: $productID) {
                    Text("Choose product").tag(nil as Int64?)
                    ForEach(app.products.filter { $0.kind != .deal }) { Text($0.name + ($0.isActive && $0.isAvailable ? "" : " · unavailable")).tag(Optional($0.id)) }
                }
                if let selectedProduct, !selectedProduct.variants.isEmpty {
                    Picker("Size", selection: $variantID) {
                        Text("Choose size").tag(nil as Int64?)
                        ForEach(selectedProduct.variants) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(width: 190)
                }
                Button("Add Choice") { if let candidate { slot.choices.append(candidate); if selectedProduct?.kind == .pizza { slot.requiresSelection = true } } }.disabled(!canAdd)
            }
            if slot.choices.isEmpty { Text("No included choices yet.").font(.caption).foregroundStyle(.orange) }
        }.textFieldStyle(.roundedBorder).padding(17).background(SpotTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: productID) { _ in variantID = nil }
    }
    private func title(_ choice: DealChoice) -> String {
        guard let product = app.products.first(where: { $0.id == choice.productID }) else { return "Missing product" }
        let variant = product.variants.first { $0.id == choice.variantID }
        return product.name + (variant.map { " · \($0.name)" } ?? "") + (product.isActive && product.isAvailable && (variant?.isAvailable ?? true) ? "" : " · unavailable")
    }
}
