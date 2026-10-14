import Foundation
import XCTest
@testable import HungrySpotCore

final class CatalogTests: XCTestCase {
    private var database: Database!
    private var auth: AuthenticationService!
    private var catalog: CatalogService!
    private var admin: Session!

    override func setUpWithError() throws {
        database = try Database(path: ":memory:"); try database.bootstrap()
        auth = AuthenticationService(database: database)
        admin = try auth.setupAdmin(username: "owner", password: "A-strong-test-password-42!")
        catalog = CatalogService(database: database, auth: auth)
    }
    override func tearDownWithError() throws { try database.close() }
    private func product(_ name: String) throws -> Product {
        try XCTUnwrap(catalog.products(session: admin, includeInactive: true).first { $0.name == name })
    }
    private func category(_ name: String) throws -> HungrySpotCore.Category {
        try XCTUnwrap(catalog.categories(session: admin, includeInactive: true).first { $0.name == name })
    }
    private func cashier() throws -> Session {
        let password = "A-strong-cashier-password-42!"
        _ = try auth.saveUser(session: admin, id: nil, username: "cashier", password: password, role: .cashier, isActive: true)
        return try auth.login(username: "cashier", password: password)
    }

    func testCashierAvailabilityChangesOnlyFlagAndAuditsActor() throws {
        let clerk = try cashier()
        let original = try product("Chicken Tikka")
        var expected = original; expected.isAvailable = false
        let updated = try catalog.setProductAvailability(session: clerk, productID: original.id, isAvailable: false)
        XCTAssertEqual(updated, expected)
        XCTAssertEqual(try catalog.product(session: admin, id: original.id), expected)
        XCTAssertEqual(try catalog.products(session: clerk, search: original.name).first, expected)
        let entry = try XCTUnwrap(catalog.audit(session: admin).first { $0.action == "Product availability changed" })
        XCTAssertEqual(entry.username, clerk.user.username)
        XCTAssertEqual(entry.entity, "Product \(original.id)")
        XCTAssertTrue(entry.details.contains("true → false"))
        XCTAssertEqual(try catalog.setProductAvailability(session: clerk, productID: original.id, isAvailable: true), original)
    }

    func testCashierAvailabilityCannotEditMetadataPriceArchiveOrAdminCatalogOperations() throws {
        let clerk = try cashier(), original = try product("Chicken Tikka")
        var edits: [Product] = []
        var edited = original; edited.name = "Unauthorized name"; edits.append(edited)
        edited = original; edited.description = "Unauthorized description"; edits.append(edited)
        edited = original; edited.basePrice = 1; edits.append(edited)
        edited = original; edited.variants[0].price = 1; edits.append(edited)
        edited = original; edited.isActive = false; edits.append(edited)
        edited = original; edited.categoryID = try category("Wraps").id; edits.append(edited)
        edited = original; edited.imagePath = "products/unauthorized.jpg"; edits.append(edited)
        for value in edits {
            XCTAssertThrowsError(try catalog.saveProduct(session: clerk, product: value)) { error in
                guard case SpotError.forbidden = error else { return XCTFail("Expected forbidden, got \(error)") }
            }
        }
        XCTAssertThrowsError(try catalog.saveProduct(session: clerk, product: Product(name: "Unauthorized new", categoryID: original.categoryID)))
        XCTAssertThrowsError(try catalog.duplicateProduct(session: clerk, id: original.id))
        XCTAssertThrowsError(try catalog.deleteProduct(session: clerk, id: original.id))
        let section = try category("Wraps")
        XCTAssertThrowsError(try catalog.saveCategory(session: clerk, category: section))
        XCTAssertThrowsError(try catalog.deleteCategory(session: clerk, id: section.id))
        let bundle = try product("Deal 1")
        let deal = try catalog.deal(session: admin, productID: bundle.id)
        XCTAssertThrowsError(try catalog.saveDeal(session: clerk, deal: deal))
        _ = try catalog.setProductAvailability(session: clerk, productID: bundle.id, isAvailable: false)
        XCTAssertEqual(try catalog.deal(session: admin, productID: bundle.id), deal)
        XCTAssertEqual(try catalog.product(session: admin, id: original.id), original)
    }

    func testCashierCannotChangeArchivedOrHiddenCategoryAvailabilityEvenWithForgedAdminRole() throws {
        let clerk = try cashier()
        let forged = Session(token: clerk.token, user: User(id: clerk.user.id, username: "owner", role: .admin))
        var archived = try product("Chicken Paratha"); archived.isActive = false
        archived = try catalog.saveProduct(session: admin, product: archived)
        XCTAssertThrowsError(try catalog.setProductAvailability(session: forged, productID: archived.id, isAvailable: false))
        XCTAssertEqual(try catalog.product(session: admin, id: archived.id), archived)
        let burger = try product("Zinger Burger")
        var section = try category("Classic Burgers"); section.isActive = false
        _ = try catalog.saveCategory(session: admin, category: section)
        XCTAssertThrowsError(try catalog.setProductAvailability(session: clerk, productID: burger.id, isAvailable: false))
        section.isActive = true
        _ = try catalog.saveCategory(session: admin, category: section)
        var parent = try category("Burgers"); parent.isActive = false
        _ = try catalog.saveCategory(session: admin, category: parent)
        XCTAssertThrowsError(try catalog.setProductAvailability(session: clerk, productID: burger.id, isAvailable: false))
        XCTAssertEqual(try catalog.product(session: admin, id: burger.id), burger)
        XCTAssertFalse(try catalog.setProductAvailability(session: admin, productID: archived.id, isAvailable: false).isAvailable)
    }

    func testAvailabilityRequiresRegisteredActiveSessionAndExistingProduct() throws {
        let clerk = try cashier(), original = try product("Chicken Paratha")
        let unregistered = Session(token: UUID(), user: clerk.user)
        XCTAssertThrowsError(try catalog.setProductAvailability(session: unregistered, productID: original.id, isAvailable: false))
        XCTAssertThrowsError(try catalog.setProductAvailability(session: clerk, productID: Int64.max, isAvailable: false))
        try database.execute(sql: "UPDATE users SET is_active=0 WHERE id=?", parameters: [.integer(clerk.user.id)])
        XCTAssertThrowsError(try catalog.setProductAvailability(session: clerk, productID: original.id, isAvailable: false))
        XCTAssertEqual(try catalog.product(session: admin, id: original.id), original)
        XCTAssertFalse(try catalog.audit(session: admin).contains { $0.action == "Product availability changed" })
    }

    func testAvailabilityAuditFailureRollsBackAndRepeatedValueIsANoOp() throws {
        let clerk = try cashier(), original = try product("Chicken Paratha")
        XCTAssertEqual(try catalog.setProductAvailability(session: clerk, productID: original.id, isAvailable: original.isAvailable), original)
        XCTAssertFalse(try catalog.audit(session: admin).contains { $0.action == "Product availability changed" })
        try database.execute(sql: "CREATE TRIGGER reject_availability_audit BEFORE INSERT ON audit_logs WHEN NEW.action='Product availability changed' BEGIN SELECT RAISE(ABORT, 'test audit failure'); END")
        XCTAssertThrowsError(try catalog.setProductAvailability(session: clerk, productID: original.id, isAvailable: false))
        XCTAssertEqual(try catalog.product(session: admin, id: original.id), original)
    }

    func testAvailabilityImmediatelyAffectsPricingAndAdminStillEditsAllFields() throws {
        let clerk = try cashier(), original = try product("Chicken Paratha")
        let pricing = PricingService(catalog: catalog)
        let draft = OrderDraft(lines: [CartLine(productID: original.id)])
        XCTAssertNoThrow(try pricing.calculate(session: clerk, draft: draft))
        _ = try catalog.setProductAvailability(session: clerk, productID: original.id, isAvailable: false)
        XCTAssertThrowsError(try pricing.calculate(session: clerk, draft: draft))
        _ = try catalog.setProductAvailability(session: clerk, productID: original.id, isAvailable: true)
        XCTAssertEqual(try pricing.calculate(session: clerk, draft: draft).total, original.basePrice)
        var edited = original; edited.name = "Administrator renamed paratha"; edited.basePrice = 30_000
        XCTAssertEqual(try catalog.saveProduct(session: admin, product: edited), edited)
        XCTAssertEqual(try pricing.calculate(session: clerk, draft: draft).total, 30_000)
    }

    func testProductCRUDImagesAndDuplicateVariantsRemainIndependent() throws {
        let wraps = try category("Wraps")
        var original = try catalog.saveProduct(session: admin, product: Product(name: "Custom wrap", categoryID: wraps.id, description: "A locally managed product", kind: .variant, imagePath: "products/wrap.jpg", variants: [ProductVariant(name: "Single", price: 15_000), ProductVariant(name: "Double", price: 25_000)]))
        XCTAssertGreaterThan(original.id, 0)
        XCTAssertEqual(original.variants.count, 2)
        XCTAssertTrue(original.variants.allSatisfy { $0.productID == original.id && $0.id > 0 })
        original.name = "Updated wrap"; original.imagePath = "products/new-wrap.jpg"
        original.variants[0].price = 17_500
        original = try catalog.saveProduct(session: admin, product: original)
        let copy = try catalog.duplicateProduct(session: admin, id: original.id)
        XCTAssertEqual(copy.name, "Updated wrap (Copy)"); XCTAssertFalse(copy.isActive)
        XCTAssertEqual(copy.imagePath, original.imagePath)
        XCTAssertTrue(Set(copy.variants.map(\.id)).isDisjoint(with: Set(original.variants.map(\.id))))
        original.imagePath = nil; original.variants.removeLast()
        original = try catalog.saveProduct(session: admin, product: original)
        XCTAssertNil(original.imagePath); XCTAssertEqual(original.variants.count, 1)
        XCTAssertEqual(try catalog.product(session: admin, id: copy.id).variants.count, 2)
        try catalog.deleteProduct(session: admin, id: original.id)
        XCTAssertThrowsError(try catalog.product(session: admin, id: original.id))
        XCTAssertEqual(try database.scalarInt(sql: "SELECT COUNT(*) FROM product_variants WHERE product_id=?", parameters: [.integer(original.id)]), 0)
        XCTAssertTrue(try catalog.audit(session: admin).contains { $0.action == "Price changed" })
    }

    func testVariantNameExchangePreservesIdentityAndBadEditRollsBack() throws {
        var item = try product("Chicken Shawarma")
        let first = item.variants[0].id, second = item.variants[1].id
        item.variants[0].name = "Large"; item.variants[1].name = "Small"
        item = try catalog.saveProduct(session: admin, product: item)
        XCTAssertEqual(item.variants.first { $0.id == first }?.name, "Large")
        XCTAssertEqual(item.variants.first { $0.id == second }?.name, "Small")
        let before = item
        item.name = "Should roll back"
        item.variants[0].id = try XCTUnwrap(product("Regular Fries").variants.first).id
        XCTAssertThrowsError(try catalog.saveProduct(session: admin, product: item))
        XCTAssertEqual(try catalog.product(session: admin, id: item.id), before)
        item = before; item.variants[1].name = "large"
        XCTAssertThrowsError(try catalog.saveProduct(session: admin, product: item))
        XCTAssertEqual(try catalog.product(session: admin, id: item.id), before)
    }

    func testReferencedProductsAndVariantsMustBeArchivedInsteadOfDeleted() throws {
        let burger = try product("Zinger Burger")
        XCTAssertThrowsError(try catalog.deleteProduct(session: admin, id: burger.id))
        var wings = try product("Fried Wings")
        let before = wings; wings.variants.removeFirst()
        XCTAssertThrowsError(try catalog.saveProduct(session: admin, product: wings))
        XCTAssertEqual(try catalog.product(session: admin, id: before.id), before)
        wings = before; wings.variants[0].isAvailable = false
        XCTAssertFalse(try catalog.saveProduct(session: admin, product: wings).variants[0].isAvailable)
        wings = before; wings.kind = .normal; wings.variants = []; wings.basePrice = 25_000
        XCTAssertThrowsError(try catalog.saveProduct(session: admin, product: wings))
    }

    func testMenuSearchMatchesNameCategorySectionAndTreatsWildcardsLiterally() throws {
        let byName = try catalog.products(session: admin, search: "cHi")
        XCTAssertTrue(byName.contains { $0.name == "Chicken Tikka" })
        XCTAssertTrue(byName.contains { $0.name == "Chicken Paratha" })
        XCTAssertEqual(try catalog.products(session: admin, search: "classic burgers").count, 5)
        XCTAssertEqual(try catalog.products(session: admin, search: "drinks").count, 7)
        let wraps = try category("Wraps")
        let item = try catalog.saveProduct(session: admin, product: Product(name: "100%_Chicken", categoryID: wraps.id, basePrice: 12345))
        XCTAssertEqual(try catalog.products(session: admin, search: "%_").map(\.id), [item.id])
        XCTAssertTrue(try catalog.products(session: admin, search: "%' OR 1=1 --").isEmpty)
        XCTAssertEqual(try catalog.products(session: admin, categoryID: try category("Classic Burgers").id).count, 5)
    }

    func testDisabledProductSectionAndAncestorDisappearImmediatelyFromPOS() throws {
        var burger = try product("Zinger Burger"); burger.isActive = false
        _ = try catalog.saveProduct(session: admin, product: burger)
        XCTAssertTrue(try catalog.products(session: admin, search: "Zinger Burger").isEmpty)
        XCTAssertEqual(try catalog.products(session: admin, search: "Zinger Burger", includeInactive: true).map(\.id), [burger.id])
        var section = try category("Classic Burgers"); section.isActive = false
        _ = try catalog.saveCategory(session: admin, category: section)
        XCTAssertTrue(try catalog.products(session: admin, search: "Anda").isEmpty)
        var parent = try category("Burgers"); parent.isActive = false
        _ = try catalog.saveCategory(session: admin, category: parent)
        XCTAssertTrue(try catalog.products(session: admin, categoryID: parent.id).isEmpty)
        XCTAssertFalse(try catalog.categories(session: admin).contains { $0.parentID == parent.id })
        XCTAssertEqual(try catalog.products(session: admin, categoryID: parent.id, includeInactive: true).count, 9)
    }

    func testSoldOutItemRemainsVisibleForThePOSIndicator() throws {
        var burger = try product("Zinger Burger"); burger.isAvailable = false
        _ = try catalog.saveProduct(session: admin, product: burger)
        let result = try XCTUnwrap(catalog.products(session: admin, search: "Zinger Burger").first)
        XCTAssertFalse(result.isAvailable); XCTAssertTrue(result.isActive)
    }

    func testCategoryCRUDHierarchyReorderImagesAndSafeDeletion() throws {
        var main = try catalog.saveCategory(session: admin, category: Category(name: "Desserts", displayOrder: -5, icon: "birthday.cake", imagePath: "categories/desserts.jpg"))
        let section = try catalog.saveCategory(session: admin, category: Category(name: "Cakes", parentID: main.id))
        XCTAssertEqual(try catalog.categories(session: admin).first?.id, main.id)
        XCTAssertThrowsError(try catalog.saveCategory(session: admin, category: Category(name: "Nested", parentID: section.id)))
        XCTAssertThrowsError(try catalog.deleteCategory(session: admin, id: main.id))
        main.parentID = try category("Burgers").id
        XCTAssertThrowsError(try catalog.saveCategory(session: admin, category: main))
        main.parentID = nil; main.name = "Sweets"; main.imagePath = nil
        main = try catalog.saveCategory(session: admin, category: main)
        XCTAssertEqual(main.name, "Sweets"); XCTAssertNil(main.imagePath)
        try catalog.deleteCategory(session: admin, id: section.id)
        try catalog.deleteCategory(session: admin, id: main.id)
        XCTAssertFalse(try catalog.categories(session: admin, includeInactive: true).contains { $0.id == main.id })
    }

    func testInvalidCategoryImageReferencesAndMoneyAreRejectedWithoutChanges() throws {
        var item = try product("Chicken Paratha"), unchanged = item
        for path in ["/tmp/image.png", "../escape.png", "products/../../escape.png", "C:\\image.png", "https://example.com/image.png", ""] {
            item.imagePath = path
            XCTAssertThrowsError(try catalog.saveProduct(session: admin, product: item))
        }
        item = unchanged; item.categoryID = try category("Classic Burgers").id
        XCTAssertThrowsError(try catalog.saveProduct(session: admin, product: item))
        item = unchanged; item.subcategoryID = try category("Special Flavours").id
        XCTAssertThrowsError(try catalog.saveProduct(session: admin, product: item))
        item = unchanged; item.basePrice = ServiceValidation.maximumAmount + 1
        XCTAssertThrowsError(try catalog.saveProduct(session: admin, product: item))
        XCTAssertEqual(try catalog.product(session: admin, id: item.id), unchanged)
        unchanged.name = " \n "
        XCTAssertThrowsError(try catalog.saveProduct(session: admin, product: unchanged))
    }

    func testDealCannotBeMarkedSellableUntilEveryComponentIsValid() throws {
        let bundle = try product("Deal 2")
        var deal = try catalog.deal(session: admin, productID: bundle.id)
        XCTAssertTrue(deal.needsReview)
        deal.needsReview = false
        XCTAssertThrowsError(try catalog.saveDeal(session: admin, deal: deal))
        let pizza = try product("Chicken Tikka"), size = try XCTUnwrap(pizza.variants.first { $0.name == "Small" })
        deal.slots[0].choices = [DealChoice(productID: pizza.id, variantID: size.id)]
        try catalog.saveDeal(session: admin, deal: deal)
        let valid = try catalog.deal(session: admin, productID: bundle.id)
        XCTAssertFalse(valid.needsReview)
        deal.slots[0].choices[0].variantID = try XCTUnwrap(product("Crown Crust").variants.first).id
        XCTAssertThrowsError(try catalog.saveDeal(session: admin, deal: deal))
        XCTAssertEqual(try catalog.deal(session: admin, productID: bundle.id), valid)
        deal = valid; deal.slots[0].choices = [DealChoice(productID: bundle.id)]
        XCTAssertThrowsError(try catalog.saveDeal(session: admin, deal: deal))
        deal = valid; deal.slots[0].requiresSelection = false
        XCTAssertThrowsError(try catalog.saveDeal(session: admin, deal: deal))
        deal = valid; deal.slots.append(deal.slots[0])
        XCTAssertThrowsError(try catalog.saveDeal(session: admin, deal: deal))
        XCTAssertEqual(try catalog.deal(session: admin, productID: bundle.id), valid)
    }

    func testDuplicateDealCopiesConfigurationIntoNewIndependentSlots() throws {
        let original = try product("Deal 13"), originalDeal = try catalog.deal(session: admin, productID: original.id)
        let copy = try catalog.duplicateProduct(session: admin, id: original.id)
        let copyDeal = try catalog.deal(session: admin, productID: copy.id)
        XCTAssertFalse(copy.isActive); XCTAssertFalse(copyDeal.needsReview)
        XCTAssertEqual(copyDeal.slots.map(\.choices), originalDeal.slots.map(\.choices))
        XCTAssertEqual(copyDeal.slots.map(\.quantity), originalDeal.slots.map(\.quantity))
        XCTAssertTrue(Set(copyDeal.slots.map(\.id)).isDisjoint(with: Set(originalDeal.slots.map(\.id))))
        try catalog.deleteProduct(session: admin, id: copy.id)
        XCTAssertEqual(try catalog.deal(session: admin, productID: original.id), originalDeal)
    }

    func testSettingsRoundTripValidationAndToppingPriceAudit() throws {
        var settings = try catalog.settings(session: admin)
        settings.restaurantName = "Hungry Spot test"; settings.quickDeliveryCharges = [0, 7_500]
        settings.defaultDeliveryCharge = 7_500; settings.paperWidthMM = 58
        settings.logoPath = "branding/logo.png"; settings.dipSaucePrice = 6_500
        try catalog.saveSettings(session: admin, settings: settings)
        XCTAssertEqual(try catalog.settings(session: admin), settings)
        var invalid = settings; invalid.paperWidthMM = 100
        XCTAssertThrowsError(try catalog.saveSettings(session: admin, settings: invalid))
        invalid = settings; invalid.quickDeliveryCharges = [-1]
        XCTAssertThrowsError(try catalog.saveSettings(session: admin, settings: invalid))
        invalid = settings; invalid.dipSaucePrice = ServiceValidation.maximumAmount + 1
        XCTAssertThrowsError(try catalog.saveSettings(session: admin, settings: invalid))
        XCTAssertEqual(try catalog.settings(session: admin), settings)
        var pizza = try product("Chicken Tikka"); pizza.variants[0].toppingPrice = 7_500
        _ = try catalog.saveProduct(session: admin, product: pizza)
        XCTAssertTrue(try catalog.audit(session: admin).contains { $0.action == "Price changed" && $0.entity == "Product \(pizza.id)" })
    }

    func testCatalogAuditFailureRollsBackAllProductAndVariantRows() throws {
        let before = try product("Chicken Shawarma")
        var changed = before; changed.name = "Should not persist"
        changed.variants[0].price = 99_999; changed.variants.append(ProductVariant(name: "Family", price: 50_000))
        try database.execute(sql: "CREATE TRIGGER reject_catalog_audit BEFORE INSERT ON audit_logs WHEN NEW.action='Product changed' BEGIN SELECT RAISE(ABORT, 'test audit failure'); END")
        XCTAssertThrowsError(try catalog.saveProduct(session: admin, product: changed))
        XCTAssertEqual(try catalog.product(session: admin, id: before.id), before)
    }
}
