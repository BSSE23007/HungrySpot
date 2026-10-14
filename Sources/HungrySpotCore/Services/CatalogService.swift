import Foundation

public final class CatalogService {
    private let database: Database
    private let auth: AuthenticationService
    private let auditService: AuditService
    public init(database: Database, auth: AuthenticationService) {
        self.database = database; self.auth = auth; self.auditService = AuditService(database: database)
    }
    public func authorizedUser(session: Session) throws -> User { try auth.authorize(session) }

    public func categories(session: Session, includeInactive: Bool = false) throws -> [Category] {
        try database.withExclusiveAccess {
            _ = try auth.authorize(session, admin: includeInactive)
            let all = try database.query(sql: "SELECT * FROM categories ORDER BY display_order,name COLLATE NOCASE").map(categoryFromRow)
            if includeInactive { return all }
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            func visible(_ category: Category, visited: Set<Int64> = []) -> Bool {
                guard category.isActive, !visited.contains(category.id) else { return false }
                guard let parent = category.parentID else { return true }
                guard let ancestor = byID[parent] else { return false }
                return visible(ancestor, visited: visited.union([category.id]))
            }
            return all.filter { visible($0) }
        }
    }
    public func products(session: Session, search: String = "", categoryID: Int64? = nil, includeInactive: Bool = false) throws -> [Product] {
        try database.withExclusiveAccess {
            _ = try auth.authorize(session, admin: includeInactive)
            var sql = "SELECT p.* FROM products p JOIN categories c ON c.id=p.category_id LEFT JOIN categories s ON s.id=p.subcategory_id WHERE 1=1"
            var parameters: [SQLValue] = []
            if !includeInactive { sql += " AND p.is_active=1" }
            if let categoryID {
                sql += " AND (p.category_id=? OR p.subcategory_id=?)"; parameters += [.integer(categoryID), .integer(categoryID)]
            }
            let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty {
                let escaped = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                sql += " AND (p.name LIKE ? ESCAPE '\\' COLLATE NOCASE OR c.name LIKE ? ESCAPE '\\' COLLATE NOCASE OR s.name LIKE ? ESCAPE '\\' COLLATE NOCASE)"
                parameters += Array(repeating: .text("%\(escaped)%"), count: 3)
            }
            sql += " ORDER BY p.display_order,p.name COLLATE NOCASE"
            let rows = try database.query(sql: sql, parameters: parameters)
            let visible = includeInactive ? Set<Int64>() : Set(try categories(session: session).map(\.id))
            return try rows.filter { includeInactive || (visible.contains($0.int("category_id")) && ($0.optionalInt("subcategory_id").map(visible.contains) ?? true)) }.map(productFromRow)
        }
    }
    public func product(session: Session, id: Int64) throws -> Product {
        try database.withExclusiveAccess {
            _ = try auth.authorize(session)
            return try loadProduct(id)
        }
    }
    /// Availability is the only catalog field a cashier may change. All full edits remain admin-only.
    @discardableResult
    public func setProductAvailability(session: Session, productID: Int64, isAvailable: Bool) throws -> Product {
        try database.transaction {
            let user = try auth.authorize(session)
            let product = try loadProduct(productID)
            if user.role != .admin {
                let visibleCategories = Set(try categories(session: session).map(\.id))
                guard product.isActive, visibleCategories.contains(product.categoryID),
                      product.subcategoryID.map(visibleCategories.contains) ?? true else {
                    throw SpotError.forbidden
                }
            }
            guard product.isAvailable != isAvailable else { return product }
            try database.execute(sql: "UPDATE products SET is_available=? WHERE id=?", parameters: [.integer(isAvailable ? 1 : 0), .integer(productID)])
            try auditService.record(userID: user.id, action: "Product availability changed", entity: "Product \(productID)", details: "\(product.name); available \(product.isAvailable) → \(isAvailable).")
            return try loadProduct(productID)
        }
    }
    public func saveProduct(session: Session, product: Product) throws -> Product {
        try database.transaction {
            let user = try auth.authorize(session, admin: true)
            var product = product
            product.name = try nonempty(product.name, label: "Product name", limit: 160)
            try validMoney(product.basePrice); try validImage(product.imagePath)
            guard product.description.count <= 4000 else { throw SpotError.validation("Product description is too long.") }
            let category = try loadCategory(product.categoryID)
            guard category.parentID == nil else { throw SpotError.validation("Choose a main category for the product.") }
            if let sub = product.subcategoryID { guard try loadCategory(sub).parentID == category.id else { throw SpotError.validation("The section must belong to the selected category.") } }
            if product.kind == .pizza || product.kind == .variant {
                guard !product.variants.isEmpty else { throw SpotError.validation("Add at least one variant.") }
            } else if !product.variants.isEmpty { throw SpotError.validation("Normal products and deals cannot have size variants. Choose Variant or Pizza.") }
            var variantNames = Set<String>()
            var variantIDs = Set<Int64>()
            for index in product.variants.indices {
                product.variants[index].name = try nonempty(product.variants[index].name, label: "Variant name", limit: 80)
                let variant = product.variants[index]
                try validMoney(variant.price)
                if let price = variant.toppingPrice { try validMoney(price) }
                guard variantNames.insert(variant.name.lowercased()).inserted else { throw SpotError.validation("Variant names must be unique within a product.") }
                if variant.id != 0 { guard variantIDs.insert(variant.id).inserted else { throw SpotError.validation("A variant was repeated.") } }
            }
            let previous: Product? = product.id == 0 ? nil : try loadProduct(product.id)
            let parameters: [SQLValue] = [.text(product.name), .integer(product.categoryID), product.subcategoryID.map(SQLValue.integer) ?? .null, .text(product.description), .text(product.kind.rawValue), .integer(product.basePrice), product.imagePath.map(SQLValue.text) ?? .null, .integer(product.isAvailable ? 1 : 0), .integer(product.isActive ? 1 : 0), .integer(Int64(product.displayOrder))]
            if product.id == 0 {
                try database.execute(sql: "INSERT INTO products(name,category_id,subcategory_id,description,kind,base_price,image_path,is_available,is_active,display_order) VALUES(?,?,?,?,?,?,?,?,?,?)", parameters: parameters)
                product.id = database.lastInsertID
            } else {
                if previous?.kind != product.kind,
                   try database.scalarInt(sql: "SELECT COUNT(*) FROM deal_item_choices WHERE product_id=?", parameters: [.integer(product.id)]) > 0 {
                    throw SpotError.conflict("This product is included in a deal. Update those deal components before changing its type.")
                }
                try database.execute(sql: "UPDATE products SET name=?,category_id=?,subcategory_id=?,description=?,kind=?,base_price=?,image_path=?,is_available=?,is_active=?,display_order=? WHERE id=?", parameters: parameters + [.integer(product.id)])
            }
            let existing = previous?.variants ?? []
            for removed in existing where !variantIDs.contains(removed.id) {
                guard try database.scalarInt(sql: "SELECT (SELECT COUNT(*) FROM deal_item_choices WHERE variant_id=?) + (SELECT COUNT(*) FROM order_item_options WHERE variant_id=?)", parameters: [.integer(removed.id), .integer(removed.id)]) == 0 else { throw SpotError.conflict("Variant \(removed.name) is used by a deal or an order. Mark it unavailable instead.") }
                try database.execute(sql: "DELETE FROM product_variants WHERE id=?", parameters: [.integer(removed.id)])
            }
            // Temporary names allow a safe exchange of two variant names without a transient UNIQUE failure.
            for variant in product.variants where variant.id != 0 {
                guard existing.contains(where: { $0.id == variant.id }) else { throw SpotError.validation("A variant does not belong to this product.") }
                try database.execute(sql: "UPDATE product_variants SET name=? WHERE id=?", parameters: [.text("__editing_\(UUID().uuidString)"), .integer(variant.id)])
            }
            for variant in product.variants {
                let values: [SQLValue] = [.text(variant.name), .integer(variant.price), .integer(Int64(variant.displayOrder)), .integer(variant.isAvailable ? 1 : 0), variant.toppingPrice.map(SQLValue.integer) ?? .null]
                if variant.id == 0 {
                    try database.execute(sql: "INSERT INTO product_variants(name,price,display_order,is_available,topping_price,product_id) VALUES(?,?,?,?,?,?)", parameters: values + [.integer(product.id)])
                } else { try database.execute(sql: "UPDATE product_variants SET name=?,price=?,display_order=?,is_available=?,topping_price=? WHERE id=?", parameters: values + [.integer(variant.id)]) }
            }
            if product.kind == .deal {
                try database.execute(sql: "INSERT OR IGNORE INTO deals(product_id,needs_review,review_note) VALUES(?,1,'Configure and confirm this bundle before sale.')", parameters: [.integer(product.id)])
            } else if previous?.kind == .deal { try database.execute(sql: "DELETE FROM deals WHERE product_id=?", parameters: [.integer(product.id)]) }
            let action: String = previous == nil ? "Product created" : (previous?.isActive == true && !product.isActive ? "Product disabled" : "Product changed")
            try auditService.record(userID: user.id, action: action, entity: "Product \(product.id)", details: "\(product.name); base price \(product.basePrice) paisa; active \(product.isActive); available \(product.isAvailable).")
            if let previous, previous.basePrice != product.basePrice || previous.variants.map(\.price) != product.variants.map(\.price) || previous.variants.map(\.toppingPrice) != product.variants.map(\.toppingPrice) {
                try auditService.record(userID: user.id, action: "Price changed", entity: "Product \(product.id)", details: "Previous base \(previous.basePrice), new base \(product.basePrice) paisa; variant prices \(product.variants.map { "\($0.name): \($0.price), topping \($0.toppingPrice.map(String.init) ?? "not configured")" }.joined(separator: ", ")).")
            }
            return try loadProduct(product.id)
        }
    }
    public func duplicateProduct(session: Session, id: Int64) throws -> Product {
        try database.transaction {
            _ = try auth.authorize(session, admin: true)
            var copy = try loadProduct(id); copy.id = 0; copy.name += " (Copy)"; copy.isActive = false
            copy.variants = copy.variants.map { var variant = $0; variant.id = 0; variant.productID = 0; return variant }
            let saved = try saveProduct(session: session, product: copy)
            if saved.kind == .deal {
                var bundle = try deal(session: session, productID: id); bundle.productID = saved.id
                bundle.slots = bundle.slots.map { var slot = $0; slot.id = 0; slot.dealID = saved.id; return slot }
                try saveDeal(session: session, deal: bundle)
            }
            return saved
        }
    }
    public func deleteProduct(session: Session, id: Int64) throws {
        try database.transaction {
            let user = try auth.authorize(session, admin: true), product = try loadProduct(id)
            guard try database.scalarInt(sql: "SELECT (SELECT COUNT(*) FROM order_items WHERE product_id=?) + (SELECT COUNT(*) FROM order_item_options WHERE product_id=?) + (SELECT COUNT(*) FROM deal_item_choices WHERE product_id=?)", parameters: [.integer(id), .integer(id), .integer(id)]) == 0 else { throw SpotError.conflict("This product is used in an order or bundle. Archive it instead.") }
            try database.execute(sql: "DELETE FROM products WHERE id=?", parameters: [.integer(id)])
            try auditService.record(userID: user.id, action: "Product deleted", entity: "Product \(id)", details: product.name)
        }
    }
    public func saveCategory(session: Session, category: Category) throws -> Category {
        try database.transaction {
            let user = try auth.authorize(session, admin: true)
            var category = category
            category.name = try nonempty(category.name, label: "Category name", limit: 100)
            category.icon = try nonempty(category.icon, label: "Category icon", limit: 100); try validImage(category.imagePath)
            if let parent = category.parentID {
                guard parent != category.id, try loadCategory(parent).parentID == nil else { throw SpotError.validation("A section must belong to a main category. Nested sections are not supported.") }
            }
            if category.id != 0 {
                let previous = try loadCategory(category.id)
                if previous.parentID != category.parentID {
                    guard try database.scalarInt(sql: "SELECT (SELECT COUNT(*) FROM categories WHERE parent_id=?) + (SELECT COUNT(*) FROM products WHERE category_id=? OR subcategory_id=?)", parameters: [.integer(category.id), .integer(category.id), .integer(category.id)]) == 0 else { throw SpotError.conflict("Move assigned products and sections before changing this category's parent.") }
                }
            }
            let values: [SQLValue] = [.text(category.name), category.parentID.map(SQLValue.integer) ?? .null, .integer(Int64(category.displayOrder)), .integer(category.isActive ? 1 : 0), .text(category.icon), category.imagePath.map(SQLValue.text) ?? .null]
            if category.id == 0 {
                try database.execute(sql: "INSERT INTO categories(name,parent_id,display_order,is_active,icon,image_path) VALUES(?,?,?,?,?,?)", parameters: values); category.id = database.lastInsertID
            } else { try database.execute(sql: "UPDATE categories SET name=?,parent_id=?,display_order=?,is_active=?,icon=?,image_path=? WHERE id=?", parameters: values + [.integer(category.id)]) }
            try auditService.record(userID: user.id, action: "Category changed", entity: "Category \(category.id)", details: "\(category.name); active \(category.isActive).")
            return category
        }
    }
    public func deleteCategory(session: Session, id: Int64) throws {
        try database.transaction {
            let user = try auth.authorize(session, admin: true), category = try loadCategory(id)
            guard try database.scalarInt(sql: "SELECT (SELECT COUNT(*) FROM categories WHERE parent_id=?) + (SELECT COUNT(*) FROM products WHERE category_id=? OR subcategory_id=?)", parameters: [.integer(id), .integer(id), .integer(id)]) == 0 else { throw SpotError.conflict("Only an unused category without sections can be deleted. Disable it instead.") }
            try database.execute(sql: "DELETE FROM categories WHERE id=?", parameters: [.integer(id)])
            try auditService.record(userID: user.id, action: "Category deleted", entity: "Category \(id)", details: category.name)
        }
    }
    public func deal(session: Session, productID: Int64) throws -> Deal {
        try database.withExclusiveAccess {
            _ = try auth.authorize(session)
            guard let row = try database.query(sql: "SELECT * FROM deals WHERE product_id=?", parameters: [.integer(productID)]).first else { throw SpotError.notFound }
            let slots = try database.query(sql: "SELECT * FROM deal_items WHERE deal_id=? ORDER BY display_order,id", parameters: [.integer(productID)]).map { item in
                let choices = try database.query(sql: "SELECT product_id,variant_id FROM deal_item_choices WHERE deal_item_id=? ORDER BY id", parameters: [.integer(item.int("id"))]).map { DealChoice(productID: $0.int("product_id"), variantID: $0.optionalInt("variant_id")) }
                return DealSlot(id: item.int("id"), dealID: productID, label: item.string("label"), quantity: Int(item.int("quantity")), requiresSelection: item.int("requires_selection") == 1, choices: choices)
            }
            return Deal(productID: productID, needsReview: row.int("needs_review") == 1, reviewNote: row.string("review_note"), slots: slots)
        }
    }
    public func saveDeal(session: Session, deal: Deal) throws {
        try database.transaction {
            let user = try auth.authorize(session, admin: true)
            guard try loadProduct(deal.productID).kind == .deal else { throw SpotError.validation("Only a Deal product can contain bundle components.") }
            guard deal.slots.count <= 50, deal.reviewNote.count <= 4000 else { throw SpotError.validation("The deal has too many components or an overly long review note.") }
            if !deal.needsReview { guard !deal.slots.isEmpty else { throw SpotError.validation("A sellable deal must contain components.") } }
            for slot in deal.slots {
                _ = try nonempty(slot.label, label: "Component label", limit: 160)
                guard (1...100).contains(slot.quantity), slot.choices.count <= 500 else { throw SpotError.validation("Component quantity must be 1–100 with no more than 500 choices.") }
                if !deal.needsReview { guard !slot.choices.isEmpty else { throw SpotError.validation("Choose eligible products for every component before clearing Needs review.") } }
                guard slot.requiresSelection || slot.choices.count <= 1 else { throw SpotError.validation("A fixed component can contain only one choice. Enable selection for multiple choices.") }
                var unique = Set<String>()
                for choice in slot.choices {
                    guard unique.insert(choice.id).inserted else { throw SpotError.validation("A component choice was repeated.") }
                    let product = try loadProduct(choice.productID)
                    guard product.kind != .deal else { throw SpotError.validation("A deal cannot contain another deal.") }
                    if product.kind == .pizza || product.kind == .variant {
                        guard let variantID = choice.variantID, product.variants.contains(where: { $0.id == variantID }) else { throw SpotError.validation("Select a valid size or variant for \(product.name).") }
                    } else if choice.variantID != nil { throw SpotError.validation("\(product.name) does not have variants.") }
                    if product.kind == .pizza && !slot.requiresSelection { throw SpotError.validation("Pizza components require selection so each pizza can be configured.") }
                }
            }
            try database.execute(sql: "INSERT INTO deals(product_id,needs_review,review_note) VALUES(?,?,?) ON CONFLICT(product_id) DO UPDATE SET needs_review=excluded.needs_review,review_note=excluded.review_note", parameters: [.integer(deal.productID), .integer(deal.needsReview ? 1 : 0), .text(deal.reviewNote)])
            let existing = Set(try database.query(sql: "SELECT id FROM deal_items WHERE deal_id=?", parameters: [.integer(deal.productID)]).map { $0.int("id") })
            var retained = Set<Int64>()
            for (index, slot) in deal.slots.enumerated() {
                let values: [SQLValue] = [.text(slot.label.trimmingCharacters(in: .whitespacesAndNewlines)), .integer(Int64(slot.quantity)), .integer(slot.requiresSelection ? 1 : 0), .integer(Int64(index))]
                let id: Int64
                if slot.id == 0 {
                    try database.execute(sql: "INSERT INTO deal_items(label,quantity,requires_selection,display_order,deal_id) VALUES(?,?,?,?,?)", parameters: values + [.integer(deal.productID)]); id = database.lastInsertID
                } else {
                    guard existing.contains(slot.id), !retained.contains(slot.id) else { throw SpotError.validation("A component does not belong to this deal or was repeated.") }
                    id = slot.id
                    try database.execute(sql: "UPDATE deal_items SET label=?,quantity=?,requires_selection=?,display_order=? WHERE id=?", parameters: values + [.integer(id)])
                    try database.execute(sql: "DELETE FROM deal_item_choices WHERE deal_item_id=?", parameters: [.integer(id)])
                }
                retained.insert(id)
                for choice in slot.choices { try database.execute(sql: "INSERT INTO deal_item_choices(deal_item_id,product_id,variant_id) VALUES(?,?,?)", parameters: [.integer(id), .integer(choice.productID), choice.variantID.map(SQLValue.integer) ?? .null]) }
            }
            for id in existing.subtracting(retained) { try database.execute(sql: "DELETE FROM deal_items WHERE id=?", parameters: [.integer(id)]) }
            try auditService.record(userID: user.id, action: "Deal changed", entity: "Product \(deal.productID)", details: "\(deal.slots.count) components; needs review \(deal.needsReview).")
        }
    }
    public func settings(session: Session) throws -> AppSettings {
        try database.withExclusiveAccess {
            _ = try auth.authorize(session)
            guard let row = try database.query(sql: "SELECT value FROM settings WHERE key='app_settings'").first else { throw SpotError.database("Restaurant settings are missing.") }
            do { return try JSONDecoder().decode(AppSettings.self, from: Data(row.string("value").utf8)) }
            catch { throw SpotError.database("Restaurant settings could not be read. Restore a verified backup.") }
        }
    }
    public func saveSettings(session: Session, settings: AppSettings) throws {
        try database.transaction {
            let user = try auth.authorize(session, admin: true)
            _ = try nonempty(settings.restaurantName, label: "Restaurant name", limit: 160)
            _ = try nonempty(settings.currencySymbol, label: "Currency symbol", limit: 12)
            for value in [settings.tagline, settings.phones, settings.address, settings.hours, settings.receiptFooter, settings.receiptPrinter, settings.kitchenPrinter] { guard value.count <= 2000 else { throw SpotError.validation("A settings field is too long.") } }
            try validImage(settings.logoPath); try validMoney(settings.defaultDeliveryCharge); try validMoney(settings.dipSaucePrice)
            guard settings.quickDeliveryCharges.count <= 12, [58,80].contains(settings.paperWidthMM) else { throw SpotError.validation("Use up to 12 delivery presets and 58 mm or 80 mm paper.") }
            for amount in settings.quickDeliveryCharges { try validMoney(amount) }
            let data = try JSONEncoder().encode(settings)
            try database.execute(sql: "INSERT INTO settings(key,value) VALUES('app_settings',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", parameters: [.text(String(decoding: data, as: UTF8.self))])
            try auditService.record(userID: user.id, action: "Settings changed", entity: "Restaurant", details: "Business, delivery, pricing and printer preferences updated.")
        }
    }
    public func audit(session: Session, limit: Int = 500) throws -> [AuditEntry] {
        try database.withExclusiveAccess {
            _ = try auth.authorize(session, admin: true)
            return try database.query(sql: "SELECT * FROM audit_logs ORDER BY created_at DESC,id DESC LIMIT ?", parameters: [.integer(Int64(min(max(limit, 1), 5000)))]).map { AuditEntry(id: $0.int("id"), action: $0.string("action"), username: $0.string("username"), entity: $0.string("entity"), details: $0.string("details"), date: Date(timeIntervalSince1970: $0.double("created_at"))) }
        }
    }
    private func loadProduct(_ id: Int64) throws -> Product {
        guard let row = try database.query(sql: "SELECT * FROM products WHERE id=?", parameters: [.integer(id)]).first else { throw SpotError.notFound }
        return try productFromRow(row)
    }
    private func productFromRow(_ row: SQLRow) throws -> Product {
        guard let kind = ProductKind(rawValue: row.string("kind")) else { throw SpotError.database("Invalid catalog product type.") }
        let variants = try database.query(sql: "SELECT * FROM product_variants WHERE product_id=? ORDER BY display_order,id", parameters: [.integer(row.int("id"))]).map { ProductVariant(id: $0.int("id"), productID: $0.int("product_id"), name: $0.string("name"), price: $0.int("price"), displayOrder: Int($0.int("display_order")), isAvailable: $0.int("is_available") == 1, toppingPrice: $0.optionalInt("topping_price")) }
        return Product(id: row.int("id"), name: row.string("name"), categoryID: row.int("category_id"), subcategoryID: row.optionalInt("subcategory_id"), description: row.string("description"), kind: kind, basePrice: row.int("base_price"), imagePath: row.optionalString("image_path"), isAvailable: row.int("is_available") == 1, isActive: row.int("is_active") == 1, displayOrder: Int(row.int("display_order")), variants: variants)
    }
    private func loadCategory(_ id: Int64) throws -> Category {
        guard let row = try database.query(sql: "SELECT * FROM categories WHERE id=?", parameters: [.integer(id)]).first else { throw SpotError.validation("The selected category does not exist.") }
        return categoryFromRow(row)
    }
    private func categoryFromRow(_ row: SQLRow) -> Category { Category(id: row.int("id"), name: row.string("name"), parentID: row.optionalInt("parent_id"), displayOrder: Int(row.int("display_order")), isActive: row.int("is_active") == 1, icon: row.string("icon"), imagePath: row.optionalString("image_path")) }
    private func nonempty(_ text: String, label: String, limit: Int) throws -> String {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= limit, !result.contains("\0") else { throw SpotError.validation("\(label) is required and must be at most \(limit) characters.") }; return result
    }
    private func validMoney(_ amount: Money) throws { try ServiceValidation.amount(amount, label: "Price") }
    private func validImage(_ path: String?) throws {
        guard let path else { return }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.split(separator: "/").contains(".."), !path.contains("\0") else { throw SpotError.validation("Images must be imported into the application's image folder.") }
    }
}
