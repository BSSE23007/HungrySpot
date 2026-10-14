import AppKit
import HungrySpotCore

@MainActor
protocol PrinterService {
    func printOrder(_ order: OrderRecord, settings: AppSettings, kitchen: Bool) throws
}

enum ReceiptText {
    static func render(_ order: OrderRecord, settings: AppSettings, kitchen: Bool) -> String {
        let separator = String(repeating: "─", count: settings.paperWidthMM == 58 ? 26 : 32)
        let date = DateFormatter(); date.dateStyle = .medium; date.timeStyle = .short
        func money(_ value: Money) -> String { MoneyFormat.string(value, symbol: settings.currencySymbol) }
        var rows = [settings.restaurantName, settings.tagline, separator,
                    "\(kitchen ? "KITCHEN • " : "")ORDER #\(order.number)",
                    date.string(from: order.createdAt), order.type.rawValue]
        if !kitchen { rows += ["Cashier: \(order.cashierName)", "Status: \(order.status.rawValue)"] }
        rows.append(separator)
        for item in order.quote.items {
            rows.append("\(item.quantity) × \(item.productName)")
            if let variant = item.variantName, !variant.isEmpty { rows.append("  \(variant)") }
            if !kitchen { rows.append("  Base each: \(money(item.unitPrice))") }
            for option in item.options {
                if item.variantName != nil && option.name.hasPrefix("Selected variant: ") && option.unitPrice == 0 { continue }
                var line = "  \(option.name) × \(option.quantity)"
                if !kitchen, option.unitPrice > 0 { line += "  \(money(option.unitPrice * Money(option.quantity))) / item" }
                rows.append(line)
            }
            if !item.notes.isEmpty { rows.append("  NOTE: \(item.notes)") }
            if !kitchen { rows.append("  Line total: \(money(item.subtotal))") }
            rows.append("")
        }
        if !order.notes.isEmpty { rows += ["ORDER NOTE: \(order.notes)", ""] }
        if order.type == .delivery {
            rows += ["Customer: \(order.customerName)", "Phone: \(order.customerPhone)", "Address: \(order.customerAddress)", ""]
        }
        if !kitchen {
            rows += [separator, "Subtotal: \(money(order.quote.subtotal))", "Delivery: \(money(order.quote.deliveryCharge))",
                     "Discount: −\(money(order.quote.discount))", "TOTAL: \(money(order.quote.total))", separator]
            if let payment = order.payment { rows += ["Paid by \(payment.method.rawValue)", "Amount: \(money(payment.amount))"] }
            else { rows.append("UNPAID") }
            rows += ["", settings.receiptFooter, settings.phones, settings.address]
        }
        return rows.joined(separator: "\n")
    }
}

@MainActor
final class NativePrinterService: PrinterService {
    func printOrder(_ order: OrderRecord, settings: AppSettings, kitchen: Bool) throws {
        let paperWidth = CGFloat(settings.paperWidthMM == 58 ? 58 : 80) * 72 / 25.4
        let contentWidth = paperWidth - 16
        let font = NSFont.monospacedSystemFont(ofSize: settings.paperWidthMM == 58 ? 8 : 9, weight: .regular)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2; paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: ReceiptText.render(order, settings: settings, kitchen: kitchen), attributes: [
            .font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph
        ])
        let rect = text.boundingRect(with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let height = max(180, ceil(rect.height) + 24)
        let view = ReceiptPrintView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: height), text: text)
        let info = NSPrintInfo(dictionary: NSPrintInfo.shared.dictionary() as! [NSPrintInfo.AttributeKey: Any])
        info.paperSize = NSSize(width: paperWidth, height: height + 16)
        info.topMargin = 8; info.bottomMargin = 8; info.leftMargin = 8; info.rightMargin = 8
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.horizontalPagination = NSPrintInfo.PaginationMode.fit; info.verticalPagination = NSPrintInfo.PaginationMode.automatic
        let printerName = kitchen ? settings.kitchenPrinter : settings.receiptPrinter
        if !printerName.isEmpty {
            guard let printer = NSPrinter(name: printerName) else { throw SpotError.validation("Printer '\(printerName)' is unavailable. Check Settings, then retry printing. The order is saved.") }
            info.printer = printer
        }
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = "Hungry Spot \(kitchen ? "Kitchen" : "Receipt") #\(order.number)"
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        guard operation.run() else {
            throw SpotError.validation("Printing was cancelled or could not be completed. The order remains saved. Use Retry Print in Orders.")
        }
    }
}

private final class ReceiptPrintView: NSView {
    let text: NSAttributedString
    init(frame: NSRect, text: NSAttributedString) { self.text = text; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        text.draw(with: bounds.insetBy(dx: 0, dy: 6), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
