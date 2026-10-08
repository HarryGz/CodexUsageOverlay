import Foundation

public struct TiboDetailPresentation: Equatable, Sendable {
    public let categoryLabel: String?
    public let summary: String?
    public let publishedText: String
    public let verificationLabel: String
    public let postURL: URL?
    public let attributionLabel: String
    public let attributionURL: URL
    public let healthText: String

    public init(
        categoryLabel: String?,
        summary: String?,
        publishedText: String,
        verificationLabel: String,
        postURL: URL?,
        attributionLabel: String,
        attributionURL: URL,
        healthText: String
    ) {
        self.categoryLabel = categoryLabel
        self.summary = summary
        self.publishedText = publishedText
        self.verificationLabel = verificationLabel
        self.postURL = postURL
        self.attributionLabel = attributionLabel
        self.attributionURL = attributionURL
        self.healthText = healthText
    }
}

public enum TiboDisplayFormatter {
    public static func detail(
        snapshot: TiboAlertSnapshot,
        now: Date = Date(),
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!
    ) -> TiboDetailPresentation? {
        guard let record = snapshot.latest else { return nil }
        let anomalous = record.verification == .anomalous
        return TiboDetailPresentation(
            categoryLabel: anomalous ? nil : record.category.map(categoryLabel),
            summary: anomalous ? nil : record.localizedSummary,
            publishedText: format(record.publishedAt, pattern: "yyyy-MM-dd HH:mm", timeZone: timeZone),
            verificationLabel: verificationLabel(record.verification),
            postURL: anomalous ? nil : record.canonicalURL,
            attributionLabel: "Data: codex-reset.com",
            attributionURL: URL(string: "https://codex-reset.com/")!,
            healthText: healthText(snapshot.health, now: now, timeZone: timeZone)
        )
    }

    private static func categoryLabel(_ category: TiboMessageCategory) -> String {
        switch category {
        case .resetAnnouncement: return "重置预告"
        case .resetCompleted: return "已完成"
        case .bankedReset: return "备用重置"
        case .strongHint: return "强烈暗示"
        }
    }

    private static func verificationLabel(_ state: TiboVerificationState) -> String {
        switch state {
        case .pending: return "… 等待 X 确认"
        case .confirmed: return "✓ X 已确认"
        case .anomalous: return "⚠ 来源异常"
        }
    }

    private static func healthText(_ health: TiboFeedHealth, now: Date, timeZone: TimeZone) -> String {
        switch health {
        case .neverChecked:
            return "尚未检查数据源"
        case let .healthy(checkedAt, _):
            return "最近检查：\(relativeAge(checkedAt, now: now))（\(format(checkedAt, pattern: "HH:mm", timeZone: timeZone))）"
        case let .stale(checkedAt):
            return "数据源已过期 · 最近检查：\(relativeAge(checkedAt, now: now))"
        case let .unavailable(checkedAt):
            return "数据源暂不可用 · 最近检查：\(relativeAge(checkedAt, now: now))"
        }
    }

    private static func relativeAge(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3_600) 小时前"
    }

    private static func format(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
