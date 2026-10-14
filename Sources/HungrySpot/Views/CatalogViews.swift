import SwiftUI
import HungrySpotCore

private enum CatalogVisibility: String, CaseIterable { case all = "All visibility", active = "Active", archived = "Archived" }
private enum CatalogAvailability: String, CaseIterable { case all = "All availability", available = "Available", soldOut = "Sold out" }

@MainActor
struct MenuManagementView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var categoryID: Int64?
    @State private var visibility = CatalogVisibility.all
    @State private var availability = CatalogAvailability.all
    @State private var selection: Int64?
    @State private var editing: Product?
    @State private var deleting: Product?
    private var selected: Product? { app.products.first { $0.id == selection } }
    private var rows: [Product] {
        app.products.filter { product in
            let matchesCategory = categoryID == nil || product.categoryID == categoryID || product.subcategoryID == categoryID
            let matchesVisibility = app.isAdmin ? (visibility == .all || product.isActive == (visibility == .active)) : product.isActive
            let matchesAvailability = availability == .all || product.isAvailable == (availability == .available)
            let matchesSection = product.subcategoryID.map { categoryName($0).localizedCaseInsensitiveContains(search) } ?? false
            let matchesSearch = search.isEmpty || product.name.localizedCaseInsensitiveContains(search) || categoryName(product.categoryID).localizedCaseInsensitiveContains(search) || matchesSection
            return matchesCategory && matchesVisibility && matchesAvailability && matchesSearch
        }
    }
    var body: some View {
        mainContent
            .padding(26)
            .sheet(item: $editing) { product in
                if app.isAdmin { ProductEditor(product: product) }
            }
            .confirmationDialog(
                deleteDialogTitle,
                isPresented: deleteDialogPresented,
                titleVisibility: .visible
            ) {
                Button("Delete Product", role: .destructive) {
                    if let deleting {
                        remove(deleting)
                    }
                    deleting = nil
                }

                Button("Cancel", role: .cancel) {
                    deleting = nil
                }
            } message: {
                Text("Deletion is permanent. Products used in orders or bundles must be archived instead.")
            }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerView
            filtersView
            productsTable
            footerView
        }
    }

    private var headerView: some View {
        HStack {
            PageTitle(
                title: "Your menu, your way.",
                subtitle: app.isAdmin
                    ? "Prices, photos and availability update the POS as soon as you save."
                    : "Select a product to mark it available or sold out. Changes update the POS immediately."
            )

            Spacer()

            if app.isAdmin {
                Button {
                    editing = Product(
                        categoryID: app.categories.first { $0.parentID == nil }?.id ?? 0
                    )
                } label: {
                    Label("Add Product", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var filtersView: some View {
        HStack {
            TextField(
                "Search products, categories or sections…",
                text: $search
            )
            .textFieldStyle(.roundedBorder)

            categoryPicker
            if app.isAdmin { visibilityPicker }
            availabilityPicker
        }
    }

    private var categoryPicker: some View {
        Picker("Category", selection: $categoryID) {
            Text("All categories")
                .tag(nil as Int64?)

            ForEach(app.categories) { category in
                Text(
                    (category.parentID == nil ? "" : "  ↳ ") + category.name
                )
                .tag(Optional(category.id))
            }
        }
        .labelsHidden()
        .frame(width: 190)
        .help("Filter by category or section")
    }

    private var visibilityPicker: some View {
        Picker("Visibility", selection: $visibility) {
            ForEach(CatalogVisibility.allCases, id: \.self) { value in
                Text(value.rawValue)
                    .tag(value)
            }
        }
        .labelsHidden()
        .frame(width: 135)
        .help("Filter active or archived products")
    }

    private var availabilityPicker: some View {
        Picker("Availability", selection: $availability) {
            ForEach(CatalogAvailability.allCases, id: \.self) { value in
                Text(value.rawValue)
                    .tag(value)
            }
        }
        .labelsHidden()
        .frame(width: 135)
        .help("Filter available or sold-out products")
    }

    private var productsTable: some View {
        Table(rows, selection: $selection) {
            TableColumn("Product", value: \.name)
                .width(min: 210, ideal: 300)

            TableColumn("Category") { product in
                Text(categoryName(product.categoryID))
            }
            .width(110)

            TableColumn("Type") { product in
                Text(product.kind.displayName)
            }
            .width(90)

            TableColumn("Price") { product in
                Text(priceString(product))
            }
            .width(140)

            TableColumn("Status") { product in
                Text(statusString(product))
            }
            .width(100)
        }
    }

    private func priceString(_ product: Product) -> String {
        let prefix = product.variants.isEmpty ? "" : "From "
        return prefix + app.money(product.startingPrice)
    }

    private func statusString(_ product: Product) -> String {
        if !product.isActive {
            return "ARCHIVED"
        } else if product.isAvailable {
            return "AVAILABLE"
        } else {
            return "SOLD OUT"
        }
    }

    private var footerView: some View {
        HStack {
            Text("\(rows.count) products")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let selected {
                selectedActions(selected)
            }
        }
    }

    private func selectedActions(_ product: Product) -> some View {
        Group {
            if app.isAdmin {
                Button("Edit") { editing = product }
                Button("Duplicate") { duplicate(product) }
            }

            Button(
                product.isAvailable
                    ? "Mark Sold Out"
                    : "Mark Available"
            ) {
                changeAvailability(product)
            }

            if app.isAdmin {
                Button(product.isActive ? "Archive" : "Restore") { archive(product) }
                Button("Delete…", role: .destructive) { deleting = product }
            }
        }
    }

    private var deleteDialogTitle: String {
        "Delete \(deleting?.name ?? "product")?"
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: {
                deleting != nil
            },
            set: { presented in
                if !presented {
                    deleting = nil
                }
            }
        )
    }

    private func categoryName(_ id: Int64) -> String { app.categories.first { $0.id == id }?.name ?? "Category" }
    private func duplicate(_ product: Product) { guard let session = app.session else { return }; app.run { editing = try app.catalog.duplicateProduct(session: session, id: product.id); try app.reloadCatalog(); app.notice = "A copy was created as archived. Review and enable it when ready." } }
    private func changeAvailability(_ product: Product) {
        guard let session = app.session else { return }
        app.run {
            let updated = try app.catalog.setProductAvailability(session: session, productID: product.id, isAvailable: !product.isAvailable)
            try app.reloadCatalog()
            app.notice = "\(updated.name) marked \(updated.isAvailable ? "available" : "sold out")."
        }
    }
    private func archive(_ product: Product) { var changed = product; changed.isActive.toggle(); save(changed) }
    private func save(_ product: Product) { guard let session = app.session else { return }; app.run { _ = try app.catalog.saveProduct(session: session, product: product); try app.reloadCatalog() } }
    private func remove(_ product: Product) { guard let session = app.session else { return }; app.run { try app.catalog.deleteProduct(session: session, id: product.id); selection = nil; try app.reloadCatalog() } }
}

extension ProductKind {
    var displayName: String { switch self { case .normal: return "Single price"; case .variant: return "Variants"; case .pizza: return "Pizza"; case .deal: return "Deal" } }
}

private struct VariantDraft: Identifiable {
    let id = UUID()
    var value: ProductVariant
}

@MainActor
struct ProductEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var product: Product
    @State private var variants: [VariantDraft]
    @State private var validation: String?
    init(product: Product) { _product = State(initialValue: product); _variants = State(initialValue: product.variants.map { VariantDraft(value: $0) }) }
    private var mainCategories: [HungrySpotCore.Category] { app.categories.filter { $0.parentID == nil } }
    private var sections: [HungrySpotCore.Category] { app.categories.filter { $0.parentID == product.categoryID } }
    private var usesVariants: Bool { product.kind == .variant || product.kind == .pizza }
    var body: some View {
        VStack(spacing: 18) {
            SheetHeader(title: product.id == 0 ? "Add product" : "Edit \(product.name)", subtitle: "Amounts are in \(app.settings.currencySymbol). Changes apply to future orders.")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 22) {
                        VStack(alignment: .leading, spacing: 13) {
                            TextField("Product name", text: $product.name)
                            Picker("Main category", selection: $product.categoryID) { if product.categoryID == 0 { Text("Choose a category").tag(Int64(0)) }; ForEach(mainCategories) { Text($0.name).tag($0.id) } }
                            Picker("Section", selection: $product.subcategoryID) { Text("None").tag(nil as Int64?); ForEach(sections) { Text($0.name).tag(Optional($0.id)) } }
                            Picker("Product type", selection: $product.kind) { ForEach(ProductKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                            MultilineField(title: "Description / ingredients", text: $product.description)
                            TextField("Display order", value: $product.displayOrder, format: .number)
                            Toggle("Show on menu", isOn: $product.isActive)
                            Toggle("Available to order", isOn: $product.isAvailable)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        ImagePickerField(path: $product.imagePath).frame(width: 225)
                    }
                    if usesVariants { variantSection }
                    else {
                        FieldRow("Price") { MoneyField(title: "Price", amount: $product.basePrice).frame(width: 175) }
                        if !variants.isEmpty { Label("Saving as a single-price item or deal removes its variants. Used variants cannot be removed.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
                    }
                    if product.kind == .deal { Label("Save this product, then configure its components in Deals. New deals are held for review until confirmed.", systemImage: "gift").font(.caption).foregroundStyle(SpotTheme.gold) }
                }.textFieldStyle(.roundedBorder).padding(.vertical, 5)
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Save Product") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(product.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || product.categoryID == 0) }
        }.padding(26).frame(width: 800, height: 610).background(SpotTheme.background)
        .onChange(of: product.categoryID) { _ in product.subcategoryID = nil }
    }
    private var variantSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Sizes & variants").font(.headline); Spacer(); Button { variants.append(VariantDraft(value: ProductVariant(displayOrder: variants.count))) } label: { Label("Add Variant", systemImage: "plus") } }
            if variants.isEmpty { Text("Add at least one size or variant before saving.").foregroundStyle(.orange) }
            ForEach($variants) { $draft in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Variant name", text: $draft.value.name)
                        MoneyField(title: "Price", amount: $draft.value.price).frame(width: 110)
                        Toggle("Available", isOn: $draft.value.isAvailable).fixedSize()
                        Button(role: .destructive) { variants.removeAll { $0.id == draft.id } } label: { Image(systemName: "trash") }.help("Remove variant")
                    }
                    HStack {
                        TextField("Display order", value: $draft.value.displayOrder, format: .number).frame(width: 140)
                        if product.kind == .pizza {
                            Toggle("Allow extra toppings", isOn: Binding(get: { draft.value.toppingPrice != nil }, set: { draft.value.toppingPrice = $0 ? 0 : nil }))
                            if draft.value.toppingPrice != nil { MoneyField(title: "Per topping", amount: Binding(get: { draft.value.toppingPrice ?? 0 }, set: { draft.value.toppingPrice = $0 })).frame(width: 110) }
                        }
                    }
                }.padding(14).background(SpotTheme.panel, in: RoundedRectangle(cornerRadius: 10))
            }
            Text("For pizza, configure the topping price separately for each size. An unavailable variant stays in historical orders.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func save() {
        guard let session = app.session else { return }
        do {
            var value = product; value.variants = usesVariants ? variants.map(\.value) : []
            _ = try app.catalog.saveProduct(session: session, product: value)
            try app.reloadCatalog(); app.notice = "\(value.name) saved."; dismiss()
        } catch { validation = error.localizedDescription }
    }
}

@MainActor
struct CategoriesView: View {
    @EnvironmentObject var app: AppState
    @State private var editing: HungrySpotCore.Category?
    @State private var deleting: HungrySpotCore.Category?
    private var ordered: [HungrySpotCore.Category] { app.categories.filter { $0.parentID == nil }.flatMap { root in [root] + app.categories.filter { $0.parentID == root.id } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { PageTitle(title: "Categories & sections", subtitle: "Organize the menu and control which groups appear at the POS."); Spacer(); Button { editing = HungrySpotCore.Category() } label: { Label("Add Category", systemImage: "plus") }.buttonStyle(.borderedProminent) }
            List(ordered) { category in
                HStack(spacing: 14) {
                    Image(systemName: SpotTheme.symbol(category.icon)).foregroundStyle(SpotTheme.gold).frame(width: 25).padding(.leading, category.parentID == nil ? 0 : 30)
                    VStack(alignment: .leading, spacing: 5) { Text(category.name).fontWeight(.semibold); Text(category.parentID == nil ? "Main category · Order \(category.displayOrder)" : "Section · Order \(category.displayOrder)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if !category.isActive { StatusBadge(text: "HIDDEN", color: .gray) }
                    if category.parentID == nil { Button("Add Section") { editing = HungrySpotCore.Category(parentID: category.id) } }
                    Button("Edit") { editing = category }
                    Button(role: .destructive) { deleting = category } label: { Image(systemName: "trash") }.help("Delete unused category")
                }.padding(.vertical, 12)
            }.listStyle(.inset)
            Text("Hiding a main category also hides its sections and products at the POS. Historical orders remain available.").font(.caption).foregroundStyle(.secondary)
        }.padding(26).sheet(item: $editing) { CategoryEditor(category: $0) }
        .confirmationDialog("Delete \(deleting?.name ?? "category")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Category", role: .destructive) { if let deleting, let session = app.session { app.run { try app.catalog.deleteCategory(session: session, id: deleting.id); try app.reloadCatalog() } }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Only an unused category without sections can be deleted. Hide it instead if it is still in use.") }
    }
}

@MainActor
struct CategoryEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var category: HungrySpotCore.Category
    @State private var validation: String?
    init(category: HungrySpotCore.Category) { _category = State(initialValue: category) }
    private let icons = ["fork.knife", "flame", "circle.grid.cross.fill", "gift", "cup.and.saucer", "takeoutbag.and.cup.and.straw", "leaf", "square.grid.2x2", "birthday.cake", "carrot", "mug", "star"]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: category.id == 0 ? "Add category or section" : "Edit category", subtitle: "Sections sit inside one main category.")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Name", text: $category.name)
                    Picker("Parent category", selection: $category.parentID) {
                        Text("None — main category").tag(nil as Int64?)
                        ForEach(app.categories.filter { $0.parentID == nil && $0.id != category.id }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("Display order", value: $category.displayOrder, format: .number)
                    Toggle("Show category and its products", isOn: $category.isActive)
                    Picker("Icon", selection: $category.icon) { ForEach(Array(Set(icons + [category.icon])).sorted(), id: \.self) { Label($0, systemImage: SpotTheme.symbol($0)).tag($0) } }
                    ImagePickerField(path: $category.imagePath)
                }.padding(.vertical, 4)
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.orange) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Save Category") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.textFieldStyle(.roundedBorder).padding(26).frame(width: 500, height: 610).background(SpotTheme.background)
    }
    private func save() {
        guard let session = app.session else { return }
        do { _ = try app.catalog.saveCategory(session: session, category: category); try app.reloadCatalog(); dismiss() }
        catch { validation = error.localizedDescription }
    }
}
