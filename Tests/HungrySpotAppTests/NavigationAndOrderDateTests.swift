import Foundation
import XCTest
import HungrySpotCore
@testable import HungrySpot

@MainActor
final class NavigationAndOrderDateTests: XCTestCase {
    func testCashierRoutesAreOnlyPOSOrdersAndMenu() {
        XCTAssertEqual(AppRoute.allCases.filter { !$0.adminOnly }, [.pos, .orders, .menu])
        for route in [AppRoute.categories, .deals, .sales, .expenses, .audit, .settings, .dashboard] {
            XCTAssertTrue(route.adminOnly)
        }
    }

    func testTodayUsesLocalMidnightBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Karachi"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 23, minute: 59)))
        let range = try XCTUnwrap(OrderDateScope.today.bounds(now: now, calendar: calendar))
        let expectedStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8)))
        let expectedEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9)))
        XCTAssertEqual(range.start, expectedStart)
        XCTAssertEqual(range.end, expectedEnd)
        XCTAssertNil(try OrderDateScope.allDates.bounds(now: now, calendar: calendar))
    }

    func testTodayHandlesShortAndLongDayAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let spring = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let autumn = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
        XCTAssertEqual(try XCTUnwrap(OrderDateScope.today.bounds(now: spring, calendar: calendar)).duration, 23 * 60 * 60)
        XCTAssertEqual(try XCTUnwrap(OrderDateScope.today.bounds(now: autumn, calendar: calendar)).duration, 25 * 60 * 60)
    }

    func testNormalOrderActionsSkipPreparingReadyAndManualCompletion() {
        XCTAssertEqual(OrderStatus.punched.next, .paymentPending)
        XCTAssertNil(OrderStatus.paymentPending.next)
        XCTAssertNil(OrderStatus.completed.next)
        XCTAssertNil(OrderStatus.cancelled.next)
        XCTAssertEqual(OrderStatus.preparing.next, .paymentPending)
        XCTAssertEqual(OrderStatus.ready.next, .paymentPending)
        XCTAssertEqual(OrderStatus.paid.next, .completed) // Historical paid orders remain usable.
    }
}
