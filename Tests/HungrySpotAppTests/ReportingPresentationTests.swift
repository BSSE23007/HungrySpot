import Foundation
import XCTest
import HungrySpotCore
@testable import HungrySpot

@MainActor
final class ReportingPresentationTests: XCTestCase {

    func testSalesDisplayUsesCollectedSalesAndRecordedExpenses() {
        // Money is stored in paisa: Rs 100,000 less Rs 25,000 = Rs 75,000.
        let report = ReportSummary(sales: 10_000_000, expenses: 2_500_000)

        XCTAssertEqual(SalesDisplayMode.grossSales.amount(in: report), 10_000_000)
        XCTAssertEqual(SalesDisplayMode.afterExpenses.amount(in: report), 7_500_000)
    }

    func testSalesDisplayPreservesPaisaAndNegativeAfterExpenseResult() {
        let report = ReportSummary(sales: 125_051, expenses: 200_079)

        XCTAssertEqual(SalesDisplayMode.grossSales.amount(in: report), 125_051)
        XCTAssertEqual(SalesDisplayMode.afterExpenses.amount(in: report), -75_028)
    }

    func testEmptyAndExpenseOnlyReportsHaveAccurateSalesFigures() {
        let empty = ReportSummary()
        let expenseOnly = ReportSummary(expenses: 99_999)

        XCTAssertEqual(SalesDisplayMode.grossSales.amount(in: empty), 0)
        XCTAssertEqual(SalesDisplayMode.afterExpenses.amount(in: empty), 0)
        XCTAssertEqual(SalesDisplayMode.grossSales.amount(in: expenseOnly), 0)
        XCTAssertEqual(SalesDisplayMode.afterExpenses.amount(in: expenseOnly), -99_999)
    }

    func testChangingSalesDisplayDoesNotSubtractPeriodExpensesFromChart() {
        let daily = [
            ReportRow(name: "2026-10-07", quantity: 1, amount: 70_003),
            ReportRow(name: "2026-10-08", quantity: 2, amount: 30_004)
        ]
        let report = ReportSummary(sales: 100_007, expenses: 25_009, dailySales: daily)

        for mode in SalesDisplayMode.allCases {
            _ = mode.amount(in: report)
            let groups = SalesChart.groupedRows(report.dailySales)
            var collections: Money = 0
            for row in groups {
                collections += row.amount
            }
            XCTAssertEqual(collections, 100_007)
            XCTAssertEqual(report.expenses, 25_009)
            XCTAssertEqual(report.dailySales[0].amount, 70_003)
            XCTAssertEqual(report.dailySales[1].amount, 30_004)
        }
    }

    func testEmptyAndZeroSalesHaveSafeChartGroups() {
        XCTAssertTrue(SalesChart.groupedRows([]).isEmpty)

        let row = ReportRow(
            name: "2026-10-07",
            quantity: 1,
            amount: 0
        )

        let result = SalesChart.groupedRows([row])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].amount, 0)
        XCTAssertEqual(result[0].quantity, 1)
    }

    func testLongReportsKeepEveryPaisaAndOrderWithinBarLimit() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        let counts = [1, 31, 32, 1000]

        for count in counts {
            var input: [ReportRow] = []

            for index in 0..<count {
                let seconds = TimeInterval(index * 86_400)
                let date = Date(timeIntervalSince1970: seconds)
                let name = formatter.string(from: date)

                let quantity = index % 7 + 1
                let amount = Money(index + 1) * 123

                let row = ReportRow(
                    name: name,
                    quantity: quantity,
                    amount: amount
                )

                input.append(row)
            }

            let reversedInput = Array(input.reversed())
            let result = SalesChart.groupedRows(reversedInput)

            XCTAssertLessThanOrEqual(result.count, 31)

            var resultAmount = Money(0)
            for row in result {
                resultAmount += row.amount
            }

            var inputAmount = Money(0)
            for row in input {
                inputAmount += row.amount
            }

            XCTAssertEqual(resultAmount, inputAmount)

            var resultQuantity = 0
            for row in result {
                resultQuantity += row.quantity
            }

            var inputQuantity = 0
            for row in input {
                inputQuantity += row.quantity
            }

            XCTAssertEqual(resultQuantity, inputQuantity)

            XCTAssertTrue(
                result.first?.name.hasPrefix(input[0].name) == true
            )

            XCTAssertTrue(
                result.last?.name.hasSuffix(input[count - 1].name) == true
            )

            var names = Set<String>()
            for row in result {
                names.insert(row.name)
            }

            XCTAssertEqual(names.count, result.count)
        }
    }

    func testChartGroupingHandlesCustomAndInvalidBarLimits() {
        let rows = [
            ReportRow(
                name: "2026-10-05",
                quantity: 1,
                amount: 100
            ),
            ReportRow(
                name: "2026-10-06",
                quantity: 2,
                amount: 200
            ),
            ReportRow(
                name: "2026-10-07",
                quantity: 3,
                amount: 300
            )
        ]

        let limits = [0, -1, 1]

        for limit in limits {
            let grouped = SalesChart.groupedRows(
                rows,
                maximumBars: limit
            )

            XCTAssertEqual(grouped.count, 1)
            XCTAssertEqual(
                grouped[0].name,
                "2026-10-05 – 2026-10-07"
            )
            XCTAssertEqual(grouped[0].amount, 600)
            XCTAssertEqual(grouped[0].quantity, 6)
        }

        let ungrouped = SalesChart.groupedRows(
            rows,
            maximumBars: 3
        )

        XCTAssertEqual(ungrouped.count, 3)
    }
}
