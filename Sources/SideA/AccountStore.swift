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
    var config = Configuration()
    var dependencies = DependencyReport()
    var checkingDependencies = false
    var error: String?
    /// Accounts that own the Mac-wide Claude and Codex logins, when they are in the library.
    var activeIDs: [AgentProvider: String] = [:]
    /// Mac-wide login emails that are not in the library yet.
    var unknownLogins: [AgentProvider: String] = [:]
    var report: UsageReport?
    var limitHook = false
    /// The `claude` shell function that makes new commands use the chosen account.
    var shellSwitching = false
    /// Every account's Fable limit is spent, so new commands resolve `fable` to Opus.
    var fableToOpus = false
    /// Opt-in `fallbackModel` in Claude Code's settings.
    var opusFallback = false
    var sessions: [LiveSession] = []
    /// Sessions Side A is typing into right now.
    var actingOn: Set<Int> = []
    /// Opt-in: when a Fable session's account runs out of Fable, move it to an account with Fable
    /// left, or switch it to Opus when none has any, by typing into its Ghostty tab.
    var fixFableSessions = UserDefaults.standard.bool(forKey: "sidea.fixFableSessions") {
        didSet { UserDefaults.standard.set(fixFableSessions, forKey: "sidea.fixFableSessions") }
    }
    @ObservationIgnored private var fixedAt: [Int: Date] = [:]
    @ObservationIgnored private var switchedToOpus: Set<Int> = []
    /// Limit hits already reported because Side A could not move the session itself.
    @ObservationIgnored private var limitReported: [Int: Double] = [:]
    /// Sessions already told they should move but can't be moved automatically (background work).
    @ObservationIgnored private var moveSuggested: [Int: String] = [:]
    /// Fable sessions already reported as stuck, until they move on.
    @ObservationIgnored private var stuckNotified: Set<Int> = []
    @ObservationIgnored private var reportAt = Date.distantPast
    @ObservationIgnored private var limitMarkerDate: Date?
    var usage: [String: AccountUsage] = [:]
    var signingIn: Set<String> = []
    @ObservationIgnored private var primedAt: [String: Date] = [:]
    @ObservationIgnored private var usageAt: [String: Date] = [:]
    @ObservationIgnored private var backoffUntil: [String: Date] = [:]
    /// Accounts whose latest read failed for a reason other than being idle. They keep their
    /// last bars on screen but are left out of Autopilot until a read succeeds.
    @ObservationIgnored private var failing: Set<String> = []
    /// When each failing account's reads started failing. A brief failure is a hiccup; one that lasts
    /// means its real limits are unknown, so Autopilot may move the Mac off it.
    @ObservationIgnored private var failingSince: [String: Date] = [:]
    /// When each account was last read successfully; `usageAt` is the last attempt.
    @ObservationIgnored private var readAt: [String: Date] = [:]
    @ObservationIgnored private var loginStamps: [String: Double] = [:]
    /// Accounts already reported as having their login replaced, until they read again.
    @ObservationIgnored private var replacedNotified: Set<String> = []
    func readsFailing(_ id: String) -> Bool { failing.contains(id) }
    @ObservationIgnored private var reading: Set<String> = []
    /// Bumped by every switch, so an "active" answer that started earlier cannot overwrite it.
    @ObservationIgnored private var selectionGeneration = 0
    /// Recent (time, 5-hour percent) samples per account for the burn-rate forecast.
    @ObservationIgnored private var samples: [String: [(Double, Double)]] = [:]
    @ObservationIgnored private var exhaustedNotified = false
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
                                 activity: (0..<14).map { ActivitySpan(date: "d\($0)", hours: (0..<24).map { (9...18).contains($0) ? 40 : 1 }) })
        } else if FileManager.default.fileExists(atPath: configURL.path) {
            do { config = try PrivateFile.read(Configuration.self, from: configURL).validated() }
            catch { self.error = error.localizedDescription; startupError = true }
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            // First launch: Autopilot only helps while running, so start with the Mac.
            try? SMAppService.mainApp.register()
        }
        if !isDemo, let cache = try? PrivateFile.read(UsageCache.self, from: usageCacheURL) {
            // Show the last numbers at once and keep each account on its normal polling schedule.
            // Readings from before model-scoped limits (Fable) were tracked are re-read at once.
            usage = cache.usage; usageAt = cache.modelLimits == true ? cache.at : [:]
            backoffUntil = cache.backoff ?? [:]; primedAt = cache.primed ?? [:]; failing = Set(cache.failing ?? [])
            // Counted from now: one old failure must not move the Mac off its account at launch.
            for id in failing { failingSince[id] = Date() }
            readAt = cache.readAt ?? [:]
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
                    if self?.limitHit() == true { break }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func loadIntegrations() async {
        struct State: Decodable { let installed: Bool }
        async let hook = try? bridgeOutput(["hook", "status"])
        async let shell = try? bridgeOutput(["shell", "status"])
        if let data = await hook { limitHook = (try? JSONDecoder().decode(State.self, from: data))?.installed ?? false }
        if let data = await shell { shellSwitching = (try? JSONDecoder().decode(State.self, from: data))?.installed ?? false }
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
    func toggleSmart() { config.smartMode.toggle(); persist() }
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
            return persist()
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
        do {
            _ = try await bridgeOutput(["activate", id])
            selectionGeneration += 1
            activeIDs[account.provider] = id
        } catch { self.error = error.localizedDescription }
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
        usageAt[id] = Date()
        do {
            let value = try JSONDecoder().decode(AccountUsage.self, from: try await bridgeOutput(["usage", id]))
            usage[id] = value
            failing.remove(id); failingSince[id] = nil; readAt[id] = Date(); replacedNotified.remove(id)
            let now = Date().timeIntervalSince1970
            if let five = value.fiveHour {
                // A drop means the window reset; the old pace no longer applies.
                if let last = samples[id]?.last, five.percent < last.1 { samples[id] = [] }
                samples[id, default: []].append((now, five.percent))
                samples[id]?.removeAll { now - $0.0 > 1200 }
            }
        } catch {
            let message = error.localizedDescription
            // Idle: nobody has used the login since it expired, so the last reading still holds.
            if message.contains("idle") {
                backoffUntil[id] = Date().addingTimeInterval(1800)
            } else {
                // The usage endpoint rate-limits frequent reads; back off rather than retry.
                let signIn = message.contains("Sign in")
                backoffUntil[id] = Date().addingTimeInterval(signIn ? 1800 : message.contains("429") ? 600 : 300)
                failing.insert(id)
                if failingSince[id] == nil { failingSince[id] = Date() }
                if signIn { usage[id]?.stale = true }
                if message.contains("belongs to another account"), !replacedNotified.contains(id),
                   let name = config.accounts.first(where: { $0.id == id })?.name {
                    replacedNotified.insert(id)
                    notify("\(name)'s login was replaced",
                           "A session using \(name) signed in to a different account with /login. In Side A, open Accounts and choose Sign in again for \(name).")
                }
            }
        }
        saveUsageCache()
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
    /// What Autopilot may act on: accounts with a trustworthy latest reading, plus any account a
    /// running session just hit a limit on (its own error is proof, even while reads are failing).
    private var plannable: [String: AccountUsage] {
        // A failed read keeps its last good reading for 30 minutes; a 429 says nothing about the limits.
        var value = usage.filter { !failing.contains($0.key) || Date().timeIntervalSince(readAt[$0.key] ?? .distantPast) < 1800 }
        for (id, evidence) in limitEvidence { value[id] = evidence }
        return value
    }
    /// Accounts with a limit a session reported hitting after the account's last successful reading.
    private var limitEvidence: [String: AccountUsage] {
        let now = Date().timeIntervalSince1970
        var result: [String: AccountUsage] = [:]
        for session in sessions {
            guard let id = session.accountID, let limit = session.limitHit, let at = session.limitAt else { continue }
            result[id] = Planner.withEvidence(result[id] ?? usage[id], limit: limit, at: at,
                                              readAt: readAt[id]?.timeIntervalSince1970 ?? 0, now: now)
        }
        return result
    }
    private struct UsageCache: Codable {
        var usage: [String: AccountUsage]; var at: [String: Date]
        var backoff: [String: Date]?; var primed: [String: Date]?
        var active: [String: String]?; var failing: [String]?
        var modelLimits: Bool?
        var readAt: [String: Date]?
    }
    private var reportURL: URL { root.appendingPathComponent("runtime/report.json") }
    private var usageCacheURL: URL { root.appendingPathComponent("runtime/usage-cache.json") }
    private func saveUsageCache() {
        try? PrivateFile.write(UsageCache(usage: usage, at: usageAt, backoff: backoffUntil, primed: primedAt,
                                          active: Dictionary(uniqueKeysWithValues: activeIDs.map { ($0.key.rawValue, $0.value) }),
                                          failing: Array(failing), modelLimits: true, readAt: readAt),
                               to: usageCacheURL)
    }
    /// Active accounts change fastest, then accounts running sessions (a session keeps the account it
    /// started on). An idle account at a limit is read hourly rather than every 10 minutes: limits can
    /// reset early (a free reset, or a weekly reset), so it is never left unread until its reset time.
    private func dueForRead(_ account: Account) -> Bool {
        let now = Date().timeIntervalSince1970
        let inUse = isActive(account) || sessions.contains { $0.accountID == account.id }
        let limited = usage[account.id].map { value in
            !value.stale && ([value.fiveHour].compactMap({ $0 }) + value.weeklyLimits)
                .contains { $0.percent >= Planner.full && ($0.resetsAt ?? 0) > now }
        } ?? false
        let interval: TimeInterval = isActive(account) ? (nearLimit(account.id) ? 60 : 120)
            : inUse ? 300 : limited ? 3600 : 600
        return Date().timeIntervalSince(usageAt[account.id] ?? .distantPast) >= interval - 1
    }
    /// Minutes until the account's 5-hour limit at its recent pace.
    func minutesToLimit(_ id: String) -> Double? { Planner.minutesToLimit(samples[id] ?? []) }
    private func nearLimit(_ id: String) -> Bool {
        (usage[id]?.fiveHour?.percent ?? 0) >= 85 || (minutesToLimit(id) ?? .infinity) < 15
    }
    private func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        Self.post(title, body)
    }
    /// Nonisolated: the authorization callback runs on a background queue, and a closure formed in
    /// this main-actor class would trap there under Swift 6's isolation checks.
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
        struct Active: Decodable { let accountID: String?; let email: String; let codexAccountID: String?; let codexEmail: String; let logins: [String: Double]? }
        guard let data = try? await bridgeOutput(["active"]), let value = try? JSONDecoder().decode(Active.self, from: data) else { return false }
        guard generation == selectionGeneration else { return false }
        activeIDs = [.claude: value.accountID, .codex: value.codexAccountID].compactMapValues { $0 }
        // From upstream 0.5.16: a login that changed (signed in again, or refreshed by Claude Code)
        // is read now; the back-off and any old failure belonged to the previous login.
        for (id, stamp) in value.logins ?? [:] {
            if let seen = loginStamps[id], seen != stamp {
                backoffUntil[id] = nil; usageAt[id] = nil; failing.remove(id); failingSince[id] = nil
            }
            loginStamps[id] = stamp
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
    /// Types into the session's Ghostty tab: `/model opus`, `/exit` and a resume on the current
    /// account, or for a rescue Esc first and `continue` after. Returns the failure, if any.
    @discardableResult func act(on pid: Int, _ action: SessionAction, reportError: Bool = true, automatic: Bool = false) async -> String? {
        guard !isDemo, !actingOn.contains(pid) else { return "Already working on this session." }
        actingOn.insert(pid); defer { actingOn.remove(pid) }
        // Above the bridge's own worst case (its waits plus several Ghostty calls), so it is never cut off mid-move.
        let timeout: TimeInterval = action == .rescue ? 600 : action == .focus ? 60 : 420
        do { _ = try await bridgeOutput(["session", String(pid), action.rawValue] + (automatic ? ["--auto"] : []), timeout: timeout) }
        catch {
            if reportError { self.error = error.localizedDescription }
            return error.localizedDescription
        }
        try? await Task.sleep(for: .seconds(2))
        await refreshSessions()
        return nil
    }
    /// Opt-in, on by default: a session stuck mid-turn on a spent limit is pressed Esc, moved to an
    /// account with room, and told to continue, instead of waiting for you.
    var rescueStuckSessions = UserDefaults.standard.object(forKey: "sidea.rescueStuck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(rescueStuckSessions, forKey: "sidea.rescueStuck") }
    }
    /// A reading Autopilot may act on: read in the last 10 minutes and not failing.
    private func trusted(_ id: String) -> AccountUsage? {
        if let evidence = limitEvidence[id] { return evidence }
        guard !failing.contains(id), Date().timeIntervalSince(readAt[id] ?? .distantPast) < 600 else { return nil }
        return usage[id]
    }
    /// The account new commands use, when it has room for this session.
    private func roomyTarget(for session: LiveSession, now: Double) -> String? {
        guard shellSwitching, let target = activeIDs[.claude], target != session.accountID,
              let value = trusted(target), !value.stale, !Planner.shouldLeave(value, onFable: session.onFable, now: now) else { return nil }
        return target
    }
    private func rescueStuck(now: Double) async {
        // A limit hit Side A won't act on (a shell command may be running, or there is no tab): say so once.
        for session in sessions where session.limitHit != nil && (session.status == "shell" || !session.restartable) {
            guard let at = session.limitAt, now - at < 1800, (limitReported[session.pid] ?? 0) < at - 3600 || limitReported[session.pid] == nil
            else { continue }
            limitReported[session.pid] = at
            let account = config.accounts.first { $0.id == session.accountID }?.name ?? "its account"
            notify("\(session.name ?? "A session") hit its \(session.limitHit ?? "") limit",
                   session.inTerminal
                       ? "It's on \(account) and has commands running that a restart would kill, so Side A won't exit it. Type /login in its tab and sign in to an account with room to switch without restarting."
                       : "It's a headless job on \(account); it can't be moved. It will stop until the limit resets.")
        }
        guard rescueStuckSessions else { return }
        for session in sessions where session.restartable && (freshLimit(session) || session.looksStuck(now: now))
            && session.status != "shell" && Date().timeIntervalSince(fixedAt[session.pid] ?? .distantPast) > 600 {
            guard let id = session.accountID, let value = trusted(id),
                  Planner.isExhausted(value, onFable: session.onFable, now: now) else { continue }
            guard let target = roomyTarget(for: session, now: now) else {
                // A Fable limit with no Fable left anywhere: carry on in Opus.
                if session.limitHit == "fable", session.status == "idle", !switchedToOpus.contains(session.pid) {
                    fixedAt[session.pid] = Date()
                    if let failure = await act(on: session.pid, .opusContinue, reportError: false, automatic: true) {
                        notify("Couldn't switch \(session.name ?? "a session") to Opus", failure)
                    } else {
                        switchedToOpus.insert(session.pid)
                        notify("Switched \(session.name ?? "a session") to Opus", "It hit its Fable limit and no account has Fable left; it continued in Opus.")
                    }
                }
                continue
            }
            fixedAt[session.pid] = Date()
            let name = session.name ?? "A session"
            let account = config.accounts.first { $0.id == target }?.name ?? "another account"
            if let failure = await act(on: session.pid, .rescue, reportError: false, automatic: true) {
                notify("Couldn't rescue \(name)", failure)
            } else {
                notify("Rescued \(name)", "Its account ran out, so it moved to \(account) and continued where it stopped.")
            }
        }
    }
    /// Moves idle sessions off an account before it runs out: once a limit the session depends on
    /// reaches 90%, to the account new commands use if that one has room for it. A Fable session with
    /// nowhere to go is switched to Opus once its Fable is nearly spent. Busy sessions are never
    /// interrupted. Each session is tried once per 10 minutes.
    private func fixSessions(fableSpentEverywhere: Bool) async {
        guard fixFableSessions else { return }
        let now = Date().timeIntervalSince1970
        // Turn over but still "busy" (background tasks): /exit would kill that work, so say it once instead.
        for session in sessions where session.inTerminal && ((session.status == "busy" && session.turnEnded == true) || (session.runningJobs ?? 0) > 0) {
            guard let id = session.accountID, moveSuggested[session.pid] != id, let value = trusted(id),
                  Planner.shouldLeave(value, onFable: session.onFable, now: now),
                  let target = roomyTarget(for: session, now: now) else { continue }
            moveSuggested[session.pid] = id
            let from = config.accounts.first { $0.id == id }?.name ?? "Its account"
            let to = config.accounts.first { $0.id == target }?.name ?? "another account"
            notify("Move \(session.name ?? "a session") to \(to)?",
                   (session.runningJobs ?? 0) > 0
                       ? "\(from) is close to a limit, and the session has commands running that a restart would kill. Type /login in its tab and sign in as \(to) to switch without restarting."
                       : "\(from) is close to a limit, but the session has background work running, so Side A won't exit it. When that work is done, /exit and run claude -c in its tab.")
        }
        for session in sessions where session.restartable && session.status == "idle" && !freshLimit(session)
            && Date().timeIntervalSince(fixedAt[session.pid] ?? .distantPast) > 600 {
            guard let id = session.accountID, let value = trusted(id),
                  Planner.shouldLeave(value, onFable: session.onFable, now: now) else { continue }
            let target = roomyTarget(for: session, now: now)
            // Already switched to Opus: its last reply stays Fable until the next turn, so don't repeat it.
            let fableOnly = session.onFable && !Planner.shouldLeave(value, onFable: false, now: now) && !switchedToOpus.contains(session.pid)
            guard target != nil || fableOnly else { continue }
            fixedAt[session.pid] = Date()
            let name = session.name ?? "A session"
            let from = config.accounts.first { $0.id == id }?.name ?? "Its account"
            if let failure = await act(on: session.pid, target != nil ? .move : .opus, reportError: false, automatic: true) {
                notify("Couldn't move \(name)", failure)
            } else if let target {
                let account = config.accounts.first { $0.id == target }?.name ?? "another account"
                notify("Moved \(name) to \(account)", "\(from) is close to a limit; the conversation continues where it was.")
            } else {
                switchedToOpus.insert(session.pid)
                notify("Switched \(name) to Opus", "\(from) is nearly out of Fable and no account has Fable to spare.")
            }
        }
    }
    func fableSpent(_ accountID: String?) -> Bool {
        let now = Date().timeIntervalSince1970
        return accountID.flatMap { usage[$0]?.fable }.map { $0.percent >= Planner.full && ($0.resetsAt ?? 0) > now } ?? false
    }
    /// The session's limit error is newer than its account's latest reading. An older one (say, from
    /// an account it was on before a /login) is history: the reading decides.
    func freshLimit(_ session: LiveSession) -> Bool {
        guard session.limitHit != nil, let at = session.limitAt, let id = session.accountID else { return false }
        return at > (readAt[id]?.timeIntervalSince1970 ?? 0)
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
        // Side A never answers that prompt (one choice buys usage credits); it tells you instead.
        let stuck = value.filter { isStuck($0) }
        for session in stuck where !stuckNotified.contains(session.pid) {
            let account = config.accounts.first { $0.id == session.accountID }?.name ?? "Its account"
            notify("\(session.name ?? "A session") is stuck on a limit",
                   session.onFable ? "\(account) is out of usage for it. In its Ghostty tab, choose Switch to … and continue, or press Esc and move it."
                                   : "\(account) is out of usage. Press Esc in its Ghostty tab, then move it from the Side A menu.")
        }
        stuckNotified = Set(stuck.map(\.pid))
    }
    func setLimitHook(_ enabled: Bool) async {
        struct State: Decodable { let installed: Bool }
        do {
            let data = try await bridgeOutput(["hook", enabled ? "on" : "off"])
            limitHook = try JSONDecoder().decode(State.self, from: data).installed
        } catch { self.error = error.localizedDescription }
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
        for provider in [AgentProvider.claude] where unknownLogins[provider] == nil && shellSwitching {
            let accounts = config.accounts.filter { $0.provider == provider }
            let current = activeIDs[provider]
            var pick = Planner.pick(accounts, usage: plannable, active: current, now: now)
            // Fable counts as spent everywhere only when every account's Fable is known to be spent;
            // an account Side A can't read right now may well have Fable left.
            let fableMaybeLeft = accounts.contains { account in
                account.ready && account.allowAuto
                    && !(plannable[account.id].map { Planner.isSpent($0, onFable: false, now: now) } ?? false)
                    && (usage[account.id]?.fable.map { $0.percent < Planner.full || ($0.resetsAt ?? 0) <= now } ?? true)
                    && plannable[account.id]?.fable.map({ $0.percent < Planner.full || ($0.resetsAt ?? 0) <= now }) != false
            }
            if pick.fableSpent && fableMaybeLeft { pick = (nil, false) }
            await setFableToOpus(pick.fableSpent)
            // A failed read is not evidence of a limit; only a signed-out active account moves.
            if let current, failing.contains(current), usage[current]?.stale != true,
               Date().timeIntervalSince(failingSince[current] ?? Date()) < 600 { continue }
            // An account with Autopilot off is never switched away from automatically.
            if let current, config.accounts.first(where: { $0.id == current })?.allowAuto == false { continue }
            if let best = pick.id, best != current {
                let from = config.accounts.first { $0.id == current }?.name
                await activate(best)
                if activeIDs[provider] == best, let name = config.accounts.first(where: { $0.id == best })?.name {
                    notify("Switched to \(name)", from.map { "\($0) is near its limit or has less quota at risk." } ?? "Autopilot picked the account with the most quota at risk.")
                }
            }
            if provider == .claude {
                await fixSessions(fableSpentEverywhere: pick.fableSpent)
                await rescueStuck(now: now)
            }
            if provider == .claude, let next = Planner.nextAvailable(accounts, usage: plannable, now: now), Planner.best(accounts, usage: plannable, active: nil, now: now, ignoringModelLimits: true) == nil {
                if !exhaustedNotified {
                    exhaustedNotified = true
                    notify("All Claude accounts are limited", "\(next.0.name) is back \(UsageBar.format(next.1)).")
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
            if (try? await bridgeOutput(["prime", account.id], timeout: 200)) != nil { await refreshUsage(account.id) }
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
