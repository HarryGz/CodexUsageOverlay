import Foundation

public struct QuotaWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Double, durationMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
}

public enum SnapshotProvenance: Equatable, Sendable {
    case appServer
    case selectedThread
    case fallbackThread
}

public struct ContextUsageSnapshot: Equatable, Sendable {
    public let threadID: String
    public let usedTokens: Int64?
    public let windowTokens: Int64?
    public let updatedAt: Date
    public let provenance: SnapshotProvenance

    public init(threadID: String, usedTokens: Int64?, windowTokens: Int64?, updatedAt: Date, provenance: SnapshotProvenance) {
        self.threadID = threadID
        self.usedTokens = usedTokens
        self.windowTokens = windowTokens
        self.updatedAt = updatedAt
        self.provenance = provenance
    }

    public var remainingTokens: Int64? {
        guard let usedTokens, let windowTokens, windowTokens > 0 else { return nil }
        return max(0, windowTokens - max(0, usedTokens))
    }

    public var remainingPercent: Double? {
        guard let remainingTokens, let windowTokens, windowTokens > 0 else { return nil }
        return Double(remainingTokens) / Double(windowTokens) * 100
    }
}

public struct AccountUsageSnapshot: Equatable, Sendable {
    public let windows: [QuotaWindow]
    public let planType: String?
    public let updatedAt: Date

    public init(windows: [QuotaWindow], planType: String?, updatedAt: Date) {
        self.windows = windows
        self.planType = planType
        self.updatedAt = updatedAt
    }
}

public enum UsageValueState<Value: Equatable & Sendable>: Equatable, Sendable {
    case unavailable(reason: String)
    case live(Value)
    case stale(Value, reason: String)
}

public struct CombinedUsageSnapshot: Equatable, Sendable {
    public let account: UsageValueState<AccountUsageSnapshot>
    public let context: UsageValueState<ContextUsageSnapshot>

    public init(account: UsageValueState<AccountUsageSnapshot>, context: UsageValueState<ContextUsageSnapshot>) {
        self.account = account
        self.context = context
    }
}

public enum CapacityColor: Equatable, Sendable {
    case healthy
    case warning
    case critical
    case unavailable

    public static func classify(remainingPercent: Double?) -> Self {
        guard let value = remainingPercent else { return .unavailable }
        if value > 50 { return .healthy }
        if value >= 20 { return .warning }
        return .critical
    }
}

public struct CompactUsageSegment: Equatable, Sendable {
    public let text: String
    public let color: CapacityColor
}

public struct UsageDetailRow: Equatable, Sendable {
    public enum Section: Equatable, Sendable { case account, context }
    public let section: Section
    public let label: String
    public let value: String
    public let color: CapacityColor
}

/// Locale-independent display strings; never invents absent quota windows.
public enum DisplayFormatter {
    public static func durationLabel(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "额度" }
        if minutes == 10_080 { return "周" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)h" }
        return "\(minutes)分"
    }

    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(min(100, max(0, value)).rounded()))%"
    }

    public static func tokens(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        guard value >= 1_000 else { return String(value) }
        let formatted = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(value) / 1_000)
        return (formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted) + "k"
    }

    public static func resetCountdown(_ reset: Date?, now: Date) -> String {
        guard let reset else { return "—" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds.isFinite else { return "—" }
        guard seconds > 0 else { return "即将重置" }
        let minutes = Int(min(ceil(seconds / 60), Double(Int.max / 2)))
        let days = minutes / 1_440, hours = minutes % 1_440 / 60, remainder = minutes % 60
        return (days > 0 ? "\(days)天" : "") + (hours > 0 ? "\(hours)小时" : "") +
            (remainder > 0 ? "\(remainder)分" : "")
    }

    public static func compactSegments(snapshot: CombinedUsageSnapshot, now: Date) -> [CompactUsageSegment] {
        let account = unpack(snapshot.account, now: now, date: { $0.updatedAt })
        var segments = account.value.map { value in
            ordered(value.windows).map { window in
                CompactUsageSegment(text: "\(durationLabel(window.durationMinutes)) \(percent(window.remainingPercent))" + staleSuffix(account.reason),
                                    color: color(window.remainingPercent, stale: account.reason != nil))
            }
        } ?? [CompactUsageSegment(text: "额度 —", color: .unavailable)]
        let context = unpack(snapshot.context, now: now, date: { $0.updatedAt })
        let fallback = context.value?.provenance == .fallbackThread ? "（可能非当前任务）" : ""
        segments.append(CompactUsageSegment(text: "上下文 \(percent(context.value?.remainingPercent))" + staleSuffix(context.value == nil ? nil : context.reason) + fallback,
                                            color: color(context.value?.remainingPercent, stale: context.reason != nil)))
        return segments
    }

    public static func detailRows(snapshot: CombinedUsageSnapshot, now: Date) -> [UsageDetailRow] {
        var rows: [UsageDetailRow] = []
        func add(_ section: UsageDetailRow.Section, _ label: String, _ value: String, _ color: CapacityColor = .unavailable) {
            rows.append(UsageDetailRow(section: section, label: label, value: value, color: color))
        }
        let account = unpack(snapshot.account, now: now, date: { $0.updatedAt })
        if let value = account.value {
            if let plan = value.planType { add(.account, "方案", plan) }
            if value.windows.isEmpty { add(.account, "额度", "—") }
            for window in ordered(value.windows) {
                let label = durationLabel(window.durationMinutes)
                add(.account, label + " 剩余", percent(window.remainingPercent), color(window.remainingPercent, stale: account.reason != nil))
                add(.account, label + " 重置", resetCountdown(window.resetsAt, now: now))
            }
        }
        if let reason = account.reason { add(.account, "状态", account.value == nil ? reason : "已过期：" + reason) }
        let context = unpack(snapshot.context, now: now, date: { $0.updatedAt })
        if let value = context.value {
            add(.context, "任务", String(value.threadID.suffix(8)))
            add(.context, "剩余", percent(value.remainingPercent), color(value.remainingPercent, stale: context.reason != nil))
            add(.context, "剩余 tokens", "\(tokens(value.remainingTokens)) / \(tokens(value.windowTokens))")
            if value.provenance == .fallbackThread { add(.context, "来源", "可能非当前任务") }
        } else { add(.context, "剩余", "—") }
        if let reason = context.reason { add(.context, "状态", context.value == nil ? reason : "已过期：" + reason) }
        return rows
    }

    private static func ordered(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        windows.enumerated().sorted {
            let left = $0.element.durationMinutes ?? Int.max
            let right = $1.element.durationMinutes ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    private static func color(_ remaining: Double?, stale: Bool) -> CapacityColor {
        guard !stale, let remaining, remaining.isFinite else { return .unavailable }
        return .classify(remainingPercent: remaining)
    }

    private static func staleSuffix(_ reason: String?) -> String { reason == nil ? "" : "（已过期）" }

    private static func unpack<Value>(_ state: UsageValueState<Value>, now: Date,
                                      date: (Value) -> Date) -> (value: Value?, reason: String?) {
        switch state {
        case .unavailable(let reason): return (nil, reason)
        case .stale(let value, let reason): return (value, reason)
        case .live(let value):
            return (value, now.timeIntervalSince(date(value)) > 300 ? "超过五分钟未更新" : nil)
        }
    }
}
