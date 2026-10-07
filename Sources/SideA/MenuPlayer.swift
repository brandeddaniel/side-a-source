import SideACore
import SwiftUI

/// The menu bar is Side A's home: usage for every account and the Mac-wide login.
struct MenuPlayer: View {
    /// Local calendar date `offset` days from today, in the report's yyyy-MM-dd form.
    static func day(_ offset: Int) -> String {
        Date.ISO8601FormatStyle(timeZone: .current).year().month().day().format(Calendar.current.date(byAdding: .day, value: offset, to: Date())!)
    }
    @Bindable var store: AccountStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("tourSeen") private var tourSeen = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Side A").font(.headline)
                Spacer()
                Button { Task { await store.refreshAll(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh usage")
            }
            ForEach(AgentProvider.allCases) { provider in
                if let email = store.unknownLogins[provider] {
                    HStack {
                        Text("\(provider.title) on this Mac: \(email)").font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Add") { Task { await store.adoptMacLogin(provider) } }.controlSize(.small)
                    }
                }
            }
            if store.config.accounts.isEmpty {
                Text("Add an account to see its limits.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(AgentProvider.allCases) { provider in
                        ProviderSection(store: store, provider: provider, firstID: store.config.accounts.first?.id)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            FableSessions(store: store)
            if !store.shellSwitching && !store.isDemo && store.config.accounts.contains(where: { $0.provider == .claude }) {
                HStack {
                    Text("Switching is off in Terminal").font(.system(size: 11))
                    Spacer()
                    Button("Turn on") { Task { await store.setShellSwitching(true) } }.controlSize(.small)
                }
            }
            if store.unknownLogins[.claude] == nil, let next = Planner.nextAvailable(store.config.accounts.filter { $0.provider == .claude }, usage: store.usage, now: Date().timeIntervalSince1970),
               Planner.best(store.config.accounts.filter { $0.provider == .claude }, usage: store.usage, active: nil, now: Date().timeIntervalSince1970, ignoringModelLimits: true) == nil {
                Text("All limited. \(next.0.name) is back \(UsageBar.format(next.1)).")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let report = store.report, !report.days.isEmpty {
                // Calendar days: an idle day counts as zero, not as the last active day.
                let today = report.days.first { $0.date == Self.day(0) }?.total ?? 0
                Button { store.settingsTab = .usage; store.openSettings() } label: {
                    HStack(spacing: 4) {
                        Text("Today \(TokenCount.short(today))")
                        Text("· 7 days \(TokenCount.short(report.days.filter { ($0.date ?? "") >= Self.day(-6) }.map(\.total).reduce(0, +)))").foregroundStyle(.secondary)
                        if let top = report.projects.first?.project { Text("· \(URL(fileURLWithPath: top).lastPathComponent)").foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }.font(.system(size: 11)).contentShape(.rect)
                }.buttonStyle(.plain).help("Tokens by day, project and model").tourAnchor(.usage)
            }
            if let error = store.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(4)
                    .onTapGesture { store.error = nil }
            }
            Divider()
            Toggle(isOn: Binding(get: { store.config.smartMode }, set: { _ in store.toggleSmart() })) {
                Text("Autopilot")
            }.toggleStyle(.switch).controlSize(.small).tourAnchor(.autopilot)
            HStack(spacing: 14) {
                Button { store.openLibrary() } label: { Label("Add account", systemImage: "plus") }.tourAnchor(.add)
                Spacer()
                Button { openPlayer() } label: { Image(systemName: "opticaldisc") }.help("Show the player")
                Button { store.settingsTab = .general; store.openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Side A")
            }.buttonStyle(.borderless).font(.system(size: 12))
        }.padding(16).frame(width: 320)
        .guidedTour(isPresented: Binding(get: { !tourSeen && !store.isDemo }, set: { if !$0 { tourSeen = true } }))
        .task { await store.refreshAll() }
        .onAppear { store.showSettings = { openSettings() } }
    }
    private func openPlayer() { store.playerRequested = true; openWindow(id: "player"); NSApp.activate(ignoringOtherApps: true) }
}

/// One provider's accounts. Accounts at their weekly limit fold away until they reset.
struct ProviderSection: View {
    @Bindable var store: AccountStore
    let provider: AgentProvider
    let firstID: String?
    @State private var showLimited = false

    var body: some View {
        let accounts = store.config.accounts.filter { $0.provider == provider }
        let now = Date().timeIntervalSince1970
        let limited = accounts.filter { account in
            !store.isActive(account) && (store.usage[account.id]?.weeklyLimits ?? []).contains { $0.percent >= Planner.full && ($0.resetsAt ?? 0) > now }
        }
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(provider.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(accounts.filter { account in !limited.contains { $0.id == account.id } }) { account in
                    AccountUsageRow(store: store, account: account)
                        .modifier(TourAnchorIf(step: .limits, active: account.id == firstID))
                }
                if !limited.isEmpty {
                    // Instant: an animated height resizes the menu window every frame and flashes the scroller.
                    Button { showLimited.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(showLimited ? 90 : 0))
                                .animation(.easeOut(duration: 0.15), value: showLimited)
                            Text("Limited (\(limited.count))")
                            if let reset = limited.compactMap({ store.usage[$0.id]?.weeklyLimits.filter { $0.percent >= Planner.full }.compactMap(\.resetsAt).max() }).min() {
                                Text("· next back \(UsageBar.format(reset))").foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.font(.system(size: 11)).contentShape(.rect)
                    }.buttonStyle(.plain)
                    if showLimited {
                        ForEach(limited) { AccountUsageRow(store: store, account: $0) }
                    }
                }
            }
        }
    }
}

struct AccountUsageRow: View {
    @Bindable var store: AccountStore
    let account: Account
    var body: some View {
        let isActive = store.isActive(account)
        let usage = store.usage[account.id]
        HStack(spacing: 8) {
            Circle().fill(isActive ? Color.green : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                .accessibilityLabel(isActive ? "Active on this Mac" : "Not active")
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name).font(.system(size: 12, weight: isActive ? .semibold : .regular)).lineLimit(1)
                if let caption { Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if let usage {
                // Claude accounts always get a Fable column so rows line up; "fb –" until it is reported.
                let showFable = account.provider == .claude || usage.fable != nil
                let width: CGFloat = showFable ? 36 : 46
                MiniBar(label: "5h", window: usage.fiveHour, width: width)
                MiniBar(label: "wk", window: usage.weekly, width: width)
                if showFable { MiniBar(label: "fb", window: usage.fable, width: width) }
            }
            Group {
                if !account.ready {
                    Button("Sign in") { Task { await store.signIn(account.id) } }
                        .disabled(store.signingIn.contains(account.id))
                } else if !isActive && account.provider == .claude {
                    Button("Use") { Task { await store.activate(account.id) } }.tourAnchor(.use)
                        .help("New claude commands use this account")
                } else {
                    Color.clear
                }
            }.controlSize(.mini).frame(width: 44)
        }
        .frame(minHeight: 28)
        .contextMenu {
            if !isActive && account.ready && account.provider == .claude { Button("Use") { Task { await store.activate(account.id) } } }
            Button("Settings…") { store.settingsTab = .accounts; store.openSettings() }
        }
    }

    private var caption: String? {
        guard account.ready else { return "Not signed in" }
        guard let usage = store.usage[account.id] else { return "Reading…" }
        if usage.stale { return "Sign in again" }
        if let minutes = store.minutesToLimit(account.id), minutes < 300 { return "Limit in ~\(Self.duration(minutes))" }
        let now = Date().timeIntervalSince1970
        if let blocked = ([usage.fiveHour].compactMap({ $0 }) + usage.weeklyLimits).filter({ $0.percent >= Planner.full && ($0.resetsAt ?? 0) > now }).compactMap(\.resetsAt).max() {
            return "Back \(UsageBar.format(blocked))"
        }
        return nil
    }
}

/// Running sessions on Fable, and whether their account still has Fable left. A running
/// session keeps its account and model; `claude -c` restarts it on Side A's current choice.
struct FableSessions: View {
    @Bindable var store: AccountStore
    var body: some View {
        let sessions = store.sessions.filter(\.onFable)
        let now = Date().timeIntervalSince1970
        if store.fableToOpus {
            Label("Fable is spent on every account. New commands use Opus.", systemImage: "arrow.triangle.branch")
                .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Fable sessions (\(sessions.count))").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(sessions) { session in
                    let account = store.config.accounts.first { $0.id == session.accountID }
                    let fable = session.accountID.flatMap { store.usage[$0]?.fable }
                    let spent = fable.map { $0.percent >= Planner.full && ($0.resetsAt ?? 0) > now } ?? false
                    HStack(spacing: 6) {
                        Circle().fill(session.status == "busy" ? Color.green : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                            .help(session.status ?? "")
                        Text(session.name ?? "pid \(session.pid)").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(account?.name ?? "Unknown account").foregroundStyle(.secondary).lineLimit(1)
                        if spent {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("This account's Fable limit is spent. Exit the session and run claude -c to continue on the account Side A picks now.")
                        } else if let fable {
                            Text("fb \(Int(fable.percent.rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.font(.system(size: 11))
                }
                if sessions.contains(where: { session in
                    session.accountID.flatMap { store.usage[$0]?.fable }.map { $0.percent >= Planner.full && ($0.resetsAt ?? 0) > now } ?? false
                }) {
                    Text("Running sessions keep their account. Exit one and run claude -c to continue it on Side A's current pick.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A compact labeled meter; the reset time is in the tooltip.
struct MiniBar: View {
    let label: String
    let window: UsageWindow?
    var width: CGFloat = 46
    var body: some View {
        let percent = min(max(window?.percent ?? 0, 0), 100)
        VStack(alignment: .trailing, spacing: 2) {
            Text(window.map { "\(label) \(Int($0.percent.rounded()))%" } ?? "\(label) –")
                .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            Capsule().fill(.quaternary).frame(width: width, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(percent >= Planner.full ? Color.red : percent >= 75 ? .orange : .accentColor)
                        .frame(width: width * percent / 100, height: 4)
                }
        }
        .help(window?.resetsAt.map { "\(window?.label ?? label) resets \(UsageBar.format($0))" } ?? "")
        .accessibilityElement(children: .combine)
    }
}

extension AccountUsageRow {
    static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m"
    }
}

struct UsageBar: View {
    let window: UsageWindow
    var body: some View {
        let percent = min(max(window.percent, 0), 100)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.label).font(.system(size: 10))
                Spacer()
                Text("\(Int(percent.rounded()))%").font(.system(size: 10).monospacedDigit())
                if let reset = window.resetsAt, reset > Date().timeIntervalSince1970 {
                    Text("· resets \(Self.format(reset))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: percent, total: 100).progressViewStyle(.linear)
                .tint(percent >= Planner.full ? .red : percent >= 75 ? .orange : .accentColor)
        }.accessibilityElement(children: .combine)
    }
    static func format(_ reset: Double) -> String {
        let date = Date(timeIntervalSince1970: reset)
        let seconds = date.timeIntervalSinceNow
        if seconds < 24 * 3600 {
            let hours = Int(seconds) / 3600, minutes = Int(seconds) % 3600 / 60
            return hours > 0 ? "in \(hours)h \(minutes)m" : "in \(minutes)m"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour())
    }
}

enum TokenCount {
    static func short(_ value: Int) -> String {
        let number = Double(value)
        switch number {
        case 1e9...: return String(format: "%.1fB", number / 1e9)
        case 1e6...: return String(format: "%.1fM", number / 1e6)
        case 1e3...: return String(format: "%.0fK", number / 1e3)
        default: return "\(value)"
        }
    }
    static func clock(_ minutes: Int) -> String {
        let value = (minutes % 1440 + 1440) % 1440
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct TourAnchorIf: ViewModifier {
    let step: TourStep
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.tourAnchor(step) } else { content }
    }
}
