import SwiftUI
import SideACore

extension Color {
    static let deckInk = Color(red: 0.13, green: 0.15, blue: 0.14)
    static let deckPaper = Color(red: 0.91, green: 0.92, blue: 0.91)
    static let deckOrange = Color(red: 0.88, green: 0.29, blue: 0.10)
}

/// The device is the entire idle interface. Setup appears only when requested
/// through OPEN; account and session state live on the physical LCD.
struct PlayerView: View {
    @Bindable var store: AccountStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        DiscmanView(provider: store.selected?.provider.title ?? "SIDE A", account: store.selected?.name ?? "NO DISC", track: store.trackNumber,
                    count: store.config.accounts.count, smart: store.config.smartMode,
                    held: store.held, lidOpen: store.lidOpen, reducedMotion: reduceMotion,
                    status: displayStatus, guideControl: guideControl, activeAccount: store.active?.name,
                    perform: handle)
            .frame(width: 620, height: 620)
            .background(TransparentPlayerWindow())
            .ignoresSafeArea()
            .modifier(ClearWindowSurface())
            .onAppear {
                store.showSettings = { openSettings() }
                if !store.playerRequested { dismissWindow(id: "player") }
            }
            .alert("Side A", isPresented: Binding(
                get: { store.error != nil && !NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true } },
                set: { if !$0 { store.error = nil } }
            )) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
    }

    private var guideControl: String? {
        guard !store.isDemo, !store.held, !store.startupError else { return nil }
        if store.config.accounts.isEmpty || store.selected?.ready != true { return "open" }
        // Codex is never switched, so PLAY only applies to Claude accounts.
        return store.selected.map { !store.isActive($0) && $0.provider == .claude } == true ? "play" : nil
    }

    private var displayStatus: String {
        if store.isDemo { return "PREVIEW / OPEN TO CONNECT" }
        if store.held { return "CONTROLS LOCKED" }
        if store.startupError { return "LIBRARY NEEDS ATTENTION" }
        if store.config.accounts.isEmpty { return "OPEN TO ADD ACCOUNT" }
        guard let selected = store.selected, selected.ready else { return "OPEN TO FINISH SIGN-IN" }
        let usage = store.usage[selected.id]
        let levels = [usage?.fiveHour.map { "5H \(Int($0.percent.rounded()))%" }, usage?.weekly.map { "WK \(Int($0.percent.rounded()))%" },
                      usage?.fable.map { "FB \(Int($0.percent.rounded()))%" }]
            .compactMap { $0 }.joined(separator: " ")
        if store.isActive(selected) { return levels.isEmpty ? "ACTIVE ON THIS MAC" : "ACTIVE / " + levels }
        if levels.isEmpty { return "PLAY TO USE ON THIS MAC" }
        return levels
    }

    private func handle(_ action: String) {
        switch action {
        case "previous": store.step(-1)
        case "next": store.step(1)
        case "play": store.play()
        case "stop", "project": Task { await store.refreshAll() }
        case "open": store.openLibrary()
        case "hold": store.held.toggle()
        case "mode": if !store.held { store.toggleSmart() }
        default: break
        }
    }
}
