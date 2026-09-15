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
