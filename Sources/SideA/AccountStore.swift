import AppKit
import Foundation
import Observation
import SideACore
import ServiceManagement
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

struct AuthStatus: Decodable, Sendable {
    let loggedIn: Bool
    let email: String
    let authMethod: String
}

struct BridgeFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

@MainActor @Observable
final class AccountStore {
    var config = Configuration() { didSet { Planner.full = config.swapAt ?? 95 } }
    var dependencies = DependencyReport()
    var checkingDependencies = false
    var error: String?
    /// Accounts that own the Mac-wide Claude and Codex logins, when they are in the library.
    var activeIDs: [AgentProvider: String] = [:]
    /// Mac-wide login emails that are not in the library yet.
    var unknownLogins: [AgentProvider: String] = [:]
    var report: UsageReport?
    /// Model of the newest Claude Code response in the last half hour.
    var claudeModel: String?
    var limitHook = false
    /// The `claude` shell function that makes new commands use the chosen account.
    var shellSwitching = false
    var liveLimits = false
    /// When a Claude Code session last reported each account's limits.
    private var liveAt: [String: Double] = [:]
    private var liveSeen = Date.distantPast
    /// Keychain slots running claude processes read, with the account whose login is in each;
    /// nil when processes can't be listed.
    private var busyLogins: [String: String]?
    @ObservationIgnored private var reportAt = Date.distantPast
    @ObservationIgnored private var limitMarkerDate: Date?
    var usage: [String: AccountUsage] = [:]
    var signingIn: Set<String> = []
    /// Why an account's numbers are not current: "idle", "signIn" or "offline". Absent when they are.
    var issues: [String: String] = [:]
    var waking: Set<String> = []
    @ObservationIgnored private var primedAt: [String: Date] = [:]
    @ObservationIgnored private var usageAt: [String: Date] = [:]
    @ObservationIgnored private var backoffUntil: [String: Date] = [:]
    /// Accounts whose latest read failed for a reason other than being idle. They keep their
    /// last bars on screen but are left out of Autopilot until a read succeeds.
    @ObservationIgnored private var failing: Set<String> = []
    @ObservationIgnored private var reading: Set<String> = []
    /// Bumped by every switch, so an "active" answer that started earlier cannot overwrite it.
    @ObservationIgnored private var selectionGeneration = 0
    /// Recent (time, 5-hour percent) samples per account for the burn-rate forecast.
    @ObservationIgnored private var samples: [String: [(Double, Double)]] = [:]
    @ObservationIgnored private var exhaustedNotified = false
    /// Per account: the window reset already warned about, so each limit warns once.
    @ObservationIgnored private var paidWarned: [String: Double] = [:]
    @ObservationIgnored private var loginStamps: [String: Double] = [:]
    @ObservationIgnored private var endWarned: [String: Double] = [:]
    @ObservationIgnored private var renewedAt: [String: Date] = [:]
    /// When each Claude sign-in stops renewing; about a month after signing in.
    var loginEnds: [String: Double] = [:]
    /// When each account was last read successfully, for marking old readings.
    var readAt: [String: Date] = [:]
    var lidOpen = false
    /// The player only stays open when asked for; macOS would otherwise restore it at launch.
    var playerRequested = false
    var settingsTab: SettingsTab = .accounts
    var held = false
    var busy = false
    var startupError = false
    let root: URL
    let isDemo: Bool
    private var pollTask: Task<Void, Never>?

    init() {
        isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        root = isDemo
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SideA-preview-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SideA")
        if isDemo {
            // Fictional accounts for previews and website screenshots.
            config.accounts = [Account(name: "Personal", email: "you@example.com", ready: true, allowAuto: true),
                               Account(name: "Studio", email: "studio@example.com", ready: true, allowAuto: true),
                               Account(name: "Weekend", email: "weekend@example.com", ready: true, allowAuto: true),
                               Account(name: "Work", email: "work@example.com", ready: true, allowAuto: true, provider: .codex),
                               Account(name: "Side project", email: "side@example.com", ready: true, allowAuto: true, provider: .codex)]
            config.selectedID = config.accounts.first?.id
            config.smartMode = true
            shellSwitching = true
            activeIDs = [.claude: config.accounts[0].id, .codex: config.accounts[3].id]
            let now = Date().timeIntervalSince1970
            func window(_ id: String, _ percent: Double, _ reset: Double) -> UsageWindow {
                UsageWindow(id: id, label: id == "five_hour" ? "5-hour" : "Weekly", percent: percent, resetsAt: now + reset)
            }
            let ids = config.accounts.map(\.id)
            usage = [ids[0]: AccountUsage(windows: [window("five_hour", 62, 7_400), window("seven_day", 41, 260_000)], capacity: 20),
                     ids[1]: AccountUsage(windows: [window("five_hour", 8, 15_800), window("seven_day", 18, 520_000)], capacity: 5),
                     ids[2]: AccountUsage(windows: [window("five_hour", 100, 2_900), window("seven_day", 100, 90_000)], capacity: 1),
                     ids[3]: AccountUsage(windows: [window("five_hour", 34, 9_600), window("seven_day", 57, 330_000)]),
                     ids[4]: AccountUsage(windows: [window("seven_day", 12, 480_000)])]
            let calendar = Calendar.current
            let days: [TokenRow] = (0..<30).map { offset in
                let date = calendar.date(byAdding: .day, value: offset - 29, to: Date())!
                let weekday = calendar.component(.weekday, from: date)
                let base = weekday == 1 || weekday == 7 ? 0.35 : 1.0
                let total = Int((900 + Double((offset * 37) % 11) * 140) * base) * 1_000_000
                return TokenRow(date: ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate]),
                                input: total / 200, output: total / 60, cacheWrite: total / 12, cacheRead: total - total / 200 - total / 60 - total / 12)
            }
            func row(_ name: String, project: Bool, _ total: Int) -> TokenRow {
                TokenRow(project: project ? name : nil, model: project ? nil : name, input: total / 200, output: total / 60, cacheWrite: total / 12, cacheRead: total - total / 200 - total / 60 - total / 12)
            }
            report = UsageReport(days: days,
                                 projects: [row("/Users/you/code/web-app", project: true, 9_400_000_000), row("/Users/you/code/api", project: true, 6_100_000_000),
                                            row("/Users/you/code/mobile", project: true, 3_800_000_000), row("/Users/you/code/docs", project: true, 900_000_000)],
                                 models: [row("claude-opus-5-5", project: false, 14_200_000_000), row("claude-sonnet-5-5", project: false, 5_300_000_000),
                                          row("claude-haiku-4-5", project: false, 700_000_000)],
                                 activity: (0..<14).map { ActivitySpan(date: "d\($0)", hours: (0..<24).map { (9...18).contains($0) ? 40 : 1 }) },
                                 dayModels: days.flatMap { day in
                                     [("claude-opus-5-5", 0.7), ("claude-sonnet-5-5", 0.26), ("claude-haiku-4-5", 0.04)].map { model, share in
                                         var split = day; split.model = model
                                         split.input = Int(Double(day.input) * share); split.output = Int(Double(day.output) * share)
                                         split.cacheWrite = Int(Double(day.cacheWrite) * share); split.cacheRead = Int(Double(day.cacheRead) * share)
                                         return split
                                     }
                                 })
        } else if FileManager.default.fileExists(atPath: configURL.path) {
            do { config = try PrivateFile.read(Configuration.self, from: configURL).validated() }
            catch { self.error = error.localizedDescription; startupError = true }
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            // First launch: Autopilot only helps while running, so start with the Mac.
            try? SMAppService.mainApp.register()
        }
        if !isDemo, let cache = try? PrivateFile.read(UsageCache.self, from: usageCacheURL) {
            // Show the last numbers at once and keep each account on its normal polling schedule.
            usage = cache.usage; usageAt = cache.at
            backoffUntil = cache.backoff ?? [:]; primedAt = cache.primed ?? [:]; failing = Set(cache.failing ?? []).intersection(config.accounts.map(\.id))
            issues = (cache.issues ?? [:]).filter { id, _ in config.accounts.contains { $0.id == id } }
            // Caches from before readAt existed only know when a read was last attempted.
            readAt = cache.readAt ?? cache.at
            activeIDs = (cache.active ?? [:]).reduce(into: [:]) { ids, item in AgentProvider(rawValue: item.key).map { ids[$0] = item.value } }
        }
        if !isDemo {
            report = try? PrivateFile.read(UsageReport.self, from: reportURL)
            // Files from the 0.4 session runner; nothing reads them any more.
            let runtime = root.appendingPathComponent("runtime")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: runtime.path)) ?? []
            where ["active.json", "session.lock", "keychain.lock", "claude-account"].contains(name) || name.hasSuffix(".hooks.json") {
                try? FileManager.default.removeItem(at: runtime.appendingPathComponent(name))
            }
        }
        // The lid stays open while Settings is on screen, as the old account panel did.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard window?.identifier?.rawValue.contains("Settings") == true else { return }
                self?.lidOpen = false
            }
        }
        pollTask = Task { [weak self] in
            // Every bridge call needs Python, so nothing runs until the tool scan has found it.
            await self?.refreshDependencies()
            await self?.loadIntegrations()
            while !Task.isCancelled {
                await self?.tick()
                // Wake early when the rate-limit hook fires, otherwise once a minute.
                for _ in 0..<30 {
                    if self?.limitHit() == true || self?.liveChanged() == true { break }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func loadIntegrations() async {
        struct State: Decodable { let installed: Bool }
        async let hook = try? bridgeOutput(["hook", "status"])
        async let shell = try? bridgeOutput(["shell", "status"])
        async let live = try? bridgeOutput(["live", config.liveLimits == false ? "status" : "on"])
        if let data = await hook { limitHook = (try? JSONDecoder().decode(State.self, from: data))?.installed ?? false }
        if let data = await shell { shellSwitching = (try? JSONDecoder().decode(State.self, from: data))?.installed ?? false }
        if let data = await live { liveLimits = (try? JSONDecoder().decode(State.self, from: data))?.installed ?? false }
        if let data = try? await bridgeOutput(["fable", "status"]) { fableToOpus = (try? JSONDecoder().decode(State.self, from: data))?.installed ?? false }
        if let data = try? await bridgeOutput(["fallback", "status"]) { opusFallback = (try? JSONDecoder().decode(State.self, from: data))?.installed ?? false }
    }
    /// Reads accounts side by side; each Codex read starts its own app-server, so serial reads add up.
    /// Three at a time: a burst of reads (every account at launch) gets the usage endpoint to
    /// answer 429 for nearly all of them.
    private func refresh(_ ids: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = ids[...]
            for _ in 0..<3 { if let id = pending.popFirst() { group.addTask { await self.refreshUsage(id) } } }
            while await group.next() != nil {
                if let id = pending.popFirst() { group.addTask { await self.refreshUsage(id) } }
            }
        }
    }
    var configURL: URL { root.appendingPathComponent("config.json") }
    var selected: Account? { config.selected }
    /// The Mac-wide Claude account (shown in the menu bar title).
    var active: Account? { config.accounts.first { $0.id == activeIDs[.claude] } }
    func isActive(_ account: Account) -> Bool { activeIDs[account.provider] == account.id }
    var schedule: WorkSchedule? { report.flatMap { WorkSchedule($0.activity) } }
    var trackNumber: Int { (config.accounts.firstIndex { $0.id == config.selectedID } ?? 0) + 1 }
    var python: String? { dependencies.python.path }
    func isInstalled(_ provider: AgentProvider) -> Bool { dependencies.agent(provider).state == .ready }
    func refreshDependencies() async {
        guard !checkingDependencies else { return }
        checkingDependencies = true
        dependencies = await DependencyCheck.scan()
        checkingDependencies = false
    }
    var bridgeURL: URL? { AppResources.bundle.url(forResource: "sidea_bridge", withExtension: "py") }

    @discardableResult func persist() -> Bool {
        guard !startupError else { return false }
        guard !isDemo else { return true }
        do { try PrivateFile.write(try config.validated(), to: configURL); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func select(_ id: String) {
        guard !held else { return }
        config.selectedID = id; persist()
    }
    func step(_ offset: Int) {
        guard !held else { return }
        config.step(offset); persist()
    }
    func toggleSmart() {
        config.smartMode.toggle(); persist()
        // Autopilot moves Terminal's account, which needs the shell line; turning it on is the consent.
        if config.smartMode && !shellSwitching && !isDemo { Task { await setShellSwitching(true) } }
    }
    /// Opens a Terminal window that stays on this account, whatever Autopilot does elsewhere.
    func openTerminal(_ id: String) async {
        guard let account = config.accounts.first(where: { $0.id == id }), !isDemo else { return }
        if !shellSwitching { await setShellSwitching(true) }
        await refreshActive()  // writes the per-account pins
        let pin = Self.pinName(account.name)
        let url = root.appendingPathComponent("runtime/open-\(pin).command")
        let script = "#!/bin/zsh\nexport SIDE_A_PIN=\(Shell.quote(pin))\nclear\necho \(Shell.quote("This terminal stays on \(account.name). Run claude as usual; sidea auto follows Side A again."))\nexec zsh -l\n"
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch { self.error = "Terminal could not be opened: \(error.localizedDescription)" }
    }
    /// Matches the bridge's pin_name: lowercased, anything else becomes a dash.
    static func pinName(_ name: String) -> String {
        let slug = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "account" : slug
    }
    func setAuto(_ id: String, _ allowed: Bool) {
        guard let index = config.accounts.firstIndex(where: { $0.id == id }) else { return }
        config.accounts[index].allowAuto = allowed; persist()
    }
    /// Opens Settings on the Accounts tab; the player's lid opens while it is shown.
    func openLibrary() {
        settingsTab = .accounts
        lidOpen = true
        Task { await refreshDependencies() }
        openSettings()
    }
    /// SwiftUI's openSettings action, registered by whichever scene appears first.
    @ObservationIgnored var showSettings: (() -> Void)?
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        showSettings?()
    }
    @discardableResult func rename(_ id: String, _ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = config.accounts.firstIndex(where: { $0.id == id }) else { return false }
        guard config.accounts[index].name != name else { return true }
        let previous = config.accounts[index].name
        config.accounts[index].name = name
        guard persist() else { config.accounts[index].name = previous; return false }
        return true
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do { enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { self.error = "Open at login could not be changed: \(error.localizedDescription)" }
    }
    func addAccount(name: String, email: String, provider: AgentProvider = .claude) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let account = Account(name: name, email: email.trimmingCharacters(in: .whitespacesAndNewlines), allowAuto: true, provider: provider)
        config.accounts.append(account)
        if config.selectedID == nil { config.selectedID = account.id }
        guard persist() else { config.accounts.removeAll { $0.id == account.id }; return nil }
        return account.id
    }
    /// Runs the CLI's own browser sign-in in the background and verifies when it returns.
    @discardableResult func signIn(_ id: String) async -> Bool {
        guard !isDemo else { return await verify(id) }
        guard let account = config.accounts.first(where: { $0.id == id }), !isActive(account) else {
            error = "Switch to another account before signing in to this one again."; return false
        }
        guard !signingIn.contains(id) else { return false }
        signingIn.insert(id); defer { signingIn.remove(id) }
        do { _ = try await bridgeOutput(["login", id], timeout: 600) }
        catch { self.error = "Sign-in did not finish. Try again."; return false }
        let ok = await verify(id)
        if ok { await refreshUsage(id) }
        return ok
    }
    func signOut(_ id: String) {
        guard !config.accounts.contains(where: { $0.id == id && isActive($0) }) else { error = "Switch to another account before signing out of this one."; return }
        Task { _ = try? await bridgeOutput(["logout", id]) }
        if let index = config.accounts.firstIndex(where: { $0.id == id }) {
            config.accounts[index].ready = false; persist()
        }
        usage[id] = nil
    }
    func remove(_ id: String) {
        guard !config.accounts.contains(where: { $0.id == id && isActive($0) }) else { error = "Switch to another account before removing this one."; return }
        // Removal is metadata-only. Claude owns its Keychain item; sign out first
        // if credentials should be revoked. Keep conversation files intact.
        config.accounts.removeAll { $0.id == id }
        if config.selectedID == id { config.selectedID = config.accounts.first?.id }
        persist()
    }
    func verify(_ id: String, reportError: Bool = true) async -> Bool {
        if isDemo {
            guard let index = config.accounts.firstIndex(where: { $0.id == id }) else { return false }
            config.accounts[index].ready = true
            if config.accounts[index].email.isEmpty { config.accounts[index].email = "you@example.com" }
            return true
        }
        guard !busy, config.accounts.contains(where: { $0.id == id }) else { return false }
        busy = true
        defer { busy = false }
        do {
            let result = try await bridgeOutput(["status", id])
            let status = try JSONDecoder().decode(AuthStatus.self, from: result)
            guard let index = config.accounts.firstIndex(where: { $0.id == id }) else { return false }
            guard status.loggedIn else {
                config.accounts[index].ready = false; persist()
                throw BridgeFailure(message: "Finish signing in, then return to Side A.")
            }
            guard !config.accounts.contains(where: { $0.id != id && $0.provider == config.accounts[index].provider && $0.ready && $0.email.caseInsensitiveCompare(status.email) == .orderedSame }) else {
                config.accounts[index].ready = false; persist()
                throw BridgeFailure(message: "That account is already in your library. Sign in with a different email in the browser.")
            }
            config.accounts[index].email = status.email
            config.accounts[index].ready = true
            let saved = persist()
            return saved
        } catch {
            // A timeout or unavailable CLI does not prove a previously verified login expired.
            if reportError { self.error = error.localizedDescription }
            return false
        }
    }
    func saveDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Save diagnostic summary"
        panel.message = "App and tool versions, and session state. No accounts, paths, conversations, or credentials."
        panel.nameFieldStringValue = "Side-A-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let summary = DiagnosticSummary(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture,
            python: dependencies.python, claude: dependencies.claude, codex: dependencies.codex,
            libraryReadable: !startupError)
        do { try PrivateFile.write(summary, to: url) }
        catch { self.error = "The diagnostic summary could not be saved. Choose another location." }
    }
    /// Makes the selected account the Mac-wide login (PLAY on the player).
    func play() {
        guard !held, let account = selected else { return }
        guard account.ready else { openLibrary(); return }
        Task { await activate(account.id) }
    }
    func activate(_ id: String) async {
        guard let account = config.accounts.first(where: { $0.id == id }), !isActive(account) else { return }
        guard !isDemo else { activeIDs[account.provider] = id; return }
        // Use means "run claude as this account", which only the shell line makes true.
        if account.provider == .claude && !shellSwitching { await setShellSwitching(true) }
        do {
            _ = try await bridgeOutput(["activate", id])
            selectionGeneration += 1
            activeIDs[account.provider] = id
        } catch { self.error = error.localizedDescription }
    }
    /// Trades the login in `slot` with `to`'s, so every session reading it continues as `to`; see bridge swap().
    private func swap(_ slot: String, _ to: String, share: Bool = false) async -> Bool {
        guard (try? await bridgeOutput(["swap", slot, to] + (share ? ["--share"] : []), timeout: 90)) != nil else { return false }
        selectionGeneration += 1
        _ = await refreshActive()
        return true
    }
    /// When `id` has spent its Fable share and no unused account has Fable room: an account with
    /// Fable room whose sessions all run other models, provided `id` still has room for them.
    /// Trading with it keeps the Fable sessions going and moves only sessions that never need Fable.
    private func fableShare(_ id: String, slots: [String: String], current: String?, now: Double) -> String? {
        let mine = sessions.filter { $0.accountID == id }
        guard mine.contains(where: \.onFable), let account = config.accounts.first(where: { $0.id == id }),
              Planner.best([account], usage: plannable, active: nil, now: now, ignoringModelLimits: true) == id else { return nil }
        let candidates = config.accounts.filter { other in
            let theirs = sessions.filter { $0.accountID == other.id }
            // New commands follow the selector, so its account never trades this way.
            return other.provider == .claude && other.id != id && other.id != current && !signingIn.contains(other.id)
                && !failing.contains(other.id) && slots.values.contains(other.id)
                && !theirs.isEmpty && theirs.allSatisfy { $0.model != nil && !$0.onFable }
                && slots.values.filter({ $0 == other.id }).count == 1
        }
        return Planner.best(candidates, usage: plannable, active: nil, now: now)
    }
    /// Keeps the Mac's existing login as a library account so switching never loses it.
    func adoptMacLogin(_ provider: AgentProvider) async {
        guard let email = unknownLogins[provider], !isDemo else { return }
        let account = Account(name: email.components(separatedBy: "@").first ?? "This Mac", email: email, allowAuto: true, provider: provider)
        config.accounts.append(account)
        guard persist() else { config.accounts.removeAll { $0.id == account.id }; return }
        do {
            _ = try await bridgeOutput(["adopt", account.id])
            if await verify(account.id) { unknownLogins[provider] = nil; activeIDs[provider] = account.id; await refreshUsage(account.id) }
        } catch {
            self.error = error.localizedDescription
            config.accounts.removeAll { $0.id == account.id }; persist()
        }
    }
    /// Reads one account's limits. A failed read keeps the last known numbers; only an
    /// expired login (stale) takes an account out of Autopilot, so a hiccup never causes a switch.
    func refreshUsage(_ id: String) async {
        guard Date() >= (backoffUntil[id] ?? .distantPast), !reading.contains(id) else { return }
        reading.insert(id); defer { reading.remove(id) }
        let started = Date()
        usageAt[id] = started
        do {
            var value = try JSONDecoder().decode(AccountUsage.self, from: try await bridgeOutput(["usage", id]))
            // A session reply that landed while this read was in flight is newer than its answer.
            if (liveAt[id] ?? 0) > started.timeIntervalSince1970, let current = usage[id] {
                for window in current.windows where ["five_hour", "seven_day"].contains(window.id) {
                    if let index = value.windows.firstIndex(where: { $0.id == window.id }) { value.windows[index] = window }
                }
            }
            warnAboutPaidUsage(id, before: usage[id], after: value)
            usage[id] = value
            readAt[id] = max(started, readAt[id] ?? started)
            failing.remove(id)
            issues[id] = nil
            sample(id, value.fiveHour, at: started.timeIntervalSince1970)
        } catch {
            let message = error.localizedDescription
            // Idle: nobody has used the login since it expired, so the last reading still holds.
            if message.contains("idle") {
                backoffUntil[id] = Date().addingTimeInterval(1800)
                issues[id] = "idle"
                // Free: Claude Code renews the login without running a model, then it is read again.
                if Date().timeIntervalSince(renewedAt[id] ?? .distantPast) > 600 { Task { await renew(id) } }
            } else {
                // The usage endpoint rate-limits frequent reads; back off rather than retry.
                let signIn = message.contains("Sign in")
                // A rate limit is not a fault: the last reading stays, marked with its time once it ages.
                issues[id] = signIn ? "signIn" : message.contains("confirm whose login") ? "verify" : message.contains("429") ? nil : "offline"
                backoffUntil[id] = Date().addingTimeInterval(signIn ? 1800 : message.contains("429") ? 600 : 300)
                if !message.contains("429") { failing.insert(id) }
                if signIn { usage[id]?.stale = true }
            }
        }
        saveUsageCache()
    }
    private func sample(_ id: String, _ five: UsageWindow?, at now: Double) {
        guard let five else { return }
        // A drop means the window reset; the old pace no longer applies.
        if let last = samples[id]?.last, five.percent < last.1 { samples[id] = [] }
        samples[id, default: []].append((now, five.percent))
        samples[id]?.removeAll { now - $0.0 > 1200 }
    }
    /// Refreshes what is due (menu open). The refresh button passes `force` but still
    /// respects backoff and never re-reads an account checked in the last minute.
    func refreshAll(force: Bool = false) async {
        await refreshActive()
        Task { await refreshReport() }
        Task { await refreshSessions() }
        await refresh(config.accounts.filter { $0.ready
            && (dueForRead($0) || (force && Date().timeIntervalSince(usageAt[$0.id] ?? .distantPast) > 60)) }.map(\.id))
    }
    /// Paid usage starts silently once a plan limit is hit. Warns when this month's spend grows,
    /// and once per limit when the account in use nears a limit with nowhere to move.
    private func warnAboutPaidUsage(_ id: String, before: AccountUsage?, after: AccountUsage) {
        guard let extra = after.extra, let name = config.accounts.first(where: { $0.id == id })?.name else { return }
        if let previous = before?.extra?.used, extra.used > previous + 0.004 {
            notify("\(name) is using paid credits", "\(extra.money(extra.used - previous)) more since the last check; \(extra.summary).")
            return
        }
        guard extra.enabled, activeIDs[.claude] == id else { return }
        let now = Date().timeIntervalSince1970
        guard let near = [after.fiveHour, after.weekly].compactMap({ $0 }).first(where: { $0.percent >= 90 && ($0.resetsAt ?? 0) > now }),
              paidWarned[id] != near.resetsAt else { return }
        let others = config.accounts.filter { $0.provider == .claude && $0.id != id }
        guard Planner.best(others, usage: planning(usage), active: nil, now: now) == nil else { return }
        paidWarned[id] = near.resetsAt
        notify("\(name) will start charging soon", "It is at \(Int(near.percent))% of its \(near.label.lowercased()) limit and no other account has room. Past the limit, Claude bills paid credits (\(extra.summary)).")
    }
    /// Why an account shows no current numbers, in words; nil when its reading is current.
    func issueText(_ id: String) -> String? {
        switch issues[id] {
        case "signIn": "Sign in again"
        case "idle": usage[id] == nil ? "Renewing its login…"
            : "As of \((readAt[id] ?? Date()).formatted(date: .omitted, time: .shortened)) · renewing"
        case nil where (loginEnds[id] ?? .infinity) - Date().timeIntervalSince1970 < 3 * 86_400:
            "Sign-in ends \(UsageBar.format(loginEnds[id]!)) · sign in again"
        case "verify": "Checking whose login this is · retrying \(UsageBar.format((backoffUntil[id] ?? Date()).timeIntervalSince1970))"
        case nil where usage[id] != nil && Date().timeIntervalSince(readAt[id] ?? .distantPast) > 900:
            "As of \((readAt[id] ?? Date()).formatted(date: .omitted, time: .shortened))"
        case "offline": "Couldn't connect · retrying \(UsageBar.format((backoffUntil[id] ?? Date()).timeIntervalSince1970))"
        default: nil
        }
    }
    /// Has Claude Code renew an idle login (no model runs, no quota), then reads it again.
    func renew(_ id: String) async {
        guard !waking.contains(id) else { return }
        waking.insert(id); defer { waking.remove(id) }
        renewedAt[id] = Date()
        do {
            _ = try await bridgeOutput(["renew", id], timeout: 120)
            backoffUntil[id] = nil
            await refreshUsage(id)
        } catch {
            let message = error.localizedDescription
            if message.contains("Sign in") { issues[id] = "signIn"; usage[id]?.stale = true; saveUsageCache() }
        }
    }
    func wake(_ id: String) async {
        renewedAt[id] = nil
        await renew(id)
        if issues[id] == "idle" { self.error = "\(config.accounts.first { $0.id == id }?.name ?? "This account") could not be renewed. Sign in to it again." }
    }
    /// What Autopilot may act on: accounts with a trustworthy latest reading.
    private var plannable: [String: AccountUsage] { usage.filter { !failing.contains($0.key) } }
    /// True while Claude Code is running Fable and Autopilot follows it.
    var fableMode: Bool { config.followFable != false && claudeModel?.localizedCaseInsensitiveContains("fable") == true }
    /// Usage as Autopilot ranks Claude accounts: through the Fable cap while Fable is in use.
    func planning(_ values: [String: AccountUsage]) -> [String: AccountUsage] { fableMode ? values.compactMapValues(\.forFable) : values }
    func setFollowFable(_ value: Bool) { config.followFable = value; persist() }
    func setSwapAt(_ value: Double) { config.swapAt = value; persist() }
    private struct UsageCache: Codable {
        var usage: [String: AccountUsage]; var at: [String: Date]
        var backoff: [String: Date]?; var primed: [String: Date]?
        var active: [String: String]?; var failing: [String]?; var issues: [String: String]?; var readAt: [String: Date]?
    }
    private var reportURL: URL { root.appendingPathComponent("runtime/report.json") }
    private var usageCacheURL: URL { root.appendingPathComponent("runtime/usage-cache.json") }
    private func saveUsageCache() {
        try? PrivateFile.write(UsageCache(usage: usage, at: usageAt, backoff: backoffUntil, primed: primedAt,
                                          active: Dictionary(uniqueKeysWithValues: activeIDs.map { ($0.key.rawValue, $0.value) }),
                                          failing: Array(failing), issues: issues, readAt: readAt),
                               to: usageCacheURL)
    }
    /// Active accounts change fastest. An idle account at a limit cannot change until that
    /// limit resets, so it is not read again before then.
    private func dueForRead(_ account: Account) -> Bool {
        let now = Date().timeIntervalSince1970
        if !isActive(account), let value = usage[account.id], !value.stale,
           let reset = [value.fiveHour, value.weekly].compactMap({ $0 }).filter({ $0.percent >= Planner.limited }).compactMap(\.resetsAt).max(),
           reset > now {
            return false
        }
        // The usage endpoint rate-limits a login read every minute or two; three minutes stays clear.
        // While sessions report live limits, the endpoint is only needed for what they can't see
        // (Fable, paid usage, use on other devices).
        let live = now - (liveAt[account.id] ?? 0) < 600
        let interval: TimeInterval = live ? 900 : isActive(account) ? (nearLimit(account.id) ? 90 : 180) : 600
        return Date().timeIntervalSince(usageAt[account.id] ?? .distantPast) >= interval - 1
    }
    /// Minutes until the account's 5-hour limit at its recent pace.
    func minutesToLimit(_ id: String) -> Double? { Planner.minutesToLimit(samples[id] ?? [], now: Date().timeIntervalSince1970) }
    private func nearLimit(_ id: String) -> Bool {
        (usage[id]?.fiveHour?.percent ?? 0) >= 85 || (minutesToLimit(id) ?? .infinity) < 15
    }
    private func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        Self.post(title, body)
    }
    /// Nonisolated: the authorization callback runs on a background queue, and a closure formed in
    /// this main-actor class would trap there under Swift 6's isolation checks (it crash-looped the app).
    private nonisolated static func post(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
    @discardableResult private func refreshActive() async -> Bool {
        let generation = selectionGeneration
        struct Active: Decodable { let accountID: String?; let email: String; let codexAccountID: String?; let codexEmail: String; let claudeModel: String?; let logins: [String: Double]?; let loginEnds: [String: Double]?; let live: [String: Live]?; let busy: [Busy]? }
        struct Busy: Decodable { let slot: String; let account: String? }
        struct Live: Decodable { let at: Double; let windows: [UsageWindow] }
        guard let data = try? await bridgeOutput(["active"]), let value = try? JSONDecoder().decode(Active.self, from: data) else { return false }
        guard generation == selectionGeneration else { return false }
        activeIDs = [.claude: value.accountID, .codex: value.codexAccountID].compactMapValues { $0 }
        claudeModel = value.claudeModel
        // A login that changed (signed in again, or refreshed by Claude Code) is read now:
        // the back-off and any old reading belonged to the previous login.
        for (id, stamp) in value.logins ?? [:] {
            if let seen = loginStamps[id], seen != stamp {
                backoffUntil[id] = nil; usageAt[id] = nil; issues[id] = nil; failing.remove(id)
            }
            loginStamps[id] = stamp
        }
        loginEnds = (value.loginEnds ?? [:]).mapValues { $0 / 1000 }
        busyLogins = value.busy.map { Dictionary($0.compactMap { busy in busy.account.map { (busy.slot, $0) } }, uniquingKeysWith: { a, _ in a }) }
        // Each reply's limits, as a session saw them: newer than the last endpoint read wins.
        var changed = false
        for (id, live) in value.live ?? [:] { liveAt[id] = live.at }
        for (id, live) in value.live ?? [:] where live.at > (readAt[id]?.timeIntervalSince1970 ?? 0) {
            // Each account's week resets at its own time. A reply that began before a trade reports
            // the previous login's limits; its weekly reset gives it away, so it is not credited here.
            if Planner.belongsElsewhere(live.windows, known: usage[id], now: Date().timeIntervalSince1970) { continue }
            var merged = usage[id] ?? AccountUsage(windows: [])
            for window in live.windows {
                if let index = merged.windows.firstIndex(where: { $0.id == window.id }) { merged.windows[index] = window } else { merged.windows.append(window) }
            }
            merged.stale = false
            usage[id] = merged
            readAt[id] = Date(timeIntervalSince1970: live.at)
            if issues[id] == "offline" || issues[id] == "idle" { issues[id] = nil; failing.remove(id) }
            sample(id, live.windows.first { $0.id == "five_hour" }, at: live.at)
            changed = true
        }
        if changed { saveUsageCache() }
        for (id, end) in loginEnds where end - Date().timeIntervalSince1970 < 3 * 86_400 && endWarned[id] != end {
            endWarned[id] = end
            if let name = config.accounts.first(where: { $0.id == id })?.name {
                notify("Sign in to \(name) again soon", "Its sign-in ends \(UsageBar.format(end)). Signing in again keeps its limits readable and Autopilot using it.")
            }
        }
        unknownLogins = [.claude: value.accountID == nil ? value.email : "", .codex: value.codexAccountID == nil ? value.codexEmail : ""]
            .filter { !$0.value.isEmpty }
        return true
    }
    /// Ten minutes old is fresh enough on screen; in the background only the schedule needs it, hourly.
    func refreshReport(maxAge: TimeInterval = 600) async {
        guard !isDemo, Date().timeIntervalSince(reportAt) > maxAge else { return }
        reportAt = Date()
        // The first scan reads every transcript from the last 30 days; later scans use a cache.
        if let data = try? await bridgeOutput(["report"], timeout: 900), let value = try? JSONDecoder().decode(UsageReport.self, from: data) {
            if value != report { report = value; try? PrivateFile.write(value, to: reportURL) }
        }
    }
    func setShellSwitching(_ enabled: Bool) async {
        struct State: Decodable { let installed: Bool }
        do {
            let data = try await bridgeOutput(["shell", enabled ? "on" : "off"])
            shellSwitching = try JSONDecoder().decode(State.self, from: data).installed
        } catch { self.error = error.localizedDescription }
    }
    func setLiveLimits(_ enabled: Bool) async {
        struct State: Decodable { let installed: Bool }
        config.liveLimits = enabled; persist()
        do {
            let data = try await bridgeOutput(["live", enabled ? "on" : "off"])
            liveLimits = try JSONDecoder().decode(State.self, from: data).installed
        } catch { self.error = error.localizedDescription }
    }
    // MARK: Fork additions: running-session view, manual session actions, Fable fallback.

    /// Every account's Fable limit is spent, so new commands resolve `fable` to Opus.
    var fableToOpus = false
    /// Opt-in `fallbackModel` in Claude Code's settings.
    var opusFallback = false
    var sessions: [LiveSession] = []
    /// Sessions Side A is typing into right now.
    var actingOn: Set<Int> = []
    @ObservationIgnored private var stuckNotified: Set<Int> = []
    @ObservationIgnored private var limitReported: [Int: Double] = [:]

    func setOpusFallback(_ enabled: Bool) async {
        struct State: Decodable { let installed: Bool }
        do {
            let data = try await bridgeOutput(["fallback", enabled ? "on" : "off"])
            opusFallback = try JSONDecoder().decode(State.self, from: data).installed
        } catch { self.error = error.localizedDescription }
    }
    private func setFableToOpus(_ enabled: Bool) async {
        guard enabled != fableToOpus else { return }
        struct State: Decodable { let installed: Bool }
        if let data = try? await bridgeOutput(["fable", enabled ? "on" : "off"]),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            fableToOpus = state.installed
            if state.installed { notify("Fable is spent on every account", "New claude commands use Opus for Fable until a Fable limit resets.") }
        }
    }
    enum SessionAction: String { case opus, move, focus, rescue, opusContinue = "opus-continue" }
    /// Types into the session's Ghostty tab, by hand from the menu: `/model opus`, `/exit` and a
    /// resume on the current account, or bringing its tab to the front. Returns the failure, if any.
    @discardableResult func act(on pid: Int, _ action: SessionAction, reportError: Bool = true) async -> String? {
        guard !isDemo, !actingOn.contains(pid) else { return "Already working on this session." }
        actingOn.insert(pid); defer { actingOn.remove(pid) }
        let timeout: TimeInterval = action == .rescue ? 600 : action == .focus ? 60 : 420
        do { _ = try await bridgeOutput(["session", String(pid), action.rawValue], timeout: timeout) }
        catch {
            if reportError { self.error = error.localizedDescription }
            return error.localizedDescription
        }
        try? await Task.sleep(for: .seconds(2))
        await refreshSessions()
        return nil
    }
    func fableSpent(_ accountID: String?) -> Bool {
        let now = Date().timeIntervalSince1970
        return accountID.flatMap { usage[$0]?.fable }.map { $0.percent >= Planner.limited && ($0.resetsAt ?? 0) > now } ?? false
    }
    /// Waiting on you, or busy far too long, on an account where a limit it needs is spent.
    func isStuck(_ session: LiveSession) -> Bool {
        guard let id = session.accountID, let value = usage[id] else { return false }
        return Planner.isSpent(value, onFable: session.onFable, now: Date().timeIntervalSince1970)
            && session.looksStuck(now: Date().timeIntervalSince1970)
    }
    func refreshSessions() async {
        guard !isDemo, let data = try? await bridgeOutput(["sessions"]),
              let value = try? JSONDecoder().decode([LiveSession].self, from: data) else { return }
        if value != sessions { sessions = value }
        let name = { (id: String?) in self.config.accounts.first { $0.id == id }?.name ?? "its account" }
        // Side A never answers Claude Code's limit prompt (one choice buys usage credits); it says so instead.
        let stuck = value.filter { isStuck($0) }
        for session in stuck where !stuckNotified.contains(session.pid) {
            notify("\(session.name ?? "A session") is stuck on a limit",
                   "\(name(session.accountID)) is out of usage for it. Autopilot trades its login to an account with room within a minute; then press Esc in its tab and type continue.")
        }
        stuckNotified = Set(stuck.map(\.pid))
        // A limit error ends the turn: once the login has moved, the session only needs "continue".
        let now = Date().timeIntervalSince1970
        for session in value where session.limitHit != nil {
            guard let at = session.limitAt, now - at < 1800, limitReported[session.pid] != at else { continue }
            limitReported[session.pid] = at
            notify("\(session.name ?? "A session") hit its \(session.limitHit ?? "") limit",
                   "Autopilot moves its login to an account with room. Once it has, type continue in its tab.")
        }
    }

    func setLimitHook(_ enabled: Bool) async {
        struct State: Decodable { let installed: Bool }
        do {
            let data = try await bridgeOutput(["hook", enabled ? "on" : "off"])
            limitHook = try JSONDecoder().decode(State.self, from: data).installed
        } catch { self.error = error.localizedDescription }
    }
    /// True when a session reported new limits, at most every 15 s, so a trade happens
    /// between replies rather than up to a minute later.
    private func liveChanged() -> Bool {
        let url = root.appendingPathComponent("runtime/live")
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              date > liveSeen, Date().timeIntervalSince(liveSeen) > 15 else { return false }
        liveSeen = Date()
        return true
    }
    /// True once per touch of the marker the opt-in StopFailure hook writes on a rate limit.
    private func limitHit() -> Bool {
        let url = root.appendingPathComponent("runtime/limit-hit")
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        defer { limitMarkerDate = date }
        guard let seen = limitMarkerDate, date > seen else { return false }
        // Re-read the active account now instead of waiting for its next poll.
        // Throttled so many sessions hitting a limit cannot hammer the usage endpoint.
        if let id = activeIDs[.claude], Date().timeIntervalSince(usageAt[id] ?? .distantPast) > 30 { usageAt[id] = nil }
        return true
    }
    /// One autopilot step: refresh usage, move each provider's Mac-wide login, start idle windows.
    private func tick() async {
        guard !isDemo, !startupError, python != nil else { return }
        // Without knowing who is active, a "switch" could only re-pick the current account.
        guard await refreshActive() else { return }
        await refresh(config.accounts.filter { $0.ready && dueForRead($0) }.map(\.id))
        Task { await refreshReport(maxAge: 3600) }
        Task { await refreshSessions() }
        // The Fable remap only makes sense while Autopilot steers Terminal; never leave it behind.
        if !config.smartMode || !shellSwitching { await setFableToOpus(false) }
        guard config.smartMode else { return }
        let now = Date().timeIntervalSince1970
        // Codex: the desktop app keeps its own copy of the login, and OpenAI revokes a login
        // whose refresh token is used twice, so Codex is never switched automatically.
        for provider in [AgentProvider.claude] where unknownLogins[provider] == nil {
            let accounts = config.accounts.filter { $0.provider == provider }
            let current = activeIDs[provider]
            let plannable = planning(self.plannable)
            // Fable spent on every account (known, not merely unreadable): new commands use Opus for Fable.
            let fableMaybeLeft = accounts.contains { account in
                // A signed-out account's last reading can't be used, so its Fable doesn't count.
                account.ready && account.allowAuto && usage[account.id]?.stale != true
                    && !(plannable[account.id].map { Planner.isSpent($0, onFable: false, now: now) } ?? false)
                    && (usage[account.id]?.fable.map { $0.percent < Planner.limited || ($0.resetsAt ?? 0) <= now } ?? true)
            }
            await setFableToOpus(shellSwitching && !fableMaybeLeft)
            let name = { (id: String) in self.config.accounts.first { $0.id == id }?.name ?? "" }
            // Logins running sessions read, by slot. Unknown (processes can't be listed) means no
            // trades; only new commands move.
            var slots = busyLogins ?? [:]
            let busy = { Set(slots.values).union([current].compactMap { $0 }) }
            for slot in slots.keys.sorted(by: { slots[$0] == current && slots[$1] != current }) {
                // Settings may have changed during the last trade.
                guard config.smartMode, let id = slots[slot], let account = config.accounts.first(where: { $0.id == id }) else { continue }
                // A failed read is not evidence of a limit; only a signed-out account moves.
                if failing.contains(id), usage[id]?.stale != true { continue }
                // An account with Autopilot off, or mid sign-in, is never moved automatically.
                if !account.allowAuto || signingIn.contains(id) { continue }
                // Trade only with an account no session is using, so no session lands on the full one.
                let free = config.accounts.filter { $0.provider == provider && ($0.id == id || (!busy().contains($0.id) && !signingIn.contains($0.id))) }
                var share = false
                // Sessions that all run other models don't need Fable room, here or where they go.
                let theirs = sessions.filter { $0.accountID == id }
                let fableFree = !theirs.isEmpty && theirs.allSatisfy { $0.model != nil && !$0.onFable }
                var target = fableFree
                    ? Planner.best(free, usage: self.plannable, active: id, now: now, ignoringModelLimits: true)
                    : Planner.best(free, usage: plannable, active: id, now: now)
                if target == nil, let pick = fableShare(id, slots: slots, current: current, now: now) { target = pick; share = true }
                // No Fable room anywhere and this account is about to stop every session on it:
                // move anyway, so the sessions on other models keep running.
                if target == nil, !fableFree, let mine = self.plannable[id],
                   [mine.fiveHour, mine.weekly].contains(where: { ($0?.resetsAt ?? 0) > now && ($0?.percent ?? 0) >= Planner.limited }) {
                    target = Planner.best(free, usage: self.plannable, active: id, now: now, ignoringModelLimits: true)
                }
                guard let best = target, best != id else { continue }
                if await swap(slot, best, share: share) {
                    // The Opus sessions that had `best` continue on the login this slot gave up.
                    if share, let theirs = slots.first(where: { $0.value == best })?.key { slots[theirs] = id }
                    slots[slot] = best
                    notify("Now playing: \(name(best))", "\(name(id)) is near its limit. Its running sessions continue as \(name(best)) within a minute, nothing to restart.")
                }
            }
            // New commands: if the account they use is still full (no trade, or no sessions on it), point them elsewhere.
            if config.smartMode, shellSwitching, let current = activeIDs[provider], !signingIn.contains(current),
               config.accounts.first(where: { $0.id == current })?.allowAuto != false,
               !(failing.contains(current) && usage[current]?.stale != true),
               let best = Planner.best(config.accounts.filter { $0.provider == provider && ($0.id == current || !busy().contains($0.id)) },
                                       usage: plannable, active: current, now: now), best != current {
                await activate(best)
                if activeIDs[provider] == best {
                    notify("Now playing: \(name(best))", "\(name(current)) is near its limit. New claude commands use \(name(best)).")
                }
            }
            if config.smartMode, activeIDs[provider] == nil, shellSwitching, let best = Planner.best(accounts, usage: plannable, active: nil, now: now) {
                await activate(best)
            }
            if provider == .claude, let next = Planner.nextAvailable(accounts, usage: plannable, now: now), Planner.best(accounts, usage: plannable, active: current, now: now) == nil {
                if !exhaustedNotified {
                    exhaustedNotified = true
                    notify(fableMode ? "Fable is used up" : "All tracks played",
                           fableMode ? "Every account has spent its Fable share. Switch to another model, or wait until \(UsageBar.format(next.1))."
                                     : "\(next.0.name) is back \(UsageBar.format(next.1)).")
                }
            } else if provider == .claude { exhaustedNotified = false }
        }
        let minute = Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())
        // Until the report has loaded, the schedule is unknown, not absent: wait for it.
        guard let report, WorkSchedule(report.activity)?.allowsPriming(atMinute: minute) ?? true else { return }
        for account in config.accounts where Planner.shouldPrime(account, usage: plannable[account.id], now: now)
            && Date().timeIntervalSince(primedAt[account.id] ?? .distantPast) > 1800 {
            primedAt[account.id] = Date()
            saveUsageCache()
            _ = try? await bridgeOutput(["prime", account.id], timeout: 200)
            backoffUntil[account.id] = nil
            await refreshUsage(account.id)
        }
    }
    func setMenuBarOnly(_ value: Bool) {
        config.menuBarOnly = value; persist()
        NSApp.setActivationPolicy(value ? .accessory : .regular)
    }
    private func bridgeOutput(_ args: [String], timeout: TimeInterval = 60) async throws -> Data {
        guard let python, let bridgeURL else { throw BridgeFailure(message: "Install Python 3 to connect your accounts.") }
        let arguments = [bridgeURL.path, "--root", root.path] + args
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            // The helper returns sanitized diagnostics; raw CLI stderr is never logged.
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            // The bridge leads its own process group; stopping the group also stops a hung claude or codex child.
            let watchdog = DispatchWorkItem { if process.isRunning { kill(-process.processIdentifier, SIGTERM); process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            defer { watchdog.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let message = (String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw BridgeFailure(message: message.isEmpty
                    ? (process.terminationReason == .uncaughtSignal || process.terminationStatus == 143 ? "Timed out; Side A stopped waiting." : "Failed without a reason.")
                    : message)
            }
            return data
        }.value
    }
}
