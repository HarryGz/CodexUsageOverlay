import Foundation

/// Normalizes account quota responses and sparse rate-limit notifications.
public enum AccountUsageParser {
    public static func parse(
        message: [String: Any],
        mergingWith previous: AccountUsageSnapshot?,
        now: Date = Date()
    ) -> AccountUsageSnapshot? {
        guard let payload = quotaPayload(in: message) else { return nil }

        let names = ["primary", "secondary"]
        var windows = previous?.windows ?? []
        var consumed = Set<Int>()
        var parsedAny = false

        for (position, name) in names.enumerated() {
            guard let raw = payload[name] as? [String: Any] else { continue }
            let duration: Int?
            if let rawDuration = raw["windowDurationMins"] {
                guard let numericDuration = number(rawDuration), let validDuration = validDuration(numericDuration) else { continue }
                duration = validDuration
            } else {
                duration = nil
            }
            let match = matchingIndex(duration: duration, position: position, windows: windows, consumed: consumed)
            if let match { consumed.insert(match) }
            let old = match.map { windows[$0] }

            let used: Double
            if let value = raw["usedPercent"] {
                guard let numeric = number(value), numeric.isFinite else { continue }
                used = numeric
            } else if let old {
                used = old.usedPercent
            } else {
                continue
            }
            let resetDate: Date?
            if let reset = raw["resetsAt"] {
                resetDate = number(reset).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            } else {
                resetDate = old?.resetsAt
            }
            let window = QuotaWindow(usedPercent: used, durationMinutes: duration ?? old?.durationMinutes, resetsAt: resetDate)
            if let match { windows[match] = window } else { windows.append(window) }
            parsedAny = true
        }

        guard parsedAny || (previous != nil && !windows.isEmpty) else { return nil }
        windows.sort { left, right in
            switch (left.durationMinutes, right.durationMinutes) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return false
            }
        }
        let plan = (payload["planType"] as? String) ?? previous?.planType
        return AccountUsageSnapshot(windows: windows, planType: plan, updatedAt: now)
    }

    private static func quotaPayload(in message: [String: Any]) -> [String: Any]? {
        for key in ["result", "params"] {
            guard let container = message[key] as? [String: Any] else { continue }
            if let byID = container["rateLimitsByLimitId"] as? [String: Any],
               let codex = byID["codex"] as? [String: Any] { return codex }
            if let limits = container["rateLimits"] as? [String: Any] { return limits }
        }
        return nil
    }

    private static func number(_ value: Any) -> Double? {
        guard !(value is Bool), let value = value as? NSNumber else { return nil }
        return value.doubleValue
    }

    private static func validDuration(_ value: Double) -> Int? {
        guard value.isFinite, value > 0, value.rounded() == value,
              value < Double(Int.max), value >= Double(Int.min) else { return nil }
        return Int(value)
    }

    private static func matchingIndex(duration: Int?, position: Int, windows: [QuotaWindow], consumed: Set<Int>) -> Int? {
        if let duration, let index = windows.indices.first(where: { !consumed.contains($0) && windows[$0].durationMinutes == duration }) {
            return index
        }
        if position < windows.count, !consumed.contains(position) { return position }
        return nil
    }
}
