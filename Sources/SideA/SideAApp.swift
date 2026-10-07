import SwiftUI

@main
struct SideAApp: App {
    @State private var store: AccountStore
    init() {
        let store = AccountStore()
        _store = State(initialValue: store)
        DispatchQueue.main.async { store.setMenuBarOnly(store.config.menuBarOnly) }
    }
    var body: some Scene {
        Window("Side A", id: "player") {
            PlayerView(store: store)
        }
        .defaultSize(width: 620, height: 620)
        .hiddenAtLaunch()
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .help) { Button("Save diagnostics…") { store.saveDiagnostics() } }
            CommandMenu("Player") {
                Button("Use selected account on this Mac") { store.play() }.keyboardShortcut(.return, modifiers: .command)
                Button("Previous account") { store.step(-1) }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Next account") { store.step(1) }.keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Button("Accounts…") { store.openLibrary() }.keyboardShortcut("l", modifiers: .command)
                Button("Hold controls") { store.held.toggle() }.keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra {
            MenuPlayer(store: store)
        } label: {
            // The menu bar is the main surface: a gauge and the active account's tightest limit.
            if let percent = menuPercent {
                Label("\(percent)%", systemImage: Self.gauge(percent)).labelStyle(.titleAndIcon)
            } else {
                Label("Side A", systemImage: "gauge.with.dots.needle.0percent").labelStyle(.iconOnly)
            }
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView(store: store) }
    }
    /// The active Claude account's tightest limit: 5-hour or weekly, whichever is closer.
    private var menuPercent: Int? {
        guard let account = store.active, let usage = store.usage[account.id] else { return nil }
        let percents = [usage.fiveHour, usage.weekly].compactMap { $0?.percent }
        return percents.max().map { Int($0.rounded()) }
    }
    static func gauge(_ percent: Int) -> String {
        "gauge.with.dots.needle." + (percent >= 90 ? "100" : percent >= 60 ? "67" : percent >= 30 ? "33" : "0") + "percent"
    }
}

extension Scene {
    /// The player is optional; Side A lives in the menu bar and opens the player on request.
    func hiddenAtLaunch() -> some Scene {
        if #available(macOS 15, *) { return self.defaultLaunchBehavior(.suppressed) }
        return self
    }
}
