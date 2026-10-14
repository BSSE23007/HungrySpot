import Foundation

/// Quotes are previews. OrderService recalculates using this same engine inside its save transaction.
public final class PricingService {
    private let catalog: CatalogService
    public init(catalog: CatalogService) { self.catalog = catalog }

    public func calculate(session: Session, draft: OrderDraft) throws -> Quote {
        let user = try catalog.authorizedUser(session: session)
        let settings = try catalog.settings(session: session)
        let categories = try catalog.categories(session: session)
        let availableCategories = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        guard draft.lines.count <= 200, Set(draft.lines.map(\.id)).count == draft.lines.count else {
            throw SpotError.validation("An order may have at most 200 distinct cart lines.")
        }
        try ServiceValidation.amount(draft.deliveryCharge, label: "Delivery charge")
        try ServiceValidation.amount(draft.discount, label: "Discount")
        guard draft.type == .delivery || draft.deliveryCharge == 0 else {
            throw SpotError.validation("Delivery charges only apply to delivery orders.")
        }
        if draft.discount > 0 && user.role != .admin && !settings.cashierCanDiscount { throw SpotError.forbidden }
        var items: [OrderItemSnapshot] = []
        var subtotal: Money = 0
        for line in draft.lines {
            guard (1...999).contains(line.quantity) else { throw SpotError.validation("Item quantity must be between 1 and 999.") }
            let notes = try ServiceValidation.text(line.notes, label: "Item notes", maximum: 2_000)
            let product = try availableProduct(session: session, id: line.productID, categories: availableCategories)
            var options: [OptionSnapshot] = []
            var variantName: String?
            let unitPrice: Money
            let extras: Money
            if product.kind == .deal {
                guard line.variantID == nil, line.toppingQuantity == 0, !line.dipSauce else {
                    throw SpotError.validation("Choose toppings and dips for each pizza within the deal.")
                }
                let result = try dealOptions(session: session, product: product, selections: line.dealSelections, categories: availableCategories, settings: settings)
                options = result.options; extras = result.price; unitPrice = product.basePrice
            } else {
                guard line.dealSelections.isEmpty else { throw SpotError.validation("Only deals accept component selections.") }
                let variant = try selectedVariant(product, id: line.variantID)
                variantName = variant?.name
                unitPrice = variant?.price ?? product.basePrice
                if let variant {
                    // Retaining the variant reference prevents unsafe deletion after sale.
                    options.append(OptionSnapshot(name: "Selected variant: \(variant.name)", productID: product.id, variantID: variant.id))
                }
                let result = try pizzaExtras(product: product, variant: variant, toppingQuantity: line.toppingQuantity, dipSauce: line.dipSauce, settings: settings, prefix: "")
                options += result.options; extras = result.price
            }
            try ServiceValidation.amount(unitPrice, label: "Product price")
            let unitTotal = try ServiceValidation.add(unitPrice, extras)
            let lineTotal = try ServiceValidation.multiply(unitTotal, by: line.quantity)
            try ServiceValidation.amount(lineTotal, label: "Item subtotal")
            subtotal = try ServiceValidation.add(subtotal, lineTotal)
            try ServiceValidation.amount(subtotal, label: "Order subtotal")
            let categoryName = availableCategories[product.categoryID]?.name ?? ""
            items.append(OrderItemSnapshot(productID: product.id, productName: product.name, categoryName: categoryName, variantName: variantName, unitPrice: unitPrice, extraPrice: extras, quantity: line.quantity, notes: notes, options: options))
        }
        guard draft.discount <= subtotal else { throw SpotError.validation("Discount cannot exceed the food subtotal.") }
        let totalBeforeDiscount = try ServiceValidation.add(subtotal, draft.deliveryCharge)
        try ServiceValidation.amount(totalBeforeDiscount - draft.discount, label: "Order total")
        return Quote(items: items, subtotal: subtotal, deliveryCharge: draft.deliveryCharge, discount: draft.discount)
    }

    private func availableProduct(session: Session, id: Int64, categories: [Int64: Category]) throws -> Product {
        let product = try catalog.product(session: session, id: id)
        guard product.isActive, categories[product.categoryID] != nil,
              product.subcategoryID.map({ categories[$0] != nil }) ?? true else {
            throw SpotError.validation("\(product.name) is inactive or its category is disabled.")
        }
        guard product.isAvailable else { throw SpotError.validation("\(product.name) is sold out.") }
        return product
    }

    private func selectedVariant(_ product: Product, id: Int64?) throws -> ProductVariant? {
        switch product.kind {
        case .pizza, .variant:
            guard let id, let variant = product.variants.first(where: { $0.id == id && $0.productID == product.id }) else {
                throw SpotError.validation("Select an available variant for \(product.name).")
            }
            guard variant.isAvailable else { throw SpotError.validation("\(product.name), \(variant.name) is unavailable.") }
            try ServiceValidation.amount(variant.price, label: "Variant price")
            return variant
        case .normal:
            guard id == nil else { throw SpotError.validation("\(product.name) does not accept a variant.") }
            return nil
        case .deal:
            throw SpotError.validation("Nested deals are not supported.")
        }
    }

    private func pizzaExtras(product: Product, variant: ProductVariant?, toppingQuantity: Int, dipSauce: Bool, settings: AppSettings, prefix: String) throws -> (price: Money, options: [OptionSnapshot]) {
        guard (0...99).contains(toppingQuantity) else { throw SpotError.validation("Extra topping quantity must be between 0 and 99.") }
        guard product.kind == .pizza || (toppingQuantity == 0 && !dipSauce) else { throw SpotError.validation("Pizza extras can only be added to a pizza.") }
        var price: Money = 0
        var options: [OptionSnapshot] = []
        if toppingQuantity > 0 {
            guard let toppingPrice = variant?.toppingPrice else { throw SpotError.validation("An administrator must configure the topping price for this pizza size.") }
            try ServiceValidation.amount(toppingPrice, label: "Extra topping price")
            price = try ServiceValidation.multiply(toppingPrice, by: toppingQuantity)
            options.append(OptionSnapshot(name: "\(prefix)Extra Topping", quantity: toppingQuantity, unitPrice: toppingPrice, productID: product.id, variantID: variant?.id))
        }
        if dipSauce {
            try ServiceValidation.amount(settings.dipSaucePrice, label: "Dip sauce price")
            price = try ServiceValidation.add(price, settings.dipSaucePrice)
            options.append(OptionSnapshot(name: "\(prefix)Dip Sauce", unitPrice: settings.dipSaucePrice, productID: product.id, variantID: variant?.id))
        }
        try ServiceValidation.amount(price, label: "Extras total")
        return (price, options)
    }

    private func dealOptions(session: Session, product: Product, selections: [DealSelection], categories: [Int64: Category], settings: AppSettings) throws -> (price: Money, options: [OptionSnapshot]) {
        let deal = try catalog.deal(session: session, productID: product.id)
        guard !deal.needsReview else { throw SpotError.validation("\(product.name) needs administrator review before sale. \(deal.reviewNote)") }
        guard !deal.slots.isEmpty, deal.slots.count <= 100 else { throw SpotError.validation("This deal has no valid component configuration.") }
        guard selections.count <= 1_000 else { throw SpotError.validation("Too many deal selections.") }
        let selectionKeys = selections.map { "\($0.slotID):\($0.unitIndex)" }
        guard Set(selectionKeys).count == selections.count else { throw SpotError.validation("Each deal component may only be selected once.") }
        for selection in selections {
            guard let slot = deal.slots.first(where: { $0.id == selection.slotID }), (0..<slot.quantity).contains(selection.unitIndex) else {
                throw SpotError.validation("A deal selection does not match its configured component.")
            }
        }
        var price: Money = 0
        var options: [OptionSnapshot] = []
        var componentCount = 0
        for slot in deal.slots {
            guard (1...100).contains(slot.quantity), !slot.choices.isEmpty else { throw SpotError.validation("The deal component \(slot.label) is not configured.") }
            componentCount += slot.quantity
            guard componentCount <= 1_000 else { throw SpotError.validation("Too many components in this deal.") }
            if !slot.requiresSelection && slot.choices.count != 1 { throw SpotError.validation("A fixed deal component must have exactly one choice.") }
            for index in 0..<slot.quantity {
                let selection = selections.first { $0.slotID == slot.id && $0.unitIndex == index }
                let choice: DealChoice
                if let selection {
                    choice = DealChoice(productID: selection.productID, variantID: selection.variantID)
                    guard slot.choices.contains(choice) else { throw SpotError.validation("That product or size is not allowed in \(slot.label).") }
                } else {
                    guard !slot.requiresSelection, let first = slot.choices.first else { throw SpotError.validation("Choose \(slot.label) \(index + 1) of \(slot.quantity).") }
                    choice = first
                }
                let component = try availableProduct(session: session, id: choice.productID, categories: categories)
                let variant = try selectedVariant(component, id: choice.variantID)
                let label = "\(slot.label) \(index + 1): \(component.name)\(variant.map { " (\($0.name))" } ?? "")"
                options.append(OptionSnapshot(name: label, productID: component.id, variantID: variant?.id))
                let extra = try pizzaExtras(product: component, variant: variant, toppingQuantity: selection?.toppingQuantity ?? 0, dipSauce: selection?.dipSauce ?? false, settings: settings, prefix: "\(slot.label) \(index + 1) • ")
                price = try ServiceValidation.add(price, extra.price)
                options += extra.options
            }
        }
        try ServiceValidation.amount(price, label: "Deal extras total")
        return (price, options)
    }
}
