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
    }
    /// Reads accounts side by side; each Codex read starts its own app-server, so serial reads add up.
    private func refresh(_ ids: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.refreshUsage(id) } }
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
            failing.remove(id)
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
                if signIn { usage[id]?.stale = true }
            }
        }
        saveUsageCache()
    }
    /// Refreshes what is due (menu open). The refresh button passes `force` but still
    /// respects backoff and never re-reads an account checked in the last minute.
    func refreshAll(force: Bool = false) async {
        await refreshActive()
        Task { await refreshReport() }
        await refresh(config.accounts.filter { $0.ready
            && (dueForRead($0) || (force && Date().timeIntervalSince(usageAt[$0.id] ?? .distantPast) > 60)) }.map(\.id))
    }
    /// What Autopilot may act on: accounts with a trustworthy latest reading.
    private var plannable: [String: AccountUsage] { usage.filter { !failing.contains($0.key) } }
    private struct UsageCache: Codable {
        var usage: [String: AccountUsage]; var at: [String: Date]
        var backoff: [String: Date]?; var primed: [String: Date]?
        var active: [String: String]?; var failing: [String]?
        var modelLimits: Bool?
    }
    private var reportURL: URL { root.appendingPathComponent("runtime/report.json") }
    private var usageCacheURL: URL { root.appendingPathComponent("runtime/usage-cache.json") }
    private func saveUsageCache() {
        try? PrivateFile.write(UsageCache(usage: usage, at: usageAt, backoff: backoffUntil, primed: primedAt,
                                          active: Dictionary(uniqueKeysWithValues: activeIDs.map { ($0.key.rawValue, $0.value) }),
                                          failing: Array(failing), modelLimits: true),
                               to: usageCacheURL)
    }
    /// Active accounts change fastest. An idle account at a limit cannot change until that
    /// limit resets, so it is not read again before then.
    private func dueForRead(_ account: Account) -> Bool {
        let now = Date().timeIntervalSince1970
        if !isActive(account), let value = usage[account.id], !value.stale,
           let reset = ([value.fiveHour].compactMap({ $0 }) + value.weeklyLimits).filter({ $0.percent >= Planner.full }).compactMap(\.resetsAt).max(),
           reset > now {
            return false
        }
        let interval: TimeInterval = isActive(account) ? (nearLimit(account.id) ? 60 : 120) : 600
        return Date().timeIntervalSince(usageAt[account.id] ?? .distantPast) >= interval - 1
    }
    /// Minutes until the account's 5-hour limit at its recent pace.
    func minutesToLimit(_ id: String) -> Double? { Planner.minutesToLimit(samples[id] ?? []) }
    private func nearLimit(_ id: String) -> Bool {
        (usage[id]?.fiveHour?.percent ?? 0) >= 85 || (minutesToLimit(id) ?? .infinity) < 15
    }
    private func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
    @discardableResult private func refreshActive() async -> Bool {
        let generation = selectionGeneration
        struct Active: Decodable { let accountID: String?; let email: String; let codexAccountID: String?; let codexEmail: String }
        guard let data = try? await bridgeOutput(["active"]), let value = try? JSONDecoder().decode(Active.self, from: data) else { return false }
        guard generation == selectionGeneration else { return false }
        activeIDs = [.claude: value.accountID, .codex: value.codexAccountID].compactMapValues { $0 }
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
        guard config.smartMode else { return }
        let now = Date().timeIntervalSince1970
        // Codex: the desktop app keeps its own copy of the login, and OpenAI revokes a login
        // whose refresh token is used twice, so Codex is never switched automatically.
        for provider in [AgentProvider.claude] where unknownLogins[provider] == nil && shellSwitching {
            let accounts = config.accounts.filter { $0.provider == provider }
            let current = activeIDs[provider]
            // A failed read is not evidence of a limit; only a signed-out active account moves.
            if let current, failing.contains(current), usage[current]?.stale != true { continue }
            // An account with Autopilot off is never switched away from automatically.
            if let current, config.accounts.first(where: { $0.id == current })?.allowAuto == false { continue }
            if let best = Planner.best(accounts, usage: plannable, active: current, now: now), best != current {
                let from = config.accounts.first { $0.id == current }?.name
                await activate(best)
                if activeIDs[provider] == best, let name = config.accounts.first(where: { $0.id == best })?.name {
                    notify("Switched to \(name)", from.map { "\($0) is near its limit or has less quota at risk." } ?? "Autopilot picked the account with the most quota at risk.")
                }
            }
            if provider == .claude, let next = Planner.nextAvailable(accounts, usage: plannable, now: now), Planner.best(accounts, usage: plannable, active: nil, now: now) == nil {
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
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Account verification failed."
                throw BridgeFailure(message: message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return data
        }.value
    }
}
