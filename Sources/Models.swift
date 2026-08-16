import SwiftUI
import AppKit
import Foundation

// MARK: - Data Models
struct ClaudeStats: Codable {
    let dailyActivity: [DayActivity]?
    let modelUsage: [String: ModelTokens]?
    let totalSessions: Int?
    let totalMessages: Int?
    let firstSessionDate: String?
    // Só é reescrito quando o usuário abre `/usage` no Claude Code — pode estar velho.
    let lastComputedDate: String?
}
struct DayActivity: Codable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}
struct ModelTokens: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    var total: Int { inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens }
}
struct HistoryLine: Codable {
    let timestamp: Double?
    let project: String?
}
struct SessionFile: Codable {
    let pid: Int?
    let sessionId: String?
    let cwd: String?
    let status: String?
}
struct OAuthCredentials: Codable {
    let claudeAiOauth: OAuthToken
}
struct OAuthToken: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Double
    let subscriptionType: String?
    let rateLimitTier: String?
}

// Rate limit data from API headers
struct RateLimits {
    var status: String = "unknown"
    var fiveHourStatus: String = "unknown"
    var fiveHourReset: Date = Date()
    var fiveHourUtilization: Double = 0
    var sevenDayStatus: String = "unknown"
    var sevenDayReset: Date = Date()
    var sevenDayUtilization: Double = 0
    var fallbackPct: Double = 0
    var overageStatus: String = "unknown"
    var fetchedAt: Date = Date()
    var error: String? = nil
}

