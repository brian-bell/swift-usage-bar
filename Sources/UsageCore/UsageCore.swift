import CryptoKit
import Foundation
import Security

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

public enum ProviderID: CaseIterable, Hashable, Sendable {
    case claude
    case codex
}

public enum StaleReason: Equatable, Sendable {
    case parseFailure
    case networkError
    case tokenExpired
}

public enum ProviderState: Equatable, Sendable {
    case fresh(ProviderUsage, asOf: Date)
    case stale(last: ProviderUsage?, reason: StaleReason)
    case hidden
}

public enum UsageStatusTone: Equatable, Sendable {
    case normal
    case warning
    case critical
}

public enum ClaudeStatuslineCacheReadResult: Equatable, Sendable {
    case fresh(data: Data, usage: ProviderUsage, asOf: Date)
    case stale(last: ProviderUsage?, reason: StaleReason, hint: String)
}

public struct ClaudeStatuslineCacheReader: Sendable {
    private let cacheURL: URL
    private let maximumAge: TimeInterval
    private let parser: ClaudeStatuslineParser

    public init(
        cacheURL: URL,
        maximumAge: TimeInterval,
        parser: ClaudeStatuslineParser = ClaudeStatuslineParser()
    ) {
        self.cacheURL = cacheURL
        self.maximumAge = maximumAge
        self.parser = parser
    }

    public func read(now: Date) throws -> ClaudeStatuslineCacheReadResult {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return .stale(
                last: nil,
                reason: .networkError,
                hint: Self.configureStatuslineHint
            )
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        let modifiedAt = attributes[.modificationDate] as? Date ?? .distantPast
        let data = try Data(contentsOf: cacheURL)
        let usage = try parser.parse(data)

        if now.timeIntervalSince(modifiedAt) > maximumAge {
            return .stale(
                last: usage,
                reason: .networkError,
                hint: Self.configureStatuslineHint
            )
        }

        return .fresh(data: data, usage: usage, asOf: modifiedAt)
    }

    private static let configureStatuslineHint =
        "Configure Claude Code statusline to write its cache."
}

public struct CodexCredential: Equatable, Sendable {
    public let accessToken: String
    public let accountID: String
    public let expiresAt: Date

    public init(accessToken: String, accountID: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.expiresAt = expiresAt
    }
}

public struct CodexCredentialParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> CodexCredential {
        do {
            let stored = try JSONDecoder().decode(CodexStoredCredential.self, from: data)
            return CodexCredential(
                accessToken: stored.tokens.accessToken,
                accountID: stored.tokens.accountID,
                expiresAt: try expiryDate(fromJWT: stored.tokens.accessToken)
            )
        } catch {
            throw UsageParsingError.parseFailure
        }
    }
}

public enum CredentialIdentifier: Hashable, Sendable {
    case claude
    case codex
}

public protocol CredentialStore: Sendable {
    func read(_ credential: CredentialIdentifier) -> Data?
}

public enum CodexCredentialReadResult: Equatable, Sendable {
    case fresh(CodexCredential)
    case stale(reason: StaleReason)
}

public struct CodexCredentialReader: Sendable {
    private let store: any CredentialStore
    private let parser: CodexCredentialParser

    public init(
        store: any CredentialStore,
        parser: CodexCredentialParser = CodexCredentialParser()
    ) {
        self.store = store
        self.parser = parser
    }

    public func read() throws -> CodexCredentialReadResult {
        guard let data = store.read(.codex) else {
            return .stale(reason: .tokenExpired)
        }

        return .fresh(try parser.parse(data))
    }
}

public struct KeychainCredentialStore: CredentialStore {
    private let accountResolver: @Sendable (CredentialIdentifier) -> String?

    public init() {
        self.accountResolver = Self.defaultAccount(for:)
    }

    public init(accountResolver: @escaping @Sendable (CredentialIdentifier) -> String?) {
        self.accountResolver = accountResolver
    }

    public func read(_ credential: CredentialIdentifier) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: credential.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        if let account = accountResolver(credential) {
            query[kSecAttrAccount as String] = account
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }

        return item as? Data
    }

    private static func defaultAccount(for credential: CredentialIdentifier) -> String? {
        switch credential {
        case .claude:
            return nil
        case .codex:
            return "cli|\(codexHomeHashPrefix())"
        }
    }
}

public func tone(for usage: ProviderUsage, warningThreshold: Int = 20) -> UsageStatusTone {
    let remaining = min(usage.fiveHour.percentRemaining, usage.weekly.percentRemaining)
    if remaining < 5 {
        return .critical
    }

    if remaining < warningThreshold {
        return .warning
    }

    return .normal
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

public enum MenuBarTitleFormatter {
    public static func format(_ states: [ProviderID: ProviderState]) -> AttributedString {
        let segments = ProviderID.allCases.compactMap { provider -> String? in
            guard let state = states[provider] else {
                return "\(provider.symbol) --/--"
            }

            switch state {
            case let .fresh(usage, _):
                return "\(provider.symbol) \(usage.remainingPair)"
            case let .stale(last: usage?, reason: _):
                return "\(provider.symbol) ~\(usage.remainingPair)"
            case .stale(last: nil, reason: _):
                return "\(provider.symbol) --/--"
            case .hidden:
                return nil
            }
        }

        return AttributedString(segments.joined(separator: "  "))
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

private extension CredentialIdentifier {
    var keychainService: String {
        switch self {
        case .claude:
            return "Claude Code-credentials"
        case .codex:
            return "Codex Auth"
        }
    }
}

private struct CodexStoredCredential: Decodable {
    let tokens: Tokens

    struct Tokens: Decodable {
        let accessToken: String
        let accountID: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
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

private struct JWTPayload: Decodable {
    let exp: TimeInterval
}

private func expiryDate(fromJWT token: String) throws -> Date {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count >= 2 else {
        throw UsageParsingError.parseFailure
    }

    let payloadSegment = String(segments[1])
    guard let payloadData = Data(base64URLEncoded: payloadSegment) else {
        throw UsageParsingError.parseFailure
    }

    do {
        let payload = try JSONDecoder().decode(JWTPayload.self, from: payloadData)
        return Date(timeIntervalSince1970: payload.exp)
    } catch {
        throw UsageParsingError.parseFailure
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
    if usedPercentage <= 0 {
        return 100
    }

    if usedPercentage >= 100 {
        return 0
    }

    return 100 - usedPercentage
}

private extension ProviderUsage {
    var remainingPair: String {
        "\(fiveHour.percentRemaining)/\(weekly.percentRemaining)"
    }
}

private extension ProviderID {
    var symbol: String {
        switch self {
        case .claude:
            "*"
        case .codex:
            "#"
        }
    }
}

private func codexHomeHashPrefix() -> String {
    let environment = ProcessInfo.processInfo.environment
    let rawPath = environment["CODEX_HOME"] ?? "\(environment["HOME"] ?? NSHomeDirectory())/.codex"
    let canonicalPath = URL(fileURLWithPath: rawPath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
    let digest = SHA256.hash(data: Data(canonicalPath.utf8))

    return digest
        .prefix(8)
        .map { String(format: "%02x", $0) }
        .joined()
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let paddingCount = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: paddingCount))

        self.init(base64Encoded: base64)
    }
}
