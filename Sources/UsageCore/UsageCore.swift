import Foundation

public enum UsageCore {
    public static let version = "0.1.0"
}

public struct UsageWindow: Equatable, Sendable {
    public let percentRemaining: Int
    public let resetsAt: Date?

    public init(percentRemaining: Int, resetsAt: Date?) {
        self.percentRemaining = percentRemaining
        self.resetsAt = resetsAt
    }
}

public struct ProviderUsage: Equatable, Sendable {
    public let fiveHour: UsageWindow
    public let weekly: UsageWindow

    public init(fiveHour: UsageWindow, weekly: UsageWindow) {
        self.fiveHour = fiveHour
        self.weekly = weekly
    }
}

public enum UsageParsingError: Error, Equatable, Sendable {
    case parseFailure
}

public struct ClaudeStatuslineParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> ProviderUsage {
        do {
            let statusline = try JSONDecoder().decode(ClaudeStatuslineResponse.self, from: data)

            return ProviderUsage(
                fiveHour: usageWindow(
                    usedPercentage: statusline.rateLimits.fiveHour.usedPercentage,
                    resetAt: statusline.rateLimits.fiveHour.resetsAt
                ),
                weekly: usageWindow(
                    usedPercentage: statusline.rateLimits.sevenDay.usedPercentage,
                    resetAt: statusline.rateLimits.sevenDay.resetsAt
                )
            )
        } catch {
            throw UsageParsingError.parseFailure
        }
    }
}

public struct CodexUsageParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> ProviderUsage {
        do {
            let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)

            return ProviderUsage(
                fiveHour: usageWindow(
                    usedPercentage: response.rateLimit.primaryWindow.usedPercent,
                    resetAt: response.rateLimit.primaryWindow.resetAt
                ),
                weekly: usageWindow(
                    usedPercentage: response.rateLimit.secondaryWindow.usedPercent,
                    resetAt: response.rateLimit.secondaryWindow.resetAt
                )
            )
        } catch {
            throw UsageParsingError.parseFailure
        }
    }
}

public enum CountdownFormatter {
    public static func format(
        resetAt: Date,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let remainingSeconds = resetAt.timeIntervalSince(now)
        if remainingSeconds <= 0 {
            return "resetting..."
        }

        if remainingSeconds >= 24 * 60 * 60 {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "EEE h:mm a"

            return "resets \(formatter.string(from: resetAt))"
        }

        let remainingMinutes = max(0, Int(remainingSeconds / 60))
        let hours = remainingMinutes / 60
        let minutes = remainingMinutes % 60

        return "resets in \(hours)h \(minutes)m"
    }
}

private struct ClaudeStatuslineResponse: Decodable {
    let rateLimits: ClaudeStatuslineRateLimits

    enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }
}

private struct ClaudeStatuslineRateLimits: Decodable {
    let fiveHour: ClaudeStatuslineWindow
    let sevenDay: ClaudeStatuslineWindow

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct ClaudeStatuslineWindow: Decodable {
    let usedPercentage: Int
    let resetsAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

private struct CodexUsageResponse: Decodable {
    let rateLimit: CodexRateLimit

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexRateLimitWindow
    let secondaryWindow: CodexRateLimitWindow

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexRateLimitWindow: Decodable {
    let resetAt: TimeInterval
    let usedPercent: Int

    enum CodingKeys: String, CodingKey {
        case resetAt = "reset_at"
        case usedPercent = "used_percent"
    }
}

private func usageWindow(usedPercentage: Int, resetAt: TimeInterval) -> UsageWindow {
    UsageWindow(
        percentRemaining: percentRemaining(fromUsedPercentage: usedPercentage),
        resetsAt: Date(timeIntervalSince1970: resetAt)
    )
}

private func percentRemaining(fromUsedPercentage usedPercentage: Int) -> Int {
    min(100, max(0, 100 - usedPercentage))
}
