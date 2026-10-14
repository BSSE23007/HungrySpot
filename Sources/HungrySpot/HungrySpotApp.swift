import AppKit
import SwiftUI

@MainActor
final class AppRuntime: ObservableObject {
    @Published var state: AppState?
    @Published var failure: String?
    init() { start() }
    func start() {
        do { state = try AppState(); failure = nil }
        catch { failure = error.localizedDescription }
    }
}

@main
@MainActor
struct HungrySpotApp: App {
    @StateObject private var runtime = AppRuntime()
    var body: some Scene {
        WindowGroup {
            Group {
                if let state = runtime.state {
                    RootView().environmentObject(state)
                        .preferredColorScheme(.dark)
                        .tint(SpotTheme.orange)
                        .frame(minWidth: 1060, minHeight: 620)
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 42)).foregroundStyle(.orange)
                        Text("The Hungry Spot could not open").font(.title2.bold())
                        Text(runtime.failure ?? "Unknown startup error").textSelection(.enabled).frame(maxWidth: 540)
                        Text("Your existing data has not been reset. Check the Application Support folder permissions and available disk space.").foregroundStyle(.secondary).frame(maxWidth: 540)
                        Button("Try Again") { runtime.start() }.buttonStyle(.borderedProminent)
                    }.padding(50).frame(minWidth: 760, minHeight: 480)
                }
            }
            .background(InitialWindowSizing())
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Order") { runtime.state?.requestNewOrder() }.keyboardShortcut("n").disabled(runtime.state?.session == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Search Menu") { runtime.state?.route = .pos; runtime.state?.searchRequested += 1 }.keyboardShortcut("f").disabled(runtime.state?.session == nil)
            }
            CommandGroup(replacing: .printItem) {
                Button("Print Receipt") {
                    if let state = runtime.state, let order = state.printTarget { state.print(order, kitchen: false) }
                }.keyboardShortcut("p").disabled(runtime.state?.printTarget == nil)
            }
        }
    }
}

/// AppKit supplies initial sizing on Monterey, including the title bar and Dock.
@MainActor
private struct InitialWindowSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView { SizingView() }
    func updateNSView(_ nsView: SizingView, context: Context) {}

    @MainActor
    final class SizingView: NSView {
        private var configured = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !configured, window != nil else { return }
            configured = true
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window,
                      let screen = window.screen ?? NSScreen.main else { return }
                let visible = screen.visibleFrame
                let proposed = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1200, height: 680))
                let width = min(proposed.width, visible.width)
                let height = min(proposed.height, visible.height)
                window.setFrame(NSRect(x: visible.midX - width / 2,
                                       y: visible.midY - height / 2,
                                       width: width, height: height), display: true)
            }
        }
    }
}
