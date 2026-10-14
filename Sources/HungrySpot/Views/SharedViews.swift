import AppKit
import SwiftUI
import UniformTypeIdentifiers
import HungrySpotCore

enum SpotTheme {
    static let background = Color(red: 0.075, green: 0.068, blue: 0.073)
    static let panel = Color(red: 0.12, green: 0.105, blue: 0.11)
    static let burgundy = Color(red: 0.30, green: 0.075, blue: 0.105)
    static let orange = Color(red: 1, green: 0.40, blue: 0.14)
    static let gold = Color(red: 0.97, green: 0.76, blue: 0.38)
    static let border = Color.white.opacity(0.09)
    @MainActor
    static func symbol(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "fork.knife" : name
    }
}
@MainActor
struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { content.padding(20).background(SpotTheme.panel, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(SpotTheme.border)) }
}
@MainActor
struct PageTitle: View {
    let title: String
    let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 28, weight: .bold, design: .rounded)); Text(subtitle).foregroundStyle(.secondary) } }
}
@MainActor
struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View { VStack(spacing: 12) { Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(SpotTheme.gold); Text(title).font(.title3.bold()); Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32) }
}
@MainActor
struct StatusBadge: View {
    let text: String
    var color: Color = SpotTheme.gold
    var body: some View { Text(text).font(.system(size: 10, weight: .bold)).tracking(0.6).padding(.horizontal, 9).padding(.vertical, 5).foregroundStyle(color).background(color.opacity(0.12), in: Capsule()) }
}
@MainActor
struct MoneyField: View {
    let title: String
    @Binding var amount: Money
    @State private var text: String
    @State private var invalid = false
    init(title: String, amount: Binding<Money>) {
        self.title = title
        _amount = amount
        _text = State(initialValue: MoneyFormat.editable(amount.wrappedValue))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $text).textFieldStyle(.roundedBorder).accessibilityLabel(title)
            if invalid { Text("Enter 0–99,999,999.99, with up to 2 decimals.").font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .onChange(of: text) { value in
            do { let parsed = try MoneyFormat.parse(value); invalid = false; amount = parsed }
            catch { invalid = true; amount = -1 }
        }
        .onChange(of: amount) { value in
            if value >= 0, (try? MoneyFormat.parse(text)) != value { text = MoneyFormat.editable(value); invalid = false }
        }
    }
}
@MainActor
struct QuantityControl: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var showsTitle = true
    var body: some View {
        HStack(spacing: 10) {
            if showsTitle { Text(title); Spacer(minLength: 8) }
            quantityButton("minus", label: "Decrease \(title.lowercased())", disabled: value <= range.lowerBound) {
                guard value > range.lowerBound else { return }
                value -= 1
            }
            Text("\(value)")
                .fontWeight(.semibold)
                .monospacedDigit()
                .frame(minWidth: 28)
                .accessibilityLabel("\(title): \(value)")
            quantityButton("plus", label: "Increase \(title.lowercased())", disabled: value >= range.upperBound) {
                guard value < range.upperBound else { return }
                value += 1
            }
        }
    }
    private func quantityButton(_ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .background(SpotTheme.gold.opacity(disabled ? 0.04 : 0.12), in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(disabled ? Color.secondary : SpotTheme.gold)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
@MainActor
struct BrandImage: View {
    var path: URL? = nil
    var body: some View {
        Group {
            if let source = path.flatMap({ NSImage(contentsOf: $0) }) ?? bundledLogo { Image(nsImage: source).resizable().scaledToFill() }
            else { Image(systemName: "flame.fill").resizable().scaledToFit().padding(20).foregroundStyle(SpotTheme.orange) }
        }.clipped().accessibilityLabel("The Hungry Spot")
    }
    private var bundledLogo: NSImage? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return bundle.url(forResource: "Branding", withExtension: "jpg").flatMap { NSImage(contentsOf: $0) }
    }
}
@MainActor
struct ProductImage: View {
    @EnvironmentObject var app: AppState
    let product: Product
    var body: some View {
        Group {
            if let url = app.images.url(for: product.imagePath), let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFill() }
            else { ZStack { LinearGradient(colors: [SpotTheme.burgundy.opacity(0.8), SpotTheme.panel], startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: product.kind == .deal ? "gift.fill" : product.kind == .pizza ? "circle.grid.cross.fill" : "fork.knife").font(.system(size: 30)).foregroundStyle(SpotTheme.gold.opacity(0.75)) } }
        }.clipped()
    }
}
@MainActor
struct ImagePickerField: View {
    @EnvironmentObject var app: AppState
    @Binding var path: String?
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let url = app.images.url(for: path), let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: "photo.badge.plus").font(.system(size: 34)).foregroundStyle(SpotTheme.gold) }
            }.frame(height: 120)
            Text("Drop an image here").foregroundStyle(.secondary)
            HStack {
                Button("Choose Image…") { let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false; if panel.runModal() == .OK, let url = panel.url { importImage(url) } }
                if path != nil { Button("Remove", role: .destructive) { path = nil } }
            }
        }.frame(maxWidth: .infinity).padding(20).background(targeted ? SpotTheme.burgundy : SpotTheme.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SpotTheme.gold.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5])))
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted, perform: acceptDrop)
    }
    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            let url: URL?
            if let value = item as? URL { url = value }
            else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = nil }
            DispatchQueue.main.async {
                guard error == nil, let url = url, url.isFileURL else {
                    self.app.alert = AppMessage(title: "Image could not be imported", detail: error?.localizedDescription ?? "Drop a local image file from Finder, or use Choose Image.")
                    return
                }
                // ImageStorageService brackets its read with security-scoped access,
                // validates the file and image decoder, and copies into app storage.
                self.importImage(url)
            }
        }
        return true
    }
    private func importImage(_ url: URL) { app.run { path = try app.images.importImage(from: url) } }
}
@MainActor
struct FieldRow<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            content
        }
    }
}
@MainActor
struct MultilineField: View {
    let title: String
    @Binding var text: String
    var height: CGFloat = 70
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: height)
                .padding(4)
                .background(SpotTheme.background)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(SpotTheme.border))
                .accessibilityLabel(title)
        }
    }
}
@MainActor
struct SheetHeader: View {
    let title: String
    let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.title2.bold()); Text(subtitle).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
}
extension OrderStatus {
    var color: Color { switch self { case .paid, .completed: return .green; case .cancelled: return .red; case .ready: return .cyan; default: return SpotTheme.gold } }
    var next: OrderStatus? { switch self { case .punched, .preparing, .ready: return .paymentPending; case .paid: return .completed; default: return nil } }
}
