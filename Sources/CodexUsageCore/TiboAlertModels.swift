import Foundation

public enum TiboAlertLimits {
    public static let feedResponseBytes = 1_048_576
    public static let oEmbedResponseBytes = 262_144
    public static let summaryScalars = 500
    public static let summaryLines = 6
    public static let minimumStatusIDLength = 1
    public static let maximumStatusIDLength = 32
    public static let maximumFeedAge: TimeInterval = 900
    public static let publicationFutureTolerance: TimeInterval = 300
    public static let maximumSeenIDs = 32
    public static let earliestSupportedTimestamp: TimeInterval = 0
    public static let latestSupportedTimestamp: TimeInterval = 4_102_444_800 // 2100-01-01 UTC
}

public enum TiboMessageCategory: String, Codable, Equatable, Sendable {
    case resetAnnouncement
    case resetCompleted
    case bankedReset
    case strongHint
}

public enum TiboVerificationState: String, Codable, Equatable, Sendable {
    case pending
    case confirmed
    case anomalous
}

public struct TiboMessage: Codable, Equatable, Sendable {
    public let id: String
    public let category: TiboMessageCategory
    public let localizedSummary: String
    public let publishedAt: Date
    public let canonicalURL: URL

    public init(
        id: String,
        category: TiboMessageCategory,
        localizedSummary: String,
        publishedAt: Date,
        canonicalURL: URL
    ) {
        self.id = id
        self.category = category
        self.localizedSummary = localizedSummary
        self.publishedAt = publishedAt
        self.canonicalURL = canonicalURL
    }
}

public struct TiboAlertRecord: Codable, Equatable, Sendable {
    public let id: String
    public var category: TiboMessageCategory?
    public var localizedSummary: String?
    public let publishedAt: Date
    public var canonicalURL: URL?
    public var verification: TiboVerificationState
    public var verificationUpdatedAt: Date?

    public init(
        message: TiboMessage,
        verification: TiboVerificationState = .pending,
        verificationUpdatedAt: Date? = nil
    ) {
        id = message.id
        category = message.category
        localizedSummary = message.localizedSummary
        publishedAt = message.publishedAt
        canonicalURL = message.canonicalURL
        self.verification = verification
        self.verificationUpdatedAt = verificationUpdatedAt
    }

    public init(
        id: String,
        category: TiboMessageCategory?,
        localizedSummary: String?,
        publishedAt: Date,
        canonicalURL: URL?,
        verification: TiboVerificationState,
        verificationUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.localizedSummary = localizedSummary
        self.publishedAt = publishedAt
        self.canonicalURL = canonicalURL
        self.verification = verification
        self.verificationUpdatedAt = verificationUpdatedAt
    }
}

public enum TiboFeedHealth: Codable, Equatable, Sendable {
    case neverChecked
    case healthy(checkedAt: Date, fetchedAt: Date)
    case stale(checkedAt: Date)
    case unavailable(checkedAt: Date)
}

public struct TiboAlertSnapshot: Codable, Equatable, Sendable {
    public var latest: TiboAlertRecord?
    public var unread: Bool
    public var pendingRevealID: String?
    public var health: TiboFeedHealth
    public var notificationPermissionRequested: Bool

    public init(
        latest: TiboAlertRecord? = nil,
        unread: Bool = false,
        pendingRevealID: String? = nil,
        health: TiboFeedHealth = .neverChecked,
        notificationPermissionRequested: Bool = false
    ) {
        self.latest = latest
        self.unread = unread
        self.pendingRevealID = pendingRevealID
        self.health = health
        self.notificationPermissionRequested = notificationPermissionRequested
    }
}

public struct TiboFeedResult: Equatable, Sendable {
    public let fetchedAt: Date
    public let health: TiboFeedHealth
    public let newestQualifyingMessage: TiboMessage?

    public init(fetchedAt: Date, health: TiboFeedHealth, newestQualifyingMessage: TiboMessage?) {
        self.fetchedAt = fetchedAt
        self.health = health
        self.newestQualifyingMessage = newestQualifyingMessage
    }
}

public struct TiboNotificationRequest: Equatable, Sendable {
    public let messageID: String
    public let title: String
    public let body: String

    public init(messageID: String, title: String, body: String) {
        self.messageID = messageID
        self.title = title
        self.body = body
    }
}
