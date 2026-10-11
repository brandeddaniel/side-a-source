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
    // The estimate counts down between readings, and stale readings give none.
    #expect(Planner.minutesToLimit([(0, 50), (600, 60)], now: 600 + 7 * 60) == 30)
    #expect(Planner.minutesToLimit([(0, 50), (600, 60)], now: 600 + 11 * 60) == nil)
    let blocked = [soon.id: usage(99, now + hour, 40, now + 24 * hour), full.id: usage(10, now + hour, 99, now + 3 * hour)]
    #expect(Planner.nextAvailable([soon, full], usage: blocked, now: now)?.0.id == soon.id)
    // A 5-hour window above the switch target blocks until it resets, even below the hard limit.
    let nearly = [soon.id: usage(93, now + 600, 40, now + 24 * hour), full.id: usage(10, now + hour, 99, now + 3 * hour)]
    #expect(Planner.nextAvailable([soon, full], usage: nearly, now: now)?.1 == now + 600)
}

@Test func fullFableWeeklyLimitBlocksLikeTheOverallWeeklyLimit() {
    let now = 1_000_000.0
    let window = { (id: String, percent: Double) in UsageWindow(id: id, label: id, percent: percent, resetsAt: now + 86_400) }
    let fableFull = AccountUsage(windows: [window("five_hour", 10), window("seven_day", 40), window("model:fable", 98)])
    let roomy = AccountUsage(windows: [window("five_hour", 10), window("seven_day", 60), window("model:fable", 30)])
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
    let spent = { (weekly: Double) in AccountUsage(windows: [window("five_hour", 10), window("seven_day", weekly), window("model:fable", 100)]) }
    let a = Account(name: "A", ready: true, allowAuto: true), b = Account(name: "B", ready: true, allowAuto: true)
    let c = Account(name: "C", ready: true, allowAuto: true)
    let roomy = AccountUsage(windows: [window("five_hour", 10), window("seven_day", 85), window("model:fable", 20)])
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

@Test func sessionLooksStuckWhenWaitingOrBusyFarTooLong() {
    let now = 1_000_000.0
    #expect(LiveSession(pid: 1, status: "waiting", statusSince: now - 700).looksStuck(now: now))
    // Review: a fresh permission prompt is not stuck, and Esc would deny it.
    #expect(!LiveSession(pid: 5, status: "waiting", statusSince: now - 5).looksStuck(now: now))
    #expect(LiveSession(pid: 2, status: "busy", statusSince: now - 3600).looksStuck(now: now))
    var waitingOnBackground = LiveSession(pid: 6, status: "busy", statusSince: now - 5400)
    waitingOnBackground.turnEnded = true
    #expect(!waitingOnBackground.looksStuck(now: now))
    var stillWriting = LiveSession(pid: 7, status: "busy", statusSince: now - 5400)
    stillWriting.lastActivity = now - 60
    #expect(!stillWriting.looksStuck(now: now))
    #expect(!LiveSession(pid: 3, status: "busy", statusSince: now - 700).looksStuck(now: now))
    #expect(!LiveSession(pid: 4, status: "idle", statusSince: now - 9000).looksStuck(now: now))
}

@Test func sessionsLeaveAt90PercentAndPicksNeedRoomBelowIt() {
    let now = 1_000_000.0
    let w = { (id: String, percent: Double) in UsageWindow(id: id, label: id, percent: percent, resetsAt: now + 86_400) }
    let fableNear = AccountUsage(windows: [w("five_hour", 10), w("seven_day", 40), w("model:fable", 92)])
    #expect(Planner.shouldLeave(fableNear, onFable: true, now: now))
    #expect(!Planner.shouldLeave(fableNear, onFable: false, now: now))
    #expect(!Planner.isSpent(fableNear, onFable: true, now: now))
    let weeklySpent = AccountUsage(windows: [w("five_hour", 60), w("seven_day", 100), w("model:fable", 28)])
    #expect(Planner.isSpent(weeklySpent, onFable: true, now: now) && Planner.isSpent(weeklySpent, onFable: false, now: now))
    #expect(Planner.isExhausted(weeklySpent, onFable: false, now: now))
    // 97-99% still works: never a reason to interrupt a turn.
    let nearly = AccountUsage(windows: [w("five_hour", 98), w("seven_day", 50)])
    #expect(Planner.isSpent(nearly, onFable: false, now: now) && !Planner.isExhausted(nearly, onFable: false, now: now))
    // A nearly spent account is never a new pick, though the active one may run on up to the limit.
    let a = Account(name: "A", ready: true, allowAuto: true), b = Account(name: "B", ready: true, allowAuto: true)
    let roomy = AccountUsage(windows: [w("five_hour", 10), w("seven_day", 95), w("model:fable", 20)])
    #expect(Planner.best([a, b], usage: [a.id: fableNear, b.id: roomy], active: nil, now: now) == nil)
    #expect(Planner.best([a, b], usage: [a.id: fableNear, b.id: roomy], active: a.id, now: now) == a.id)
}

@Test func aSessionsLimitErrorCountsUntilANewerReading() {
    let now = 1_000_000.0
    let stale = AccountUsage(windows: [UsageWindow(id: "five_hour", label: "", percent: 0, resetsAt: now + 9000),
                                       UsageWindow(id: "model:fable", label: "", percent: 53, resetsAt: now + 90_000)])
    let raised = Planner.withEvidence(stale, limit: "fable", at: now - 60, readAt: now - 900, now: now)
    #expect(raised.fable?.percent == 100 && Planner.isExhausted(raised, onFable: true, now: now))
    #expect(!Planner.isExhausted(raised, onFable: false, now: now))
    // A reading taken after the error wins.
    #expect(Planner.withEvidence(stale, limit: "fable", at: now - 900, readAt: now - 60, now: now).fable?.percent == 53)
    #expect(Planner.withEvidence(nil, limit: "session", at: now, readAt: 0, now: now).fiveHour?.percent == 100)
}

@Test func scheduleIgnoresLightOvernightAgentTraffic() {
    // A real 14-day histogram: overnight agents run at up to 13% of the peak.
    let hours = [1095, 1542, 1584, 1586, 2286, 457, 289, 287, 16888, 20207, 18177, 15070, 14568, 18778,
                 21247, 20781, 18890, 13652, 12336, 9746, 6467, 6917, 4080, 3143]
    let schedule = WorkSchedule(Array(repeating: ActivitySpan(date: "d", hours: hours), count: 14))!
    #expect(schedule.start == 480 && schedule.end == 1320)
}

@Test func fablePlanningSkipsSpentFableCapsAndPlansWithoutFable() {
    let now = Date().timeIntervalSince1970
    func usage(weekly: Double, fable: Double?, capacity: Double) -> AccountUsage {
        AccountUsage(windows: [UsageWindow(id: "five_hour", label: "5-hour", percent: 10, resetsAt: now + 3600),
                               UsageWindow(id: "seven_day", label: "Weekly", percent: weekly, resetsAt: now + 86_400)]
                     + (fable.map { [UsageWindow(id: "model:fable", label: "Weekly Fable", percent: $0, resetsAt: now + 86_400)] } ?? []),
                     capacity: capacity)
    }
    let spent = Account(name: "Spent", ready: true, allowAuto: true), room = Account(name: "Room", ready: true, allowAuto: true)
    let pro = Account(name: "Pro", ready: true, allowAuto: true), almost = Account(name: "Almost", ready: true, allowAuto: true)
    let all = [spent.id: usage(weekly: 40, fable: 100, capacity: 20), room.id: usage(weekly: 60, fable: 20, capacity: 5),
               pro.id: usage(weekly: 0, fable: nil, capacity: 1), almost.id: usage(weekly: 99, fable: 0, capacity: 20)]
    let accounts = [spent, room, pro, almost]
    // This fork treats a spent Fable cap as blocking, so even plain planning leaves it.
    #expect(Planner.best(accounts, usage: all, active: spent.id, now: now) != spent.id)
    // Weekly room caps Fable room: an account 99% through its week has almost no Fable left.
    #expect(all[almost.id]!.forFable!.weekly!.percent == 98)
    // A Max plan with no Fable cap listed yet still has its Fable share; a Pro plan has none.
    #expect(usage(weekly: 10, fable: nil, capacity: 20).forFable?.weekly?.percent == 0)
    #expect(all[pro.id]!.forFable == nil)
    #expect(Planner.best(accounts, usage: all.compactMapValues(\.forFable), active: spent.id, now: now) == room.id)
}

@Test func weekForecastFollowsAWeekdayRhythmNotAStraightLine() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    // Four weeks of weekday 9:00-17:00 work, nothing on weekends. 2026-09-07 is a Monday.
    let monday = try Date("2026-09-07T00:00:00Z", strategy: .iso8601).timeIntervalSince1970
    let activity = (0..<28).map { day -> ActivitySpan in
        let date = Date(timeIntervalSince1970: monday + Double(day) * 86_400)
        let weekend = [1, 7].contains(calendar.component(.weekday, from: date))
        return ActivitySpan(date: Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day().format(date),
                            hours: (0..<24).map { !weekend && (9..<17).contains($0) ? 10 : 0 })
    }
    let rhythm = try #require(WeekRhythm(activity, calendar: calendar))
    let reset = monday + 35 * 86_400  // the next Monday 00:00
    // Friday 17:00: the work week is over, so half the limit used means about half by the reset,
    // where a straight line would have projected 70%.
    let friday = reset - 7 * 86_400 + 4 * 86_400 + 17 * 3600
    let calm = try #require(WeekForecast(UsageWindow(id: "seven_day", label: "Weekly", percent: 50, resetsAt: reset), rhythm: rhythm, now: friday))
    #expect(calm.projected < 55 && calm.expectedNow > 0.9 && calm.runsOut == nil)
    // Wednesday 12:00 at 80% after 19 of 40 working hours: the last 20% lasts about 5 more working hours.
    let wednesday = reset - 7 * 86_400 + 2 * 86_400 + 12 * 3600
    let busy = try #require(WeekForecast(UsageWindow(id: "seven_day", label: "Weekly", percent: 80, resetsAt: reset), rhythm: rhythm, now: wednesday))
    let out = Date(timeIntervalSince1970: try #require(busy.runsOut))
    #expect(calendar.component(.weekday, from: out) == 4 && (16..<17).contains(calendar.component(.hour, from: out)))
}
