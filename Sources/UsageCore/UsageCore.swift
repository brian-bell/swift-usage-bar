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
    case credentialUnavailable
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
        let usage: ProviderUsage
        do {
            usage = try parser.parse(data)
        } catch UsageParsingError.parseFailure {
            return .stale(
                last: nil,
                reason: .parseFailure,
                hint: Self.configureStatuslineHint
            )
        }

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
            guard stored.tokens.hasRequiredValues else {
                throw UsageParsingError.parseFailure
            }

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
    case codex
}

public enum CredentialStoreReadError: Error, Equatable, Sendable {
    case unavailable
}

public protocol CredentialStore: Sendable {
    func read(_ credential: CredentialIdentifier) throws -> Data?
}

public enum CodexCredentialReadResult: Equatable, Sendable {
    case fresh(CodexCredential)
    case stale(reason: StaleReason)
}

public struct CodexCredentialReader: Sendable {
    private let store: any CredentialStore
    private let parser: CodexCredentialParser
    private let now: @Sendable () -> Date

    public init(
        store: any CredentialStore,
        parser: CodexCredentialParser = CodexCredentialParser(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.parser = parser
        self.now = now
    }

    public func read() throws -> CodexCredentialReadResult {
        let data: Data?
        do {
            data = try store.read(.codex)
        } catch CredentialStoreReadError.unavailable {
            return .stale(reason: .credentialUnavailable)
        } catch {
            return .stale(reason: .credentialUnavailable)
        }

        guard let data else {
            return .stale(reason: .tokenExpired)
        }

        let credential: CodexCredential
        do {
            credential = try parser.parse(data)
        } catch UsageParsingError.parseFailure {
            return .stale(reason: .parseFailure)
        }

        guard credential.expiresAt > now() else {
            return .stale(reason: .tokenExpired)
        }

        return .fresh(credential)
    }
}

public struct KeychainCredentialStore: CredentialStore {
    public typealias CopyMatching = @Sendable (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus

    private let accountResolver: @Sendable (CredentialIdentifier) -> String
    private let copyMatching: CopyMatching

    public init() {
        self.accountResolver = Self.defaultAccount(for:)
        self.copyMatching = SecItemCopyMatching
    }

    public init(copyMatching: @escaping CopyMatching) {
        self.accountResolver = Self.defaultAccount(for:)
        self.copyMatching = copyMatching
    }

    init(codexHomePath: String, copyMatching: @escaping CopyMatching) {
        self.accountResolver = { _ in codexKeychainAccount(codexHomePath: codexHomePath) }
        self.copyMatching = copyMatching
    }

    public init(
        accountResolver: @escaping @Sendable (CredentialIdentifier) -> String,
        copyMatching: @escaping CopyMatching = SecItemCopyMatching
    ) {
        self.accountResolver = accountResolver
        self.copyMatching = copyMatching
    }

    public func read(_ credential: CredentialIdentifier) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: credential.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        query[kSecAttrAccount as String] = accountResolver(credential)

        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw CredentialStoreReadError.unavailable
        }

        return item as? Data
    }

    private static func defaultAccount(for credential: CredentialIdentifier) -> String {
        switch credential {
        case .codex:
            return codexKeychainAccount(codexHomePath: defaultCodexHomePath())
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
        "Codex Auth"
    }
}

private struct CodexStoredCredential: Decodable {
    let tokens: Tokens

    struct Tokens: Decodable {
        let accessToken: String
        let accountID: String

        var hasRequiredValues: Bool {
            !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

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

func codexKeychainAccount(codexHomePath: String) -> String {
    "cli|\(codexHomeHashPrefix(codexHomePath: codexHomePath))"
}

private func defaultCodexHomePath() -> String {
    let environment = ProcessInfo.processInfo.environment

    return environment["CODEX_HOME"] ?? "\(environment["HOME"] ?? NSHomeDirectory())/.codex"
}

private func codexHomeHashPrefix(codexHomePath: String) -> String {
    let canonicalPath = URL(fileURLWithPath: codexHomePath)
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
