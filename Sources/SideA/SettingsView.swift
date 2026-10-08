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
            Section {
                if store.config.accounts.isEmpty {
                    Text("No accounts yet. Add one below.").foregroundStyle(.secondary)
                }
                ForEach(store.config.accounts) { account in
                    AccountSettingsRow(store: store, account: account, removing: $removing)
                }
            } header: {
                HStack {
                    Text("Accounts")
                    Spacer()
                    let signedIn = store.config.accounts.filter(\.ready).count
                    Text("\(signedIn) of \(store.config.accounts.count) signed in")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
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
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.green : Color.secondary)
                .help(isActive ? "Active on this Mac" : "Not active")
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $draft).labelsHidden().textFieldStyle(.plain).font(.body.weight(.medium))
                    .help("Click to rename")
                    .focused($editing).onSubmit(commit)
                    .onChange(of: editing) { _, focused in if !focused { commit() } }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if store.signingIn.contains(account.id) {
                ProgressView().controlSize(.small)
            } else if !account.ready {
                Button("Sign in") { Task { await store.signIn(account.id) } }
            } else if !isActive && account.provider == .claude {
                Button("Use") { Task { await store.activate(account.id) } }
            }
            Toggle("Autopilot", isOn: Binding(get: { account.allowAuto }, set: { store.setAuto(account.id, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help("Autopilot")
            Menu {
                Button("Rename") { editing = true }
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
        let identity = account.ready ? (account.email.isEmpty ? "Connected" : account.email) : "Not signed in"
        return "\(account.provider.title) · \(identity)"
    }
    private func commit() {
        if !store.rename(account.id, draft) { draft = account.name }
    }
}

struct UsageSettings: View {
    @Bindable var store: AccountStore
    var body: some View {
        Form {
            if let report = store.report {
                Section("Last 30 days") {
                    Chart(report.days, id: \.date) { day in
                        BarMark(x: .value("Day", Self.day(day.date), unit: .day), y: .value("Tokens", day.total))
                    }
                    .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { Text(TokenCount.short(value.as(Int.self) ?? 0)) } } }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                    .frame(height: 150)
                }
                Section("Projects") { rows(report.projects.prefix(8).map { (URL(fileURLWithPath: $0.project ?? "").lastPathComponent, $0) }) }
                Section("Models") { rows(report.models.prefix(5).map { ($0.model ?? "", $0) }) }
            } else {
                Section {
                    HStack { ProgressView().controlSize(.small); Text("Reading transcripts…") }
                }
            }
        }
        .formStyle(.grouped)
        .task { await store.refreshReport() }
    }
    static func day(_ text: String?) -> Date {
        (try? Date(text ?? "", strategy: .iso8601.year().month().day())) ?? .distantPast
    }
    private func rows(_ items: [(String, TokenRow)]) -> some View {
        let largest = Double(items.map(\.1.total).max() ?? 1)
        return ForEach(items, id: \.0) { name, row in
            LabeledContent {
                Text(TokenCount.short(row.total)).monospacedDigit()
            } label: {
                Text(name).lineLimit(1).truncationMode(.middle)
                ProgressView(value: Double(row.total), total: largest).progressViewStyle(.linear)
            }
        }
    }
}

struct AutopilotSettings: View {
    @Bindable var store: AccountStore
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.config.smartMode }, set: { _ in store.toggleSmart() })) {
                    Text("Autopilot")
                }
                Toggle(isOn: Binding(get: { store.shellSwitching }, set: { value in Task { await store.setShellSwitching(value) } })) {
                    Text("Switch in Terminal")
                    Text("Adds one line to ~/.zshrc.")
                }
                Toggle(isOn: Binding(get: { store.limitHook }, set: { value in Task { await store.setLimitHook(value) } })) {
                    Text("Switch instantly on a limit")
                    Text("Adds a silent Claude Code hook.")
                }
                Toggle(isOn: $store.fixFableSessions) {
                    Text("Move running sessions before a limit")
                    Text("Between turns, when a session's account reaches 90% of a limit it needs, types into its Ghostty tab to move it to an account with room, or switches a Fable session to Opus.")
                }
                Toggle(isOn: $store.rescueStuckSessions) {
                    Text("Rescue sessions stuck on a spent limit")
                    Text("When a session has been stuck for 15 minutes on an account at 100% of a limit it needs, presses Esc, moves it to an account with room, and types continue. Never the tab you are using.")
                }
                Toggle(isOn: Binding(get: { store.opusFallback }, set: { value in Task { await store.setOpusFallback(value) } })) {
                    Text("Fall back to Opus when a model is unavailable")
                    Text("Sets fallbackModel in Claude Code settings. Claude Code decides when it applies.")
                }
            }
            Section("Schedule") {
                if let schedule = store.schedule {
                    LabeledContent("Your hours", value: "\(TokenCount.clock(schedule.start))–\(TokenCount.clock(schedule.end))")
                    LabeledContent("Warm-up from", value: TokenCount.clock(schedule.start - WorkSchedule.lead))
                } else {
                    Text("Learning your hours").foregroundStyle(.secondary)
                }
            }
            Section("How it decides") {
                LabeledContent("Picks", value: "Quota closest to expiring, by plan size")
                LabeledContent("Fable", value: store.fableToOpus ? "Spent everywhere: new commands use Opus" : "Accounts with Fable left come first")
                LabeledContent("Switches at", value: "\(Int(Planner.full))%")
                LabeledContent("Warm-up", value: "One tiny Haiku message")
            }
            Section {
                LabeledContent("Claude", value: "New terminal commands")
                LabeledContent("Codex", value: "Tracked; switch with codex login")
            }
        }.formStyle(.grouped)
    }
}

struct GeneralSettings: View {
    @Bindable var store: AccountStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("tourSeen") private var tourSeen = false
    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { store.setLaunchAtLogin($0); launchAtLogin = SMAppService.mainApp.status == .enabled }))
                Toggle("Show only in the menu bar", isOn: Binding(get: { store.config.menuBarOnly }, set: { store.setMenuBarOnly($0) }))
                LabeledContent("Guided tour") { Button("Show again") { tourSeen = false } }
            }
            Section("Tools") {
                DependencyStatusView(store: store, provider: .claude)
                DependencyStatusView(store: store, provider: .codex, compact: true)
            }
            Section("Privacy") {
                LabeledContent("Local build", value: "No updates or analytics")
                LabeledContent {
                    Button("Save diagnostics…") { store.saveDiagnostics() }
                } label: { Text("Diagnostics stay on this Mac") }
            }
        }.formStyle(.grouped)
    }
}
