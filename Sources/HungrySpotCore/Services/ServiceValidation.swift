import Foundation

/// Accepts local or +92/92 Pakistani mobile numbers and stores the local 03 form.
/// Only ASCII digits, a leading plus, spaces and hyphens are accepted.
public enum PakistanMobileNumber {
    public static func normalized(_ text: String) throws -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.count <= 50 else { throw invalidNumber }
        if let plus = input.firstIndex(of: "+") {
            guard plus == input.startIndex, !input.dropFirst().contains("+") else { throw invalidNumber }
        }
        let compact = input.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let local: String
        if compact.hasPrefix("+92") { local = "0" + String(compact.dropFirst(3)) }
        else if compact.hasPrefix("92") { local = "0" + String(compact.dropFirst(2)) }
        else { local = compact }
        guard local.range(of: #"^03[0-9]{9}$"#, options: .regularExpression) != nil else { throw invalidNumber }
        return local
    }

    public static func isValid(_ text: String) -> Bool { (try? normalized(text)) != nil }
    private static var invalidNumber: SpotError { .validation("Enter a valid Pakistani mobile number.") }
}

/// Bounds apply to individual user-entered amounts. Aggregates use checked Int64 arithmetic.
enum ServiceValidation {
    static let maximumAmount: Money = 9_999_999_999

    static func amount(_ value: Money, label: String = "Amount", positive: Bool = false) throws {
        guard value >= (positive ? 1 : 0), value <= maximumAmount else {
            throw SpotError.validation("\(label) must be \(positive ? "greater than zero" : "nonnegative") and no more than Rs 99,999,999.99.")
        }
    }

    static func add(_ lhs: Money, _ rhs: Money) throws -> Money {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw SpotError.validation("The total is too large to calculate safely.") }
        return result
    }

    static func multiply(_ value: Money, by quantity: Int) throws -> Money {
        guard let multiplier = Int64(exactly: quantity) else { throw SpotError.validation("Quantity is too large.") }
        let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { throw SpotError.validation("The total is too large to calculate safely.") }
        return result
    }

    static func text(_ value: String, label: String, maximum: Int, required: Bool = false) throws -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count <= maximum, !required || !cleaned.isEmpty else {
            throw SpotError.validation("\(label) \(required && cleaned.isEmpty ? "is required" : "is too long").")
        }
        guard !cleaned.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            throw SpotError.validation("\(label) contains unsupported control characters.")
        }
        return cleaned
    }

    static func dateRange(from: Date, to: Date) throws {
        guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite, from < to else {
            throw SpotError.validation("Choose a valid date range with an end after its start.")
        }
    }
}
