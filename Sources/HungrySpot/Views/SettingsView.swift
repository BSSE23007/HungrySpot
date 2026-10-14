import AppKit
import SwiftUI
import HungrySpotCore

@MainActor
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var settings = AppSettings()
    @State private var presets = ""
    @State private var tab = 0
    @State private var validation: String?
    @State private var printers: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                PageTitle(title: "Settings", subtitle: "The details that make this restaurant yours.")
                Spacer()
                if tab < 3 { Button("Save Settings") { save() }.buttonStyle(.borderedProminent) }
            }
            if let validation { Label(validation, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            TabView(selection: $tab) {
                business.tabItem { Label("Business", systemImage: "building.2") }.tag(0)
                delivery.tabItem { Label("Delivery & Pricing", systemImage: "bicycle") }.tag(1)
                printing.tabItem { Label("Printers", systemImage: "printer") }.tag(2)
                UsersSettingsView().tabItem { Label("Users", systemImage: "person.2") }.tag(3)
                BackupSettingsView().tabItem { Label("Backups", systemImage: "externaldrive") }.tag(4)
            }
        }.padding(26).onAppear { settings = app.settings; presets = settings.quickDeliveryCharges.map(MoneyFormat.editable).joined(separator: ", "); printers = NSPrinter.printerNames }
    }
    private var business: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 26) {
                Form {
                    Section("Restaurant") {
                        TextField("Restaurant name", text: $settings.restaurantName)
                        TextField("Tagline", text: $settings.tagline)
                        TextField("Phone numbers", text: $settings.phones)
                        MultilineField(title: "Address", text: $settings.address)
                        TextField("Opening hours", text: $settings.hours)
                    }
                    Section("Receipts") {
                        TextField("Currency symbol", text: $settings.currencySymbol)
                        MultilineField(title: "Receipt footer", text: $settings.receiptFooter)
                    }
                }.textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) { Text("Restaurant logo").font(.headline); ImagePickerField(path: $settings.logoPath); Text("The supplied Hungry Spot branding is used when no custom logo is selected.").font(.caption).foregroundStyle(.secondary) }.frame(width: 255).padding(.top, 25)
            }.padding(18)
        }
    }
    private var delivery: some View {
        ScrollView {
            Form {
                Section("Delivery charges") {
                    MoneyField(title: "Default delivery charge", amount: $settings.defaultDeliveryCharge)
                    TextField("Quick amounts, separated by commas", text: $presets)
                    Text("Use up to 12 nonnegative amounts, such as 0, 50, 100, 150, 200. The cashier can also enter a custom amount on each delivery order.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Pizza extras") {
                    MoneyField(title: "Dip sauce price", amount: $settings.dipSaucePrice)
                    Text("Topping prices are configured per pizza size in Menu → Edit Product.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Discount permission") {
                    Toggle("Allow cashiers to enter discounts", isOn: $settings.cashierCanDiscount)
                    Text("Administrators can always apply a discount. Discounts are validated when an order is punched and recorded in its history.").font(.caption).foregroundStyle(.secondary)
                }
            }.textFieldStyle(.roundedBorder).frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }
    }
    private var printing: some View {
        ScrollView {
            Form {
                Section("Printer destinations") {
                    printerPicker("Customer receipt", selection: $settings.receiptPrinter)
                    printerPicker("Kitchen ticket", selection: $settings.kitchenPrinter)
                    Button("Refresh Printer List") { printers = NSPrinter.printerNames }
                    Text("Add printers in macOS System Preferences → Printers & Scanners first. Every print opens the native print dialog, where you can confirm the destination or save a PDF.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Receipt paper") {
                    Picker("Paper width", selection: $settings.paperWidthMM) { Text("58 mm").tag(58); Text("80 mm").tag(80) }.pickerStyle(.segmented)
                    Toggle("Open kitchen print dialog after punching an order", isOn: $settings.autoPrintKitchen)
                }
                Section("Verify your printer") {
                    Text("Select a saved order in Orders, then print its kitchen ticket and customer receipt. Check paper size, scaling and margins in the native dialog.").foregroundStyle(.secondary)
                    if let order = app.printTarget {
                        Button("Print Selected Order Receipt") { printSelected(order, kitchen: false) }
                        Button("Print Selected Order Kitchen Ticket") { printSelected(order, kitchen: true) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }
    }
    private func printerPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("System default / choose in dialog").tag("")
            ForEach(Array(Set(printers + (selection.wrappedValue.isEmpty ? [] : [selection.wrappedValue]))).sorted(), id: \.self) { printer in Text(printer + (printers.contains(printer) ? "" : " · unavailable")).tag(printer) }
        }
    }
    private func printSelected(_ order: OrderRecord, kitchen: Bool) {
        guard let session = app.session else { return }
        do { let current = try app.orders.order(session: session, id: order.id); try app.printer.printOrder(current, settings: settings, kitchen: kitchen); validation = nil }
        catch { validation = error.localizedDescription }
    }
    private func save() {
        guard let session = app.session else { return }
        do {
            let fields = presets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : presets.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let values = try fields.map { try MoneyFormat.parse($0) }
            guard values.count <= 12 else { throw SpotError.validation("Enter up to 12 delivery amounts.") }
            settings.quickDeliveryCharges = Array(Set(values)).sorted()
            try app.catalog.saveSettings(session: session, settings: settings)
            try app.reloadCatalog(); presets = settings.quickDeliveryCharges.map(MoneyFormat.editable).joined(separator: ", "); validation = nil; app.notice = "Restaurant settings saved."
        } catch { validation = error.localizedDescription }
    }
}

@MainActor
struct UsersSettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var users: [User] = []
    @State private var editing: User?
    @State private var changingPassword = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("Team access").font(.title3.bold()); Text("Administrators manage the restaurant. Cashiers take orders and payments.").foregroundStyle(.secondary) }
                Spacer()
                Button("Change My Password") { changingPassword = true }
                Button { editing = User(id: 0, username: "", role: .cashier) } label: { Label("Add User", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            List(users) { user in
                HStack(spacing: 15) {
                    Image(systemName: user.role == .admin ? "person.crop.circle.badge.checkmark" : "person.crop.circle").font(.title2).foregroundStyle(SpotTheme.gold)
                    VStack(alignment: .leading, spacing: 4) { Text(user.username).fontWeight(.semibold); Text(user.role == .admin ? "Administrator" : "Cashier").font(.caption).foregroundStyle(.secondary) }
                    if user.id == app.session?.user.id { StatusBadge(text: "YOU") }
                    Spacer()
                    StatusBadge(text: user.isActive ? "ACTIVE" : "DISABLED", color: user.isActive ? .green : .gray)
                    Button("Edit") { editing = user }
                }.padding(.vertical, 10)
            }.listStyle(.inset)
            Text("Disabling an account preserves its order history. At least one active administrator is required. Changing an account invalidates that user's sessions.").font(.caption).foregroundStyle(.secondary)
        }.padding(22).onAppear { load() }.onChange(of: app.revision) { _ in load() }
        .sheet(item: $editing) { UserEditor(user: $0) }
        .sheet(isPresented: $changingPassword) { PasswordEditor() }
    }
    private func load() { guard let session = app.session else { return }; app.run { users = try app.auth.users(session: session) } }
}

@MainActor
struct UserEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var user: User
    @State private var password = ""
    @State private var confirmation = ""
    @State private var validation: String?
    init(user: User) { _user = State(initialValue: user) }
    private var passwordValid: Bool { user.id != 0 && password.isEmpty || password.count >= 10 && password == confirmation }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: user.id == 0 ? "Add team member" : "Edit account", subtitle: "Usernames use letters, digits, dots, underscores or hyphens.")
            TextField("Username", text: $user.username).textContentType(.username)
            Picker("Role", selection: $user.role) { Text("Administrator").tag(Role.admin); Text("Cashier").tag(Role.cashier) }.pickerStyle(.segmented)
            Toggle("Account is active", isOn: $user.isActive)
            SecureField(user.id == 0 ? "Password — at least 10 characters" : "New password — leave blank to keep current", text: $password).textContentType(.password)
            if !password.isEmpty { SecureField("Confirm password", text: $confirmation); if !confirmation.isEmpty && password != confirmation { Text("Passwords must match.").font(.caption).foregroundStyle(.orange) } }
            if user.id == app.session?.user.id { Label("Saving changes to your account signs you out. Use the updated credentials to sign in again.", systemImage: "person.crop.circle.badge.exclamationmark").font(.caption).foregroundStyle(SpotTheme.gold) }
            if let validation { Text(validation).foregroundStyle(.orange).font(.caption) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Save Account") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(user.username.isEmpty || !passwordValid) }
        }.textFieldStyle(.roundedBorder).padding(26).frame(width: 520)
    }
    private func save() {
        guard let session = app.session else { return }
        do {
            let saved = try app.auth.saveUser(session: session, id: user.id == 0 ? nil : user.id, username: user.username, password: password.isEmpty ? nil : password, role: user.role, isActive: user.isActive)
            password = ""; confirmation = ""; dismiss()
            if saved.id == session.user.id { app.clearSession(); app.alert = AppMessage(title: "Account updated", detail: "Sign in again using your updated account credentials.") }
            else { app.revision += 1; app.notice = "Account saved." }
        } catch { validation = error.localizedDescription }
    }
}

@MainActor
struct PasswordEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var validation: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Change your password", subtitle: "Choose a password of at least 10 characters.")
            SecureField("Current password", text: $current).textContentType(.password)
            SecureField("New password", text: $password).textContentType(.password)
            SecureField("Confirm new password", text: $confirmation)
            if let validation { Text(validation).font(.caption).foregroundStyle(.orange) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Change Password") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(current.isEmpty || password.count < 10 || password != confirmation) }
        }.textFieldStyle(.roundedBorder).padding(26).frame(width: 470)
    }
    private func save() {
        guard let session = app.session else { return }
        do { try app.auth.changePassword(session: session, currentPassword: current, newPassword: password); current = ""; password = ""; confirmation = ""; app.notice = "Password changed."; dismiss() }
        catch { validation = error.localizedDescription }
    }
}

private struct RestoreRequest: Identifiable {
    let id = UUID()
    let url: URL
    let summary: String
}

@MainActor
struct BackupSettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var lastBackup: URL?
    @State private var restoring: RestoreRequest?
    @State private var validation: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Panel {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Back up the restaurant", systemImage: "externaldrive.badge.plus").font(.title3.bold())
                        Text("A backup includes the database, accounts, menu, orders, settings and imported images. Keep a copy on a separate drive.").foregroundStyle(.secondary)
                        HStack { Button("Create Local Backup") { create(destination: nil) }.buttonStyle(.borderedProminent); Button("Back Up to Folder…") { chooseDestination() }; Button("Open Backups Folder") { NSWorkspace.shared.open(app.paths.backups) } }
                        if let lastBackup { HStack { Label("Backup verified and saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green); Spacer(); Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([lastBackup]) } }; Text(lastBackup.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Panel {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Restore a backup", systemImage: "arrow.counterclockwise.circle").font(.title3.bold())
                        Text("Choose a Hungry Spot backup folder. Its contents are verified before you confirm. Restoring replaces current data and signs everyone out; a safety backup is kept first.").foregroundStyle(.secondary)
                        Button("Choose Backup to Review…") { chooseRestore() }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Panel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Local data location").font(.headline)
                        Text(app.paths.root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Show Data Folder") { NSWorkspace.shared.open(app.paths.root) }
                        Text("Backups contain customer details and account password hashes. Store them somewhere only trusted people can access.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let validation { Label(validation, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(22)
        }.sheet(item: $restoring) { request in RestoreConfirmationView(url: request.url, summary: request.summary) }
    }
    private func chooseDestination() {
        let panel = NSOpenPanel(); panel.title = "Choose where to save the backup"; panel.prompt = "Back Up Here"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { create(destination: url) }
    }
    private func create(destination: URL?) {
        guard let session = app.session else { return }
        do { lastBackup = try app.backups.create(session: session, destination: destination); validation = nil; app.revision += 1 }
        catch { validation = error.localizedDescription }
    }
    private func chooseRestore() {
        let panel = NSOpenPanel(); panel.title = "Choose a Hungry Spot backup folder"; panel.prompt = "Review Backup"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.directoryURL = app.paths.backups
        if panel.runModal() == .OK, let url = panel.url {
            do { restoring = RestoreRequest(url: url, summary: try app.backups.validate(url)); validation = nil }
            catch { validation = error.localizedDescription }
        }
    }
}

@MainActor
struct RestoreConfirmationView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let summary: String
    @State private var acknowledged = false
    @State private var validation: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeader(title: "Restore this backup?", subtitle: "\(url.lastPathComponent)")
            Text(summary).foregroundStyle(SpotTheme.gold)
            Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("The current catalog, orders, users, settings and images will be replaced by this backup. You will need a username and password from the backup to sign in afterward.")
            Toggle("I understand that current data will be replaced", isOn: $acknowledged)
            if let validation { Text(validation).font(.caption).foregroundStyle(.orange) }
            HStack { Button("Keep Current Data") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Restore Backup", role: .destructive) { restore() }.buttonStyle(.borderedProminent).disabled(!acknowledged) }
        }.padding(28).frame(width: 580)
    }
    private func restore() {
        guard let session = app.session, acknowledged else { return }
        do {
            try app.backups.restore(session: session, from: url, confirmed: true)
            dismiss(); app.clearSession(); app.alert = AppMessage(title: "Backup restored", detail: "Sign in with an account from the restored backup. A safety copy of the previous data is in the Backups folder.")
        } catch { validation = error.localizedDescription }
    }
}
