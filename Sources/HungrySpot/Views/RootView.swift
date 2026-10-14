import SwiftUI
import HungrySpotCore

@MainActor
struct RootView: View {
    @EnvironmentObject var app: AppState
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    var body: some View {
        Group {
            if app.session == nil { SignInView() }
            else {
                HStack(spacing: 0) {
                    sidebar.frame(width: sidebarCollapsed ? 64 : 215)
                    Divider()
                    VStack(spacing: 0) {
                        if let notice = app.notice { HStack { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text(notice); Spacer(); Button { app.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(12).background(Color.green.opacity(0.08)) }
                        destination.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.background(SpotTheme.background)
                }
            }
        }
        .alert(item: $app.alert) { message in Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("OK"))) }
        .confirmationDialog("Discard this unsaved order?", isPresented: $app.newOrderRequested, titleVisibility: .visible) { Button("Discard and Start New Order", role: .destructive) { app.resetDraft() }; Button("Keep Current Order", role: .cancel) {} } message: { Text("The items in the current cart have not been punched.") }
    }
    private var sidebar: some View {
        VStack(spacing: 12) {
            sidebarBrand
            Button { sidebarCollapsed.toggle() } label: {
                Image(systemName: sidebarCollapsed ? "chevron.right" : "chevron.left")
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .background(SpotTheme.border, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
            .accessibilityLabel(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
            .padding(.horizontal, 10)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(app.routes) { route in sidebarRoute(route) }
                }.padding(.horizontal, 8)
            }
            sidebarAccount
        }.padding(.top, 16).background(SpotTheme.panel)
    }
    private var sidebarBrand: some View {
        HStack(spacing: 10) {
            BrandImage(path: app.images.url(for: app.settings.logoPath))
                .frame(width: sidebarCollapsed ? 38 : 48, height: sidebarCollapsed ? 46 : 58)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if !sidebarCollapsed {
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.settings.restaurantName).font(.system(size: 13, weight: .heavy, design: .rounded))
                    Text(app.settings.tagline).font(.system(size: 9)).foregroundStyle(SpotTheme.gold)
                }
            }
        }.frame(maxWidth: .infinity).padding(.horizontal, sidebarCollapsed ? 8 : 16)
    }
    private func sidebarRoute(_ route: AppRoute) -> some View {
        Button { app.route = route } label: {
            HStack(spacing: 12) {
                Image(systemName: SpotTheme.symbol(route.symbol)).font(.system(size: 17)).frame(width: 24)
                if !sidebarCollapsed { Text(route.rawValue).fontWeight(.medium); Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity).frame(height: 40)
            .padding(.horizontal, sidebarCollapsed ? 0 : 10)
            .foregroundStyle(app.route == route ? SpotTheme.gold : Color.primary)
            .background(app.route == route ? SpotTheme.orange.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).help(route.rawValue).accessibilityLabel(route.rawValue)
            .accessibilityValue(app.route == route ? "Selected" : "")
    }
    private var sidebarAccount: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !sidebarCollapsed {
                Label("Offline · On this Mac", systemImage: "checkmark.shield.fill").font(.caption).foregroundStyle(.green)
            }
            Divider()
            HStack {
                if !sidebarCollapsed {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.session?.user.username ?? "").fontWeight(.semibold).lineLimit(1)
                        Text(app.isAdmin ? "Administrator" : "Cashier").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                Button { app.logout() } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right").frame(width: 36, height: 36)
                }.buttonStyle(.plain).help("Sign out").accessibilityLabel("Sign out")
            }
        }.padding(sidebarCollapsed ? 14 : 16)
    }
    @ViewBuilder private var destination: some View {
        if app.route.adminOnly && !app.isAdmin { EmptyState(symbol: "lock", title: "Administrator access required", detail: "Use POS, Orders or Menu to continue.") }
        else {
            switch app.route {
            case .dashboard: DashboardView()
            case .pos: POSView()
            case .orders: OrdersView()
            case .menu: MenuManagementView()
            case .categories: CategoriesView()
            case .deals: DealsView()
            case .sales: SalesView()
            case .expenses: ExpensesView()
            case .audit: AuditView()
            case .settings: SettingsView()
            }
        }
    }
}
@MainActor
struct SignInView: View {
    @EnvironmentObject var app: AppState
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                BrandImage().frame(maxWidth: .infinity, maxHeight: .infinity)
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 12) { Text("Good food.\nGreat service.").font(.system(size: 44, weight: .bold, design: .rounded)); Text("Your restaurant, running smoothly.").font(.title3).foregroundStyle(.white.opacity(0.8)) }.padding(45)
            }.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 22) {
                Label("THE HUNGRY SPOT", systemImage: "flame.fill").font(.headline).foregroundStyle(SpotTheme.orange)
                VStack(alignment: .leading, spacing: 10) { Text(app.needsSetup ? "Make it yours." : "Welcome back.").font(.system(size: 34, weight: .bold, design: .rounded)); Text(app.needsSetup ? "Create your administrator account to start. Your restaurant data stays on this Mac." : "Sign in to your restaurant workspace.").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 7) { Text("Username").font(.subheadline.bold()); TextField("Your username", text: $username).textContentType(.username).focused($focused) }
                VStack(alignment: .leading, spacing: 7) { Text("Password").font(.subheadline.bold()); SecureField(app.needsSetup ? "At least 10 characters" : "Your password", text: $password).textContentType(.password) }
                if app.needsSetup { VStack(alignment: .leading, spacing: 7) { Text("Confirm password").font(.subheadline.bold()); SecureField("Repeat password", text: $confirm) }; if !confirm.isEmpty && confirm != password { Text("Passwords must match.").font(.caption).foregroundStyle(.red) } }
                Button(app.needsSetup ? "Create Administrator" : "Sign In") { app.signIn(username: username, password: password, setup: app.needsSetup); password = ""; confirm = "" }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity).keyboardShortcut(.defaultAction).disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || (app.needsSetup && (password != confirm || password.count < 10)))
                Label("Fully offline. Secure local access.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder).controlSize(.large).padding(65).frame(width: 510)
        }.background(SpotTheme.background).onAppear { focused = true }
    }
}
