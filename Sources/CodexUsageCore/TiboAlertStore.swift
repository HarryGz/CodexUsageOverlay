import Foundation

@MainActor
public final class TiboAlertStore {
    public static let stateKey = "tiboAlertState.v1"
    public static let permissionRequestedKey = "tiboNotificationPermissionRequested"

    public private(set) var snapshot: TiboAlertSnapshot
    public var onChange: ((TiboAlertSnapshot) -> Void)?

    private let defaults: UserDefaults
    private var seenIDs: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = Self.loadState(from: defaults)
        snapshot = loaded?.snapshot ?? TiboAlertSnapshot()
        snapshot.notificationPermissionRequested = defaults.bool(forKey: Self.permissionRequestedKey)
        seenIDs = loaded?.seenIDs ?? []
    }

    @discardableResult
    public func accept(_ message: TiboMessage, checkedAt: Date) -> Bool {
        guard Self.valid(message), Self.finite(checkedAt) else { return false }

        if seenIDs.contains(message.id) {
            guard var latest = snapshot.latest,
                  latest.id == message.id,
                  latest.verification != .anomalous else { return false }
            latest.category = message.category
            latest.localizedSummary = message.localizedSummary
            latest.canonicalURL = message.canonicalURL
            mutate {
                $0.latest = latest
            }
            return false
        }

        seenIDs.append(message.id)
        if seenIDs.count > TiboAlertLimits.maximumSeenIDs {
            seenIDs.removeFirst(seenIDs.count - TiboAlertLimits.maximumSeenIDs)
        }
        let record = TiboAlertRecord(
            message: message,
            verification: .pending,
            verificationUpdatedAt: checkedAt
        )
        mutate {
            $0.latest = record
            $0.unread = true
            $0.pendingRevealID = nil
        }
        return true
    }

    public func updateHealth(_ health: TiboFeedHealth) {
        guard Self.valid(health) else { return }
        mutate { $0.health = health }
    }

    public func markConfirmed(id: String) {
        guard var latest = snapshot.latest,
              latest.id == id,
              latest.verification == .pending else { return }
        latest.verification = .confirmed
        latest.verificationUpdatedAt = Date()
        mutate { $0.latest = latest }
    }

    public func markAnomalous(id: String, at: Date) {
        guard at.timeIntervalSinceReferenceDate.isFinite,
              var latest = snapshot.latest,
              latest.id == id,
              latest.verification != .anomalous else { return }
        latest.category = nil
        latest.localizedSummary = nil
        latest.canonicalURL = nil
        latest.verification = .anomalous
        latest.verificationUpdatedAt = at
        mutate {
            $0.latest = latest
            $0.unread = false
            if $0.pendingRevealID == id { $0.pendingRevealID = nil }
        }
    }

    public func markRead() {
        mutate { $0.unread = false }
    }

    public func requestReveal(id: String) {
        guard snapshot.latest?.id == id,
              snapshot.latest?.verification != .anomalous else { return }
        mutate { $0.pendingRevealID = id }
    }

    @discardableResult
    public func consumePendingReveal(for id: String) -> Bool {
        guard snapshot.pendingRevealID == id else { return false }
        mutate { $0.pendingRevealID = nil }
        return true
    }

    public func setNotificationPermissionRequested() {
        guard !snapshot.notificationPermissionRequested else { return }
        defaults.set(true, forKey: Self.permissionRequestedKey)
        mutate { $0.notificationPermissionRequested = true }
    }

    private func mutate(_ update: (inout TiboAlertSnapshot) -> Void) {
        let previous = snapshot
        update(&snapshot)
        guard snapshot != previous else { return }
        persist()
        onChange?(snapshot)
    }

    private func persist() {
        let state = PersistentState(version: 1, snapshot: snapshot, seenIDs: seenIDs)
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }

    private static func loadState(from defaults: UserDefaults) -> PersistentState? {
        guard let data = defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(PersistentState.self, from: data),
              state.version == 1,
              state.seenIDs.count <= TiboAlertLimits.maximumSeenIDs,
              Set(state.seenIDs).count == state.seenIDs.count,
              state.seenIDs.allSatisfy(validStatusID),
              valid(state.snapshot) else {
            return nil
        }
        return state
    }

    private static func valid(_ snapshot: TiboAlertSnapshot) -> Bool {
        guard valid(snapshot.health) else { return false }
        if snapshot.unread && snapshot.latest == nil { return false }
        if let pending = snapshot.pendingRevealID, pending != snapshot.latest?.id { return false }
        guard let latest = snapshot.latest else {
            return !snapshot.unread && snapshot.pendingRevealID == nil
        }
        guard validStatusID(latest.id), finite(latest.publishedAt) else { return false }
        if let updatedAt = latest.verificationUpdatedAt, !finite(updatedAt) { return false }

        switch latest.verification {
        case .anomalous:
            return latest.category == nil && latest.localizedSummary == nil && latest.canonicalURL == nil
        case .pending, .confirmed:
            guard latest.category != nil,
                  let summary = latest.localizedSummary,
                  validSummary(summary),
                  latest.canonicalURL?.absoluteString == "https://x.com/thsottiaux/status/\(latest.id)" else { return false }
            return true
        }
    }

    private static func valid(_ message: TiboMessage) -> Bool {
        validStatusID(message.id)
            && finite(message.publishedAt)
            && validSummary(message.localizedSummary)
            && message.canonicalURL.absoluteString == "https://x.com/thsottiaux/status/\(message.id)"
    }

    private static func valid(_ health: TiboFeedHealth) -> Bool {
        switch health {
        case .neverChecked:
            return true
        case let .healthy(checkedAt, fetchedAt):
            return finite(checkedAt) && finite(fetchedAt)
        case let .stale(checkedAt), let .unavailable(checkedAt):
            return finite(checkedAt)
        }
    }

    private static func validSummary(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.count <= TiboAlertLimits.summaryScalars
            && value.split(separator: "\n", omittingEmptySubsequences: false).count <= TiboAlertLimits.summaryLines
    }

    private static func validStatusID(_ id: String) -> Bool {
        let scalars = id.unicodeScalars
        guard scalars.count >= TiboAlertLimits.minimumStatusIDLength,
              scalars.count <= TiboAlertLimits.maximumStatusIDLength else { return false }
        return scalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    private static func finite(_ date: Date) -> Bool {
        let timestamp = date.timeIntervalSince1970
        return timestamp.isFinite
            && timestamp >= TiboAlertLimits.earliestSupportedTimestamp
            && timestamp <= TiboAlertLimits.latestSupportedTimestamp
    }
}

private struct PersistentState: Codable {
    let version: Int
    let snapshot: TiboAlertSnapshot
    let seenIDs: [String]
}
