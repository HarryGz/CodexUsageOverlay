import Foundation

/// Merges independently refreshed account and context snapshots.
@MainActor
public final class UsageStore {
    public private(set) var snapshot: CombinedUsageSnapshot
    public var onChange: ((CombinedUsageSnapshot) -> Void)?

    public init() {
        snapshot = CombinedUsageSnapshot(
            account: .unavailable(reason: "Unknown"),
            context: .unavailable(reason: "Unknown")
        )
    }

    public func updateAccount(_ value: AccountUsageSnapshot) {
        replace(CombinedUsageSnapshot(account: .live(value), context: snapshot.context))
    }

    public func failAccount(_ reason: String, now: Date = Date()) {
        let next: UsageValueState<AccountUsageSnapshot>
        switch snapshot.account {
        case .live(let value) where now.timeIntervalSince(value.updatedAt) <= 300:
            next = .live(value)
        case .live(let value), .stale(let value, _):
            next = .stale(value, reason: reason)
        case .unavailable:
            next = .unavailable(reason: reason)
        }
        replace(CombinedUsageSnapshot(account: next, context: snapshot.context))
    }

    public func updateContext(_ value: ContextUsageSnapshot) {
        replace(CombinedUsageSnapshot(account: snapshot.account, context: .live(value)))
    }

    public func failContext(_ reason: String) {
        replace(CombinedUsageSnapshot(account: snapshot.account, context: failure(from: snapshot.context, reason: reason)))
    }

    /// Identity/provenance changes and compaction make the prior value unusable.
    public func invalidateContext(_ reason: String) {
        replace(CombinedUsageSnapshot(account: snapshot.account, context: .unavailable(reason: reason)))
    }

    public func refreshStaleness(now: Date = Date()) {
        replace(CombinedUsageSnapshot(
            account: staleIfNeeded(snapshot.account, now: now),
            context: staleIfNeeded(snapshot.context, now: now)
        ))
    }

    private func failure<Value: Equatable & Sendable>(from state: UsageValueState<Value>, reason: String) -> UsageValueState<Value> {
        switch state {
        case .live(let value), .stale(let value, _): return .stale(value, reason: reason)
        case .unavailable: return .unavailable(reason: reason)
        }
    }

    private func staleIfNeeded(_ state: UsageValueState<AccountUsageSnapshot>, now: Date) -> UsageValueState<AccountUsageSnapshot> {
        guard case .live(let value) = state, now.timeIntervalSince(value.updatedAt) > 300 else { return state }
        return .stale(value, reason: "Snapshot is older than five minutes.")
    }

    private func staleIfNeeded(_ state: UsageValueState<ContextUsageSnapshot>, now: Date) -> UsageValueState<ContextUsageSnapshot> {
        guard case .live(let value) = state, now.timeIntervalSince(value.updatedAt) > 300 else { return state }
        return .stale(value, reason: "Snapshot is older than five minutes.")
    }

    private func replace(_ next: CombinedUsageSnapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onChange?(next)
    }
}
