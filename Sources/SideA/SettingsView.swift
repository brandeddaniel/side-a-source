import Charts
import ServiceManagement
import SideACore
import SwiftUI

enum SettingsTab: String { case accounts, usage, autopilot, general }

/// The one place to manage accounts and preferences; the menu bar and player link here.
struct SettingsView: View {
    @Bindable var store: AccountStore
    var body: some View {
        TabView(selection: $store.settingsTab) {
            AccountsSettings(store: store)
                .tabItem { Label("Accounts", systemImage: "person.2") }.tag(SettingsTab.accounts)
            UsageSettings(store: store)
                .tabItem { Label("Usage", systemImage: "chart.bar") }.tag(SettingsTab.usage)
            AutopilotSettings(store: store)
                .tabItem { Label("Autopilot", systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.autopilot)
            GeneralSettings(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
        }
        .frame(width: 520, height: 560)
    }
}

struct AccountsSettings: View {
    @Bindable var store: AccountStore
    @State private var provider: AgentProvider = .claude
    @State private var name = ""
    @State private var email = ""
    @State private var removing: Account?

    var body: some View {
        Form {
            ForEach(AgentProvider.allCases) { provider in
                if let login = store.unknownLogins[provider] {
                    Section {
                        LabeledContent {
                            Button("Add to Side A") { Task { await store.adoptMacLogin(provider) } }
                        } label: {
                            Text("\(provider.title) on this Mac: \(login)")
                        }
                    }
                }
            }
            if store.config.accounts.isEmpty {
                Section { Text("No accounts yet. Add one below.").foregroundStyle(.secondary) }
            }
            ForEach(AgentProvider.allCases) { provider in
                let accounts = store.config.accounts.filter { $0.provider == provider }
                if !accounts.isEmpty {
                    Section {
                        ForEach(accounts) { account in
                            AccountSettingsRow(store: store, account: account, removing: $removing)
                        }
                    } header: {
                        HStack {
                            Text(provider.title)
                            Spacer()
                            Text("\(accounts.filter(\.ready).count) of \(accounts.count) signed in")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            Section("Add account") {
                Picker("Agent", selection: $provider) {
                    ForEach(AgentProvider.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                TextField("Name", text: $name, prompt: Text("Personal"))
                TextField("Email", text: $email, prompt: Text("Optional, prefills sign-in"))
                    .autocorrectionDisabled()
                DependencyStatusView(store: store, provider: provider, compact: true)
                HStack {
                    Spacer()
                    Button("Sign in with \(provider.title)") { add() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !store.isInstalled(provider) || store.python == nil)
                }
            }
            if let error = store.error {
                Section { Text(error).foregroundStyle(.red).onTapGesture { store.error = nil } }
            }
        }
        .formStyle(.grouped)
        .alert("Remove \(removing?.name ?? "account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let removing { store.remove(removing.id) }; removing = nil }
        } message: { Text("Conversations stay.") }
    }

    private func add() {
        guard let id = store.addAccount(name: name, email: email, provider: provider) else { return }
        name = ""; email = ""
        Task { await store.signIn(id) }
    }
}

struct AccountSettingsRow: View {
    @Bindable var store: AccountStore
    let account: Account
    @Binding var removing: Account?
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        let isActive = store.isActive(account)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $draft).labelsHidden().textFieldStyle(.plain).font(.body.weight(.medium))
                    .help("Click to rename")
                    .focused($editing).onSubmit(commit)
                    .onChange(of: editing) { _, focused in if !focused { commit() } }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if account.ready, let usage = store.usage[account.id] {
                MiniBar(label: "5h", window: usage.fiveHour, showsReset: true)
                MiniBar(label: "wk", window: usage.weekly, showsReset: true)
                ForEach(usage.modelLimits, id: \.id) { MiniBar(label: LimitText.name($0), window: $0, showsReset: true) }
            }
            Group {
                if store.signingIn.contains(account.id) || store.waking.contains(account.id) {
                    ProgressView().controlSize(.small)
                } else if !account.ready || (store.issues[account.id] == "signIn" && !isActive) {
                    Button("Sign in") { Task { await store.signIn(account.id) } }
                } else if store.issues[account.id] == "idle" && store.usage[account.id] == nil && account.provider == .claude {
                    Button("Renew") { Task { await store.wake(account.id) } }
                        .help("Has Claude Code renew this login; no model runs and no quota is used")
                } else if isActive {
                    // Which login new commands use; every signed-in account is healthy.
                    Text("In use").font(.caption.weight(.medium)).foregroundStyle(.green)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.green.opacity(0.12), in: .capsule)
                        .help(account.provider == .claude ? "New claude commands use this account" : "Codex on this Mac is signed in to this account")
                } else if account.provider == .claude {
                    Button("Use") { Task { await store.activate(account.id) } }
                }
            }.frame(width: 64, alignment: .trailing)
            Menu {
                Button("Rename") { editing = true }
                Toggle("Include in Autopilot", isOn: Binding(get: { account.allowAuto }, set: { store.setAuto(account.id, $0) }))
                if account.provider == .claude && account.ready {
                    Button("Open Terminal on \(account.name)") { Task { await store.openTerminal(account.id) } }
                }
                Divider()
                Button("Sign in again") { Task { await store.signIn(account.id) } }.disabled(isActive)
                Button("Sign out") { store.signOut(account.id) }.disabled(isActive || !account.ready)
                Divider()
                Button("Remove…", role: .destructive) { removing = account }.disabled(isActive)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Options for \(account.name)")
        }
        .onAppear { draft = account.name }
        .onChange(of: account.name) { _, name in if !editing { draft = name } }
    }

    private var subtitle: String {
        guard account.ready else { return "Not signed in" }
        let identity = account.email.isEmpty ? "Connected" : account.email
        if let issue = store.issueText(account.id) { return "\(identity) · \(issue)" }
        return account.allowAuto ? identity : "\(identity) · Autopilot skips it"
    }
    private func commit() {
        if !store.rename(account.id, draft) { draft = account.name }
    }
}

struct UsageSettings: View {
    @Bindable var store: AccountStore
    var body: some View {
        Form {
            let weekly = store.config.accounts.filter { $0.ready && store.usage[$0.id]?.weekly != nil }
            if !weekly.isEmpty {
                let rhythm = store.report.flatMap { WeekRhythm($0.activity) }
                Section {
                    ForEach(weekly) { PaceRow(account: $0, usage: store.usage[$0.id]!, rhythm: rhythm) }
                } header: {
                    Text("This week")
                } footer: {
                    Text(outlook(weekly, rhythm: rhythm))
                }
            }
            if let report = store.report {
                Section {
                    HStack(spacing: 10) {
                        let days = Dictionary(report.days.map { ($0.date ?? "", $0.total) }, uniquingKeysWith: +)
                        let sum = { (range: ClosedRange<Int>) in range.reduce(0) { $0 + (days[MenuPlayer.day(-$1)] ?? 0) } }
                        // Early in the day, compare with what is usually used by this hour, not a whole day.
                        StatTile(title: "Today", value: sum(0...0), baseline: Double(sum(1...29)) / 29 * Self.shareOfDayByNow(report.activity),
                                 comparison: "usual by \(Date().formatted(.dateTime.hour()))")
                        StatTile(title: "7 days", value: sum(0...6), baseline: Double(sum(7...13)), comparison: "the week before")
                        StatTile(title: "30 days", value: sum(0...29))
                    }
                }
                if let machines = report.machines, machines.count > 1 {
                    Section("Your Macs, last 7 days") {
                        let top = Double(max(machines.map(\.tokens).max() ?? 1, 1))
                        ForEach(machines, id: \.self) { machine in
                            HStack(spacing: 10) {
                                Text(machine.name + (machine.current ? " (this Mac)" : "")).lineLimit(1).frame(width: 170, alignment: .leading)
                                GeometryReader { proxy in
                                    Capsule().fill(machine.current ? Color.accentColor : Color.secondary.opacity(0.35))
                                        .frame(width: max(proxy.size.width * Double(machine.tokens) / top, 4))
                                }.frame(height: 8)
                                Text(TokenCount.short(machine.tokens)).monospacedDigit().frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                }
                let paying = store.config.accounts.filter { ($0.provider == .claude) && (store.usage[$0.id]?.extra.map { $0.enabled || $0.used > 0 } ?? false) }
                if !paying.isEmpty {
                    Section {
                        ForEach(paying) { account in
                            let extra = store.usage[account.id]!.extra!
                            LabeledContent(account.name) {
                                Text(extra.enabled ? extra.summary : "Off · \(extra.summary)").monospacedDigit()
                            }
                        }
                    } header: {
                        Text("Paid usage")
                    } footer: {
                        Text("Past a plan limit, accounts with usage credits on keep working and bill them. Side A warns before that happens and when it does.")
                    }
                }
                Section("Tokens per day") {
                    Chart(report.dayModels ?? report.days, id: \.self) { row in
                        BarMark(x: .value("Day", Self.day(row.date), unit: .day), y: .value("Tokens", row.total))
                            .foregroundStyle(by: .value("Model", ModelName.short(row.model)))
                    }
                    .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { Text(TokenCount.short(value.as(Int.self) ?? 0)) } } }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 170)
                }
                Section("When you work") { HourStrip(activity: report.activity) }
                Section("Projects") { shares(report.projects.prefix(6).map { (URL(fileURLWithPath: $0.project ?? "").lastPathComponent, $0.total) }) }
                // Per agent, so a smaller Codex share is not crowded out by Claude.
                ForEach(AgentProvider.allCases) { provider in
                    let models = report.models.filter { ModelName.provider($0.model) == provider }
                    if !models.isEmpty {
                        Section("\(provider.title) models") { shares(models.prefix(5).map { (ModelName.short($0.model), $0.total) }) }
                    }
                }
            } else {
                Section {
                    HStack { ProgressView().controlSize(.small); Text("Reading transcripts…") }
                }
            }
        }
        .formStyle(.grouped)
        .task { await store.refreshReport() }
    }
    /// The week ahead across Claude accounts, each weighted by plan size and projected to its own reset.
    private func outlook(_ accounts: [Account], rhythm: WeekRhythm?) -> String {
        let now = Date().timeIntervalSince1970
        let claude = accounts.filter { $0.provider == .claude }.compactMap { account -> (Double, Double)? in
            guard let usage = store.usage[account.id], let weekly = usage.weekly else { return nil }
            let projected = WeekForecast(weekly, rhythm: rhythm, now: now)?.projected ?? weekly.percent
            return (min(projected, 100), usage.capacity ?? 1)
        }
        let capacity = claude.reduce(0) { $0 + $1.1 }
        guard capacity > 0 else { return "" }
        let share = claude.reduce(0) { $0 + $1.0 * $1.1 } / capacity
        let basis = rhythm == nil ? "at this week's pace" : "at your usual weekly rhythm"
        let pace = share >= 99.5 ? "on pace to use all of your combined Claude limits before they reset" : "on pace to use \(Int(share))% of your combined Claude limits"
        return "Week ahead: \(pace), \(basis). The tick on each bar is where you would usually be by now."
    }
    /// Share of a typical day's activity that happens before this moment, from past days' hourly counts.
    static func shareOfDayByNow(_ activity: [ActivitySpan]) -> Double {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let hour = now.hour ?? 0, part = Double(now.minute ?? 0) / 60
        let past = activity.filter { $0.date != MenuPlayer.day(0) }
        let total = past.reduce(0.0) { $0 + Double($1.hours.reduce(0, +)) }
        guard total > 0 else { return 1 }
        let done = past.reduce(0.0) { sum, span in
            sum + Double(span.hours.prefix(hour).reduce(0, +)) + (span.hours.indices.contains(hour) ? Double(span.hours[hour]) * part : 0)
        }
        return max(done / total, 0.02)
    }
    static func day(_ text: String?) -> Date {
        (try? Date(text ?? "", strategy: .iso8601.year().month().day())) ?? .distantPast
    }
    private func shares(_ items: [(String, Int)]) -> some View {
        let all = Double(max(items.map(\.1).reduce(0, +), 1))
        return ForEach(items, id: \.0) { name, total in
            LabeledContent {
                Text("\(TokenCount.short(total))  \(Int((Double(total) / all * 100).rounded()))%").monospacedDigit()
            } label: {
                Text(name).lineLimit(1).truncationMode(.middle)
                ProgressView(value: Double(total), total: all).progressViewStyle(.linear)
            }
        }
    }
}

/// Weekly use against how much of the week has passed, with what that pace means.
struct PaceRow: View {
    let account: Account
    let usage: AccountUsage
    let rhythm: WeekRhythm?
    private var window: UsageWindow { usage.weekly! }
    var body: some View {
        let used = min(max(window.percent, 0), 100)
        let forecast = WeekForecast(window, rhythm: rhythm, now: Date().timeIntervalSince1970)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(account.name).font(.body.weight(.medium))
                Text(account.provider.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(verdict(used: used, forecast: forecast)).font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(used >= Planner.limited ? Color.red : .accentColor).frame(width: proxy.size.width * used / 100)
                    // Where usage would be by now if this week follows your usual rhythm.
                    Rectangle().fill(.primary.opacity(0.55)).frame(width: 1.5, height: 10).offset(x: proxy.size.width * (forecast?.expectedNow ?? 0) - 0.75)
                }
            }.frame(height: 6)
            Text(LimitText.resets(usage)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
    private func verdict(used: Double, forecast: WeekForecast?) -> String {
        guard let reset = window.resetsAt else { return "\(Int(used))% used" }
        if used >= Planner.limited { return "Limited, back \(UsageBar.format(reset))" }
        guard let forecast, forecast.projected > used else { return "\(Int(used))% used, resets \(UsageBar.format(reset))" }
        if let out = forecast.runsOut { return "Runs out \(UsageBar.format(out))" }
        return "On pace for \(Int(forecast.projected))% by \(UsageBar.format(reset))"
    }
}

/// Plain-words limit summaries shared by the Usage and Accounts tabs.
enum LimitText {
    /// "Fable" for "Weekly Fable".
    static func name(_ window: UsageWindow) -> String {
        window.label.hasPrefix("Weekly ") ? String(window.label.dropFirst("Weekly ".count)) : window.label
    }
    /// Every window's reset, e.g. "5-hour 24%, resets in 2h 10m · Fable 0%, resets Sat 5 PM".
    static func resets(_ usage: AccountUsage) -> String {
        let now = Date().timeIntervalSince1970
        let live = { (window: UsageWindow?) in window.flatMap { ($0.resetsAt ?? 0) > now ? $0 : nil } }
        var parts: [String] = []
        if let five = live(usage.fiveHour) { parts.append("5-hour \(Int(five.percent))%, resets \(UsageBar.format(five.resetsAt!))") }
        else if usage.fiveHour != nil { parts.append("5-hour idle") }
        let weekly = live(usage.weekly).map { "week resets \(UsageBar.format($0.resetsAt!))" }
        if let weekly { parts.append(weekly) }
        for limit in usage.modelLimits {
            parts.append("\(name(limit)) \(Int(limit.percent))%\(live(limit).map { ", resets \(UsageBar.format($0.resetsAt!))" } ?? "")")
        }
        return parts.joined(separator: " · ")
    }
}

struct StatTile: View {
    let title: String
    let value: Int
    var baseline: Double? = nil
    var comparison = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(TokenCount.short(value)).font(.title2.weight(.semibold)).monospacedDigit()
            if let baseline, baseline > 0 {
                let change = (Double(value) - baseline) / baseline * 100
                Text("\(change >= 0 ? "+" : "")\(Int(change.rounded()))% vs \(comparison)")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("tokens").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Responses per hour of the day over the report period, as a heat strip.
struct HourStrip: View {
    let activity: [ActivitySpan]
    var body: some View {
        let hours = (0..<24).map { hour in activity.reduce(0) { $0 + ($1.hours.indices.contains(hour) ? $1.hours[hour] : 0) } }
        let peak = Double(max(hours.max() ?? 0, 1))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.08 + 0.92 * Double(hours[hour]) / peak))
                        .frame(height: 22).help("\(TokenCount.clock(hour * 60)): \(hours[hour]) responses")
                }
            }
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(TokenCount.clock(hour * 60)).font(.caption2).foregroundStyle(.secondary)
                    if hour != 18 { Spacer() }
                }
                Spacer()
            }
            if let busiest = hours.indices.max(by: { hours[$0] < hours[$1] }), hours[busiest] > 0 {
                Text("Busiest around \(TokenCount.clock(busiest * 60))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

enum ModelName {
    /// Which agent produced a model id: Claude ids name Claude or a Claude family, anything else is Codex.
    static func provider(_ id: String?) -> AgentProvider {
        let id = (id ?? "").lowercased()
        return ["claude", "opus", "sonnet", "haiku", "fable"].contains(where: id.contains) ? .claude : .codex
    }
    /// "claude-opus-5-5-20260101" reads as "Opus 5.5".
    static func short(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Other" }
        if id.hasPrefix("gpt-") {
            // "gpt-6.1-sol" reads as "GPT-6.1 Sol".
            let parts = id.dropFirst(4).split(separator: "-").map(String.init)
            return "GPT-" + (parts.first ?? "") + parts.dropFirst().map { " " + $0.capitalized }.joined()
        }
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init).filter { $0.count < 8 }
        guard let name = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return name.capitalized + (version.isEmpty ? "" : " " + version)
    }
}

struct AutopilotSettings: View {
    @Bindable var store: AccountStore
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.config.smartMode }, set: { _ in store.toggleSmart() })) {
                    Text("Autopilot").font(.headline)
                    Text(status)
                }
                Picker(selection: Binding(get: { store.config.swapAt ?? 95 }, set: { store.setSwapAt($0) })) {
                    ForEach([80.0, 85, 90, 95, 97, 99], id: \.self) { Text("\(Int($0))%").tag($0) }
                } label: {
                    Text("Move at")
                    Text("When an account reaches this much of its 5-hour or weekly limit, Autopilot moves your sessions to another. Lower leaves room for a burst of use; higher uses more of each account.")
                }
                Toggle(isOn: Binding(get: { store.config.followFable != false }, set: { store.setFollowFable($0) })) {
                    Text("Follow Fable")
                    Text("While you use Fable, pick the account with the most Fable left. Fable can use up to half of each weekly limit, and Pro plans bill it as extra usage.")
                }
                Toggle(isOn: Binding(get: { store.opusFallback }, set: { value in Task { await store.setOpusFallback(value) } })) {
                    Text("Fall back to Opus when a model is unavailable")
                    Text("Sets fallbackModel in Claude Code settings. Claude Code decides when it applies.")
                }
            }
            Section {
                UpNext(store: store)
            } header: {
                Text(store.fableMode ? "Up next for Fable" : "Up next")
            } footer: {
                Text("\(store.fableMode ? "Fable" : "weekly") % left ÷ hours until it resets × plan size")
                    .font(.custom("Noteworthy-Bold", size: 13)).foregroundStyle(.secondary)
            }
            Section("Your day") {
                DayTimeline(store: store)
                HStack(spacing: 8) {
                    RuleChip(value: "\(Int(Planner.full))%", text: "leaves an account")
                    RuleChip(value: "<\(Int(Planner.switchTarget))%", text: "moves only to one")
                    RuleChip(value: "1.5×", text: "more urgent to switch")
                }
            }
            Section {
                Toggle(isOn: Binding(get: { store.shellSwitching }, set: { value in Task { await store.setShellSwitching(value) } })) {
                    Text("Switch in Terminal")
                    Text("New claude commands use the account Autopilot picks, and sidea use <name> keeps one terminal on one account. Adds one line to ~/.zshrc.")
                }
                Toggle(isOn: Binding(get: { store.liveLimits }, set: { value in Task { await store.setLiveLimits(value) } })) {
                    Text("Live limits from Claude Code")
                    Text("Each reply updates the numbers, and your own statusline keeps working unchanged.")
                }
                Toggle(isOn: Binding(get: { store.limitHook }, set: { value in Task { await store.setLimitHook(value) } })) {
                    Text("React the moment a limit hits")
                    Text("A silent Claude Code hook that rechecks right away.")
                }
            } footer: {
                Text("Codex accounts are tracked and warmed up; switch Codex itself with codex login.")
            }
        }.formStyle(.grouped)
    }

    private var status: String {
        guard store.config.smartMode else { return "Off. Side A only shows your limits." }
        guard store.shellSwitching else { return "On, but it can't move Terminal to another account until Switch in Terminal is on." }
        let using = store.active.map { "Using \($0.name)\(store.fableMode ? " for Fable" : "")" } ?? "Watching your accounts"
        guard let schedule = store.schedule else { return "\(using). Learning your hours." }
        return "\(using). Warms up idle windows from \(TokenCount.clock(schedule.start - WorkSchedule.lead))."
    }
}

/// Claude accounts ranked the way Autopilot ranks them, with the score that decides.
struct UpNext: View {
    @Bindable var store: AccountStore
    var body: some View {
        let now = Date().timeIntervalSince1970
        let usage = store.planning(store.usage)
        let ranked = store.config.accounts.filter { $0.provider == .claude && $0.ready && $0.allowAuto }
            .compactMap { account in usage[account.id].map { (account, $0, Planner.urgency($0, now: now)) } }
            .sorted { $0.2 > $1.2 }
        let top = max(ranked.first?.2 ?? 1, 0.01)
        let pick = Planner.best(store.config.accounts.filter { $0.provider == .claude }, usage: usage, active: store.activeIDs[.claude], now: now)
        if ranked.isEmpty {
            Text("Add Claude accounts to see how Autopilot ranks them.").foregroundStyle(.secondary)
        }
        ForEach(ranked, id: \.0.id) { account, usage, score in
            HStack(spacing: 10) {
                Text(account.name).font(.body.weight(account.id == pick ? .semibold : .regular)).frame(width: 110, alignment: .leading).lineLimit(1)
                GeometryReader { proxy in
                    Capsule().fill(account.id == pick ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: max(proxy.size.width * score / top, 4))
                }.frame(height: 8)
                Text(score < 0.05 ? "–" : String(format: "%.1f/h", score)).font(.custom("Noteworthy-Bold", size: 13)).monospacedDigit().frame(width: 52, alignment: .trailing)
                Text(account.id == pick ? (store.activeIDs[.claude] == account.id ? "In use" : "Next") : Planner.hasHeadroom(usage, now: now) ? "" : "Limited")
                    .font(.caption.weight(.medium)).foregroundStyle(account.id == pick ? .green : .secondary).frame(width: 48, alignment: .trailing)
            }
        }
    }
}

/// The learned working day on a 24-hour strip: activity, working hours, warm-up start and now.
struct DayTimeline: View {
    @Bindable var store: AccountStore
    var body: some View {
        let activity = store.report?.activity ?? []
        let hours = (0..<24).map { hour in activity.reduce(0) { $0 + ($1.hours.indices.contains(hour) ? $1.hours[hour] : 0) } }
        let peak = Double(max(hours.max() ?? 0, 1))
        let schedule = store.schedule
        let calendar = Calendar.current
        let nowMinute = calendar.component(.hour, from: Date()) * 60 + calendar.component(.minute, from: Date())
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let x = { (minute: Int) in proxy.size.width * CGFloat(((minute % 1440) + 1440) % 1440) / 1440 }
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 1.5) {
                        ForEach(0..<24, id: \.self) { hour in
                            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.08 + 0.7 * Double(hours[hour]) / peak))
                        }
                    }
                    if let schedule {
                        // Working hours, outlined; may wrap past midnight.
                        let start = x(schedule.start), end = x(schedule.end)
                        Group {
                            if end > start {
                                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5).frame(width: end - start).offset(x: start)
                            } else {
                                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5).frame(width: proxy.size.width - start).offset(x: start)
                                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5).frame(width: end)
                            }
                        }
                        Image(systemName: "sunrise.fill").font(.system(size: 11)).foregroundStyle(.orange)
                            .position(x: x(schedule.start - WorkSchedule.lead), y: -9)
                    }
                    Rectangle().fill(.primary).frame(width: 1.5, height: proxy.size.height + 6).offset(x: x(nowMinute), y: -3)
                }
            }
            .frame(height: 26).padding(.top, 14)
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(TokenCount.clock(hour * 60)).font(.caption2).foregroundStyle(.secondary)
                    if hour != 18 { Spacer() }
                }
                Spacer()
            }
            Text(schedule.map { "You usually work \(TokenCount.clock($0.start))–\(TokenCount.clock($0.end)). Idle 5-hour windows start from \(TokenCount.clock($0.start - WorkSchedule.lead)), so they reset sooner." }
                 ?? "Learning your hours from a week of activity.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RuleChip: View {
    let value: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.custom("Noteworthy-Bold", size: 17))
            Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 9))
    }
}

struct GeneralSettings: View {
    @Bindable var store: AccountStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("tourSeen") private var tourSeen = false
    @AppStorage("playerEnabled") private var playerEnabled = false
    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { store.setLaunchAtLogin($0); launchAtLogin = SMAppService.mainApp.status == .enabled }))
                Toggle("Show only in the menu bar", isOn: Binding(get: { store.config.menuBarOnly }, set: { store.setMenuBarOnly($0) }))
                LabeledContent("Guided tour") { Button("Show again") { tourSeen = false } }
                Toggle(isOn: $playerEnabled) {
                    Text("3D player")
                    Text("A pocket disc player for your accounts, from the menu.")
                }
            }
            Section("Tools") {
                DependencyStatusView(store: store, provider: .claude)
                DependencyStatusView(store: store, provider: .codex, compact: true)
            }
            Section("Privacy") {
                LabeledContent("Local build", value: "No updates, analytics or sync")
                LabeledContent {
                    Button("Save diagnostics…") { store.saveDiagnostics() }
                } label: { Text("Diagnostics stay on this Mac") }
            }
        }.formStyle(.grouped)
    }
}
