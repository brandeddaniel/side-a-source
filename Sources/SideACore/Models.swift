import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "Codex" }
    public var cliName: String { self == .claude ? "Claude Code" : "Codex CLI" }
    public var setupURL: URL {
        URL(string: self == .claude ? "https://code.claude.com/docs/en/setup" : "https://developers.openai.com/codex/cli")!
    }
}

public struct Account: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var email: String
    public var ready: Bool
    public var allowAuto: Bool
    public var provider: AgentProvider

    public init(id: String = UUID().uuidString.lowercased(), name: String, email: String = "",
                ready: Bool = false, allowAuto: Bool = false, provider: AgentProvider = .claude) {
        self.id = id; self.name = name; self.email = email
        self.ready = ready; self.allowAuto = allowAuto; self.provider = provider
    }
    private enum CodingKeys: String, CodingKey { case id, name, email, ready, allowAuto, provider }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        email = try values.decode(String.self, forKey: .email)
        ready = try values.decode(Bool.self, forKey: .ready)
        allowAuto = try values.decode(Bool.self, forKey: .allowAuto)
        // Existing v1 libraries contain Claude profiles. Never reassign their identity.
        provider = try values.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .claude
    }
}

public struct Configuration: Codable, Equatable, Sendable {
    public var version = 2
    public var accounts: [Account] = []
    public var selectedID: String?
    /// Autopilot: switch the Mac-wide account and start idle 5-hour windows.
    public var smartMode = true
    public var menuBarOnly = true
    public init() {}

    public var selected: Account? { accounts.first { $0.id == selectedID } }
    public mutating func step(_ offset: Int) {
        guard !accounts.isEmpty else { selectedID = nil; return }
        let current = accounts.firstIndex { $0.id == selectedID } ?? 0
        selectedID = accounts[((current + offset) % accounts.count + accounts.count) % accounts.count].id
    }
    public func validated() throws -> Configuration {
        guard version == 1 || version == 2 else { throw StorageError.unsupportedVersion }
        guard Set(accounts.map(\.id)).count == accounts.count,
              accounts.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              selectedID == nil || accounts.contains(where: { $0.id == selectedID }) else {
            throw StorageError.invalidConfiguration
        }
        var migrated = self
        // Prevent older releases from decoding Codex profiles as Claude and
        // overwriting their provider discriminator when saving the library.
        migrated.version = 2
        return migrated
    }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var percent: Double
    public var resetsAt: Double?
    public init(id: String, label: String, percent: Double, resetsAt: Double?) {
        self.id = id; self.label = label; self.percent = percent; self.resetsAt = resetsAt
    }
}

public struct AccountUsage: Codable, Equatable, Sendable {
    public var windows: [UsageWindow]
    public var stale: Bool
    /// Relative plan size (Pro 1, Max 5x 5, Max 20x 20). Missing means unknown, treated as 1.
    public var capacity: Double?
    public init(windows: [UsageWindow], stale: Bool = false, capacity: Double? = nil) {
        self.windows = windows; self.stale = stale; self.capacity = capacity
    }
    public var fiveHour: UsageWindow? { windows.first { $0.id == "five_hour" } }
    public var weekly: UsageWindow? { windows.first { $0.id == "seven_day" } }
    /// Fable's own weekly limit; when full it stops Fable sessions even with overall weekly room left.
    public var fable: UsageWindow? { windows.first { $0.id == "seven_day_model:fable" } }
    /// The overall weekly limit and every model-scoped weekly limit; any full one stops work.
    public var weeklyLimits: [UsageWindow] { windows.filter { $0.id == "seven_day" || $0.id.hasPrefix("seven_day_model:") } }
}

/// A running Claude Code session: the model of its latest reply and the account it runs on.
public struct LiveSession: Codable, Equatable, Sendable, Identifiable {
    public var pid: Int
    public var name: String?
    public var status: String?
    /// When the status last changed, in seconds since 1970.
    public var statusSince: Double?
    /// "cli" for a session in a terminal; "sdk-cli" for a headless `claude -p` job, which has no tab.
    public var entrypoint: String?
    /// Side A can type into it: it runs in a terminal tab.
    public var inTerminal: Bool { entrypoint == nil || entrypoint == "cli" }
    public var model: String?
    public var accountID: String?
    public var id: Int { pid }
    public var onFable: Bool { model?.localizedCaseInsensitiveContains("fable") == true }
    public init(pid: Int, name: String? = nil, status: String? = nil, statusSince: Double? = nil, model: String? = nil, accountID: String? = nil) {
        self.pid = pid; self.name = name; self.status = status; self.statusSince = statusSince; self.model = model; self.accountID = accountID
    }
    /// Waiting on the user, or "busy" far longer than a turn takes: on an account with no Fable
    /// left, that is Claude Code's Fable-limit prompt or a turn stuck retrying the limit.
    public func looksStuck(now: Double) -> Bool {
        status == "waiting" || (status == "busy" && now - (statusSince ?? now) > 600)
    }
}

public struct TokenRow: Codable, Equatable, Sendable {
    public var date: String?
    public var project: String?
    public var model: String?
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    public var total: Int { input + output + cacheWrite + cacheRead }
    public init(date: String? = nil, project: String? = nil, model: String? = nil, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
        self.date = date; self.project = project; self.model = model
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
}

public struct ActivitySpan: Codable, Equatable, Sendable {
    public var date: String
    /// Responses per local hour, 0 to 23.
    public var hours: [Int]
    public init(date: String, hours: [Int]) { self.date = date; self.hours = hours }
}

/// Local Claude Code token use, read from transcripts the way ccusage does.
public struct UsageReport: Codable, Equatable, Sendable {
    public var days: [TokenRow]
    public var projects: [TokenRow]
    public var models: [TokenRow]
    public var activity: [ActivitySpan]
    public init(days: [TokenRow], projects: [TokenRow], models: [TokenRow], activity: [ActivitySpan]) {
        self.days = days; self.projects = projects; self.models = models; self.activity = activity
    }
}

/// The user's usual working hours, learned from when transcripts show activity.
public struct WorkSchedule: Equatable, Sendable {
    /// Typical start and end of the working day, in minutes after local midnight.
    public var start: Int
    public var end: Int
    public static let lead = 120

    /// The day starts right after the longest quiet run of hours over the last 14 active days,
    /// so work that crosses midnight still counts as one day. Nil until a week of history
    /// exists, or when there is no quiet stretch of at least four hours (agents running all day).
    public init?(_ activity: [ActivitySpan]) {
        let recent = activity.suffix(14)
        guard recent.count >= 7 else { return nil }
        let totals = (0..<24).map { hour in recent.reduce(0) { $0 + ($1.hours.indices.contains(hour) ? $1.hours[hour] : 0) } }
        let quiet = totals.map { Double($0) <= Double(totals.max() ?? 0) * 0.2 }
        var best = (start: 0, length: 0)
        for first in 0..<24 where quiet[first] && !quiet[(first + 23) % 24] {
            var length = 0
            while length < 24, quiet[(first + length) % 24] { length += 1 }
            if length > best.length { best = (first, length) }
        }
        guard best.length >= 4, best.length < 24 else { return nil }
        start = (best.start + best.length) % 24 * 60
        end = best.start * 60
    }
    public init(start: Int, end: Int) { self.start = start; self.end = end }

    /// Priming starts two hours before the usual start, so the first window resets mid-session,
    /// and continues through the working day. Overnight windows would only lapse unused.
    public func allowsPriming(atMinute minute: Int) -> Bool {
        let from = (start - Self.lead + 1440) % 1440
        let span = (end - from + 1440) % 1440
        return (minute - from + 1440) % 1440 <= span
    }
}

/// Decides which account should hold the Mac-wide login, and which idle windows to start.
/// Weekly quota is what expires unused, so the account that must burn quota fastest
/// before its weekly reset goes first; among near-ties, the 5-hour window that resets
/// soonest is used before it refills.
public enum Planner {
    public static let full = 97.0
    public static let switchTarget = 90.0
    static let week = 7 * 24 * 3600.0

    static func live(_ window: UsageWindow?, _ now: Double) -> UsageWindow? {
        guard let window, let reset = window.resetsAt, reset > now else { return nil }
        return window
    }

    /// The fullest live weekly limit, overall or model-scoped (or overall only).
    static func tightestWeekly(_ usage: AccountUsage, _ now: Double, ignoringModelLimits: Bool = false) -> UsageWindow? {
        (ignoringModelLimits ? [usage.weekly].compactMap { $0 } : usage.weeklyLimits)
            .compactMap { live($0, now) }.max { $0.percent < $1.percent }
    }

    public static func hasHeadroom(_ usage: AccountUsage, now: Double, ignoringModelLimits: Bool = false) -> Bool {
        (live(usage.fiveHour, now)?.percent ?? 0) < full
            && (tightestWeekly(usage, now, ignoringModelLimits: ignoringModelLimits)?.percent ?? 0) < full
    }

    /// A running session should leave this account between turns: a limit it depends on (5-hour,
    /// weekly, and Fable's own weekly for a Fable session) has reached the switch target.
    public static func shouldLeave(_ usage: AccountUsage, onFable: Bool, now: Double) -> Bool {
        let limits = [usage.fiveHour, usage.weekly] + (onFable ? [usage.fable] : [])
        return limits.contains { (live($0, now)?.percent ?? 0) >= switchTarget }
    }

    /// A session on this account cannot run: a limit it depends on is spent.
    public static func isSpent(_ usage: AccountUsage, onFable: Bool, now: Double) -> Bool {
        let limits = [usage.fiveHour, usage.weekly] + (onFable ? [usage.fable] : [])
        return limits.contains { (live($0, now)?.percent ?? 0) >= full }
    }

    /// Fable first: an account with Fable room left. Only when every Fable limit is spent does it
    /// pick by the overall limits, and `fableSpent` tells the caller to send Fable to Opus.
    public static func pick(_ candidates: [Account], usage: [String: AccountUsage], active: String?, now: Double) -> (id: String?, fableSpent: Bool) {
        if let id = best(candidates, usage: usage, active: active, now: now) { return (id, false) }
        let id = best(candidates, usage: usage, active: active, now: now, ignoringModelLimits: true)
        return (id, id != nil)
    }

    /// Weekly quota (in Pro-plan percent) that must be used per hour to avoid losing it at reset.
    public static func urgency(_ usage: AccountUsage, now: Double) -> Double {
        let weekly = live(usage.weekly, now)
        let remaining = 100 - (weekly?.percent ?? 0)
        let hours = max(((weekly?.resetsAt ?? now + week) - now) / 3600, 1)
        return remaining / hours * (usage.capacity ?? 1)
    }

    /// Earliest moment any account regains headroom, for when every account is limited.
    public static func nextAvailable(_ candidates: [Account], usage: [String: AccountUsage], now: Double) -> (Account, Double)? {
        candidates.filter { $0.ready }.compactMap { account -> (Account, Double)? in
            guard let value = usage[account.id] else { return nil }
            // Same bars as switching: a 5-hour window counts as blocked from the switch target.
            let blocking = [live(value.fiveHour, now).flatMap { $0.percent >= switchTarget ? $0 : nil }].compactMap { $0 }
                + value.weeklyLimits.compactMap { live($0, now) }.filter { $0.percent >= full }
            guard let reset = blocking.compactMap(\.resetsAt).max() else { return nil }
            return (account, reset)
        }.min { $0.1 < $1.1 }
    }

    /// Minutes until a window reaches the limit at the observed pace, from (time, percent) samples.
    public static func minutesToLimit(_ samples: [(Double, Double)]) -> Double? {
        guard let first = samples.first, let last = samples.last, last.0 - first.0 >= 300,
              last.1 > first.1, last.1 < full else { return nil }
        let perMinute = (last.1 - first.1) / ((last.0 - first.0) / 60)
        return (full - last.1) / perMinute
    }

    public static func best(_ candidates: [Account], usage: [String: AccountUsage], active: String?, now: Double,
                            ignoringModelLimits: Bool = false) -> String? {
        let eligible = candidates.filter { account in
            guard account.ready, account.allowAuto, let value = usage[account.id], !value.stale else { return false }
            // Only move to an account with real room; the active one may run up to the limit.
            // A new pick also needs room below the switch target, so sessions are not sent to an account about to run out.
            return hasHeadroom(value, now: now, ignoringModelLimits: ignoringModelLimits) && (account.id == active
                || ((live(value.fiveHour, now)?.percent ?? 0) < switchTarget
                    && (tightestWeekly(value, now, ignoringModelLimits: ignoringModelLimits)?.percent ?? 0) < switchTarget))
        }
        guard let top = eligible.map({ urgency(usage[$0.id]!, now: now) }).max() else { return nil }
        let pick = eligible.filter { urgency(usage[$0.id]!, now: now) >= top * 0.75 }
            .min { (live(usage[$0.id]!.fiveHour, now)?.resetsAt ?? .infinity) < (live(usage[$1.id]!.fiveHour, now)?.resetsAt ?? .infinity) }
        // Hysteresis: keep a usable active account unless the pick is clearly more urgent.
        if let active, let current = eligible.first(where: { $0.id == active }), let pick, pick.id != active,
           urgency(usage[pick.id]!, now: now) < urgency(usage[current.id]!, now: now) * 1.5 {
            return active
        }
        return pick?.id
    }

    /// A 5-hour window only starts on the first message; starting it early makes it reset early.
    public static func shouldPrime(_ account: Account, usage: AccountUsage?, now: Double) -> Bool {
        guard account.ready, account.allowAuto, let usage, !usage.stale else { return false }
        // A plan with no 5-hour window has nothing to start.
        guard account.provider == .claude || usage.fiveHour != nil else { return false }
        return live(usage.fiveHour, now) == nil && (tightestWeekly(usage, now)?.percent ?? 0) < full
    }
}

public enum StorageError: LocalizedError {
    case unsupportedVersion, invalidConfiguration
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This library was saved by a newer version of Side A. Update the app to open it."
        case .invalidConfiguration: "The account library could not be read safely. Your saved file has been left untouched."
        }
    }
}

public enum PrivateFile {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

public enum Shell {
    public static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
