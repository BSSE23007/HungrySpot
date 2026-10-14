import XCTest
@testable import HungrySpotCore

final class CheckoutValidationTests: XCTestCase {
    func testPakistanLocalInternationalAndFormattedMobileNumbers() throws {
        for value in ["03004573301", "0300-4573301", "+923004573301", "923004573301", " +92 300 4573301 "] {
            XCTAssertEqual(try PakistanMobileNumber.normalized(value), "03004573301")
            XCTAssertTrue(PakistanMobileNumber.isValid(value))
        }
    }

    func testPakistanMobileRejectsBlankWrongLengthAndNonMobilePrefixes() {
        for value in ["", "  - ", "0300457330", "030045733011", "+92300457330", "9230045733011", "02104573301", "04004573301", "+913004573301", "00923004573301"] {
            XCTAssertFalse(PakistanMobileNumber.isValid(value), value)
            XCTAssertThrowsError(try PakistanMobileNumber.normalized(value), value)
        }
    }

    func testPakistanMobileRejectsLettersUnicodeDigitsAndMalformedPlus() {
        for value in ["03O04573301", "۰۳۰۰۴۵۷۳۳۰۱", "0300+4573301", "++923004573301", "92+3004573301", "-+923004573301", "+03004573301", "0300/4573301", "0300\n4573301"] {
            XCTAssertFalse(PakistanMobileNumber.isValid(value), value)
            XCTAssertThrowsError(try PakistanMobileNumber.normalized(value), value)
        }
    }

    func testExactCashHasZeroChange() throws {
        let quote = try CashPaymentQuote(total: 125_000, tendered: 125_000)
        XCTAssertTrue(quote.canConfirm); XCTAssertEqual(quote.change, 0); XCTAssertEqual(quote.shortage, 0)
    }

    func testOverTenderedCashReturnsPreciseMinorUnitChange() throws {
        let quote = try CashPaymentQuote(total: 125_001, tendered: 200_000)
        XCTAssertEqual(quote.total, 125_001); XCTAssertEqual(quote.tendered, 200_000)
        XCTAssertTrue(quote.canConfirm); XCTAssertEqual(quote.change, 74_999); XCTAssertEqual(quote.shortage, 0)
    }

    func testUnderTenderedCashCannotConfirmAndShowsShortage() throws {
        let quote = try CashPaymentQuote(total: 125_000, tendered: 124_999)
        XCTAssertFalse(quote.canConfirm); XCTAssertEqual(quote.shortage, 1); XCTAssertEqual(quote.change, 0)
    }

    func testCashQuoteRejectsInvalidAmountsAndHandlesBounds() throws {
        for invalid in [Money(-1), Int64.max] {
            XCTAssertThrowsError(try CashPaymentQuote(total: invalid, tendered: 0))
            XCTAssertThrowsError(try CashPaymentQuote(total: 0, tendered: invalid))
        }
        let quote = try CashPaymentQuote(total: 0, tendered: ServiceValidation.maximumAmount)
        XCTAssertEqual(quote.change, ServiceValidation.maximumAmount); XCTAssertTrue(quote.canConfirm)
    }
}
