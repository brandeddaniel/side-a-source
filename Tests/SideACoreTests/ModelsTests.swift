import Foundation
import Testing
@testable import SideACore

@Test func rejectsDuplicateIdentityAndUnsupportedVersion() throws {
    let account = Account(name: "Personal")
    var config = Configuration()
    config.accounts = [account, account]
    #expect(throws: StorageError.self) { try config.validated() }
    config.accounts = [account]
    config.version = 3
    #expect(throws: StorageError.self) { try config.validated() }
}

@Test func rejectsTraversalAndDanglingSelection() {
    var config = Configuration()
    config.accounts = [Account(id: "../escape", name: "Wrong")]
    #expect(throws: StorageError.self) { try config.validated() }
    config.accounts = [Account(name: "Real")]
    config.selectedID = UUID().uuidString
    #expect(throws: StorageError.self) { try config.validated() }
}

@Test func persistsPrivateLibraryWithRestrictivePermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("config.json")
    var config = Configuration()
    config.accounts = [Account(name: "Personal")]
    config.selectedID = config.accounts[0].id
    try PrivateFile.write(config, to: path)
    #expect(try PrivateFile.read(Configuration.self, from: path) == config)
    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func oldClaudeProfilesKeepIdentityAndConsent() throws {
    let id = UUID().uuidString.lowercased()
    let data = Data("""
    {"id":"\(id)","name":"Personal","email":"person@example.com","ready":true,"allowAuto":true}
    """.utf8)
    let account = try JSONDecoder().decode(Account.self, from: data)
    #expect(account.provider == .claude)
    #expect(account.id == id && account.ready && account.allowAuto)
    #expect(account.email == "person@example.com")
}

@Test func codexProfileRoundTripsAndUnknownProvidersFailClosed() throws {
    let account = Account(name: "Work", ready: true, provider: .codex)
    let data = try JSONEncoder().encode(account)
    #expect(try JSONDecoder().decode(Account.self, from: data) == account)
    let unknown = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "codex", with: "unknown")
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Account.self, from: Data(unknown.utf8)) }
}

@Test func legacyLibraryPromotesSchemaWithoutChangingAccounts() throws {
    var legacy = Configuration()
    legacy.version = 1
    legacy.accounts = [Account(name: "Personal", email: "person@example.com", ready: true, allowAuto: true)]
    legacy.selectedID = legacy.accounts[0].id
    legacy.smartMode = true
    let migrated = try legacy.validated()
    #expect(migrated.version == 2)
    #expect(migrated.accounts == legacy.accounts)
    #expect(migrated.selectedID == legacy.selectedID && migrated.smartMode)
}

@Test func plannerBurnsExpiringQuotaFirstAndPrimesIdleWindows() {
    let now = 1_000_000.0, hour = 3600.0
    let soon = Account(name: "Soon", ready: true, allowAuto: true)
    let later = Account(name: "Later", ready: true, allowAuto: true)
    let full = Account(name: "Full", ready: true, allowAuto: true)
    func usage(_ five: Double?, _ fiveReset: Double?, _ week: Double, _ weekReset: Double) -> AccountUsage {
        AccountUsage(windows: [five.map { UsageWindow(id: "five_hour", label: "5-hour", percent: $0, resetsAt: fiveReset) },
                               UsageWindow(id: "seven_day", label: "Weekly", percent: week, resetsAt: weekReset)].compactMap { $0 })
    }
    var table = [soon.id: usage(10, now + 2 * hour, 40, now + 24 * hour),    // 60% left, 1 day to use it
                 later.id: usage(0, nil, 10, now + 6 * 24 * hour),            // 90% left, 6 days
                 full.id: usage(99, now + hour, 50, now + 24 * hour)]         // 5-hour limit hit
    let accounts = [later, soon, full]
    #expect(Planner.best(accounts, usage: table, active: full.id, now: now) == soon.id)
    // Hysteresis keeps a usable active account unless the pick is clearly more urgent.
    #expect(Planner.best(accounts, usage: table, active: later.id, now: now) == soon.id)
    table[soon.id] = usage(10, now + 2 * hour, 40, now + 6 * 24 * hour)
    #expect(Planner.best(accounts, usage: table, active: later.id, now: now) == later.id)
    // Never move to an account that is already close to its 5-hour limit.
    table[soon.id] = usage(93, now + 2 * hour, 40, now + 24 * hour)
    #expect(Planner.best([soon, full], usage: table, active: full.id, now: now) == nil)
    #expect(Planner.best([soon, full], usage: table, active: soon.id, now: now) == soon.id)
    table[soon.id] = usage(10, now + 2 * hour, 40, now + 6 * 24 * hour)
    // An expired window counts as not started.
    #expect(Planner.shouldPrime(later, usage: table[later.id], now: now))
    #expect(Planner.shouldPrime(soon, usage: usage(80, now - 1, 40, now + hour), now: now))
    #expect(!Planner.shouldPrime(soon, usage: table[soon.id], now: now))
    #expect(!Planner.shouldPrime(Account(name: "Off", ready: true), usage: table[later.id], now: now))
    // Review: a Codex plan with no 5-hour window was primed every 30 minutes forever.
    #expect(!Planner.shouldPrime(Account(name: "Codex", ready: true, allowAuto: true, provider: .codex), usage: usage(nil, nil, 10, now + hour), now: now))
    // A Max 20x account's remaining weekly quota outweighs a Pro account's.
    var big = table[later.id]!; big.capacity = 20
    #expect(Planner.urgency(big, now: now) > Planner.urgency(table[soon.id]!, now: now))
    // Forecast needs at least five minutes of rising samples.
    #expect(Planner.minutesToLimit([(0, 50), (600, 60)]) == 37)
    #expect(Planner.minutesToLimit([(0, 50), (120, 60)]) == nil)
    let blocked = [soon.id: usage(99, now + hour, 40, now + 24 * hour), full.id: usage(10, now + hour, 99, now + 3 * hour)]
    #expect(Planner.nextAvailable([soon, full], usage: blocked, now: now)?.0.id == soon.id)
    // A 5-hour window above the switch target blocks until it resets, even below the hard limit.
    let nearly = [soon.id: usage(93, now + 600, 40, now + 24 * hour), full.id: usage(10, now + hour, 99, now + 3 * hour)]
    #expect(Planner.nextAvailable([soon, full], usage: nearly, now: now)?.1 == now + 600)
}

@Test func fullFableWeeklyLimitBlocksLikeTheOverallWeeklyLimit() {
    let now = 1_000_000.0
    let window = { (id: String, percent: Double) in UsageWindow(id: id, label: id, percent: percent, resetsAt: now + 86_400) }
    let fableFull = AccountUsage(windows: [window("five_hour", 10), window("seven_day", 40), window("seven_day_model:fable", 98)])
    let roomy = AccountUsage(windows: [window("five_hour", 10), window("seven_day", 60), window("seven_day_model:fable", 30)])
    #expect(fableFull.fable?.percent == 98)
    #expect(!Planner.hasHeadroom(fableFull, now: now))
    #expect(Planner.hasHeadroom(roomy, now: now))
    let a = Account(name: "A", ready: true, allowAuto: true), b = Account(name: "B", ready: true, allowAuto: true)
    #expect(Planner.best([a, b], usage: [a.id: fableFull, b.id: roomy], active: a.id, now: now) == b.id)
    #expect(Planner.nextAvailable([a], usage: [a.id: fableFull], now: now)?.1 == now + 86_400)
}

@Test func plannerPrefersFableRoomAndOnlyThenFallsBackToOpus() {
    let now = 1_000_000.0
    let window = { (id: String, percent: Double) in UsageWindow(id: id, label: id, percent: percent, resetsAt: now + 86_400) }
    let spent = { (weekly: Double) in AccountUsage(windows: [window("five_hour", 10), window("seven_day", weekly), window("seven_day_model:fable", 100)]) }
    let a = Account(name: "A", ready: true, allowAuto: true), b = Account(name: "B", ready: true, allowAuto: true)
    let c = Account(name: "C", ready: true, allowAuto: true)
    let roomy = AccountUsage(windows: [window("five_hour", 10), window("seven_day", 90), window("seven_day_model:fable", 20)])
    // C has the least overall quota at risk, but it is the only one with Fable left.
    let first = Planner.pick([a, b, c], usage: [a.id: spent(10), b.id: spent(20), c.id: roomy], active: a.id, now: now)
    #expect(first.id == c.id && !first.fableSpent)
    // Fable spent everywhere: pick by overall limits (keeping a usable active account) and send Fable to Opus.
    let fallback = Planner.pick([a, b], usage: [a.id: spent(10), b.id: spent(20)], active: b.id, now: now)
    #expect(fallback.id == b.id && fallback.fableSpent)
    #expect(Planner.pick([a, b], usage: [a.id: spent(10), b.id: spent(20)], active: nil, now: now).id == a.id)
    // Everything spent: no pick and no Opus remap.
    let none = Planner.pick([a], usage: [a.id: spent(99)], active: a.id, now: now)
    #expect(none.id == nil && !none.fableSpent)
    #expect(LiveSession(pid: 1, model: "claude-fable-5-1").onFable && !LiveSession(pid: 2, model: "claude-opus-5-5").onFable)
}

@Test func scheduleIgnoresLightOvernightAgentTraffic() {
    // A real 14-day histogram: overnight agents run at up to 13% of the peak.
    let hours = [1095, 1542, 1584, 1586, 2286, 457, 289, 287, 16888, 20207, 18177, 15070, 14568, 18778,
                 21247, 20781, 18890, 13652, 12336, 9746, 6467, 6917, 4080, 3143]
    let schedule = WorkSchedule(Array(repeating: ActivitySpan(date: "d", hours: hours), count: 14))!
    #expect(schedule.start == 480 && schedule.end == 1320)
}
