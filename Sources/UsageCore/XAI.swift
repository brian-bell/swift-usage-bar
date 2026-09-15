import Foundation
import Security

/// Console team ID for the Management API billing path. Official docs show a
/// UUID; org-scoped keys still need this explicit team id (do not substitute
/// `scopeId`). Rejects anything that is not a UUID so an untrusted string
/// cannot reach the request path.
public enum XAITeamID {
    public static func normalizedID(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, UUID(uuidString: value) != nil else {
            return nil
        }
        return value.lowercased()
    }
}

public struct XAIManagementCredential: Sendable, Equatable {
    public let key: String
    public let teamID: String

    public init(key: String, teamID: String) {
        self.key = key
        self.teamID = teamID
    }
}

public enum XAIManagementCredentialReadResult: Equatable, Sendable {
    case fresh(XAIManagementCredential)
    case stale(reason: StaleReason)
}

public protocol XAIManagementCredentialReading: Sendable {
    func read(mode: CredentialAccessMode) throws -> XAIManagementCredentialReadResult
}

public extension XAIManagementCredentialReading {
    func read() throws -> XAIManagementCredentialReadResult {
        try read(mode: .background)
    }
}

public protocol XAIManagementKeyStoring: Sendable {
    func read(mode: CredentialAccessMode) throws -> String?
    func write(_ key: String) throws
    func delete() throws
}

/// Test/double store. Production uses `KeychainXAIManagementKeyStore`.
public final class InMemoryXAIManagementKeyStore: XAIManagementKeyStoring, @unchecked Sendable {
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func read(mode _: CredentialAccessMode) throws -> String? {
        key
    }

    public func write(_ key: String) throws {
        self.key = key
    }

    public func delete() throws {
        key = nil
    }
}

/// AIUsageBar-owned Keychain item for the management key the user pastes in
/// Settings. This is not a CLI credential: we never write Claude/Codex/
/// OpenCode/Chrome items. Background reads suppress Keychain UI.
public struct KeychainXAIManagementKeyStore: XAIManagementKeyStoring {
    public static let service = "AIUsageBar xAI Management Key"
    public static let account = "management"

    public typealias CopyMatching = @Sendable (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    public typealias AddItem = @Sendable (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    public typealias UpdateItem = @Sendable (CFDictionary, CFDictionary) -> OSStatus
    public typealias DeleteItem = @Sendable (CFDictionary) -> OSStatus

    private let copyMatching: CopyMatching
    private let addItem: AddItem
    private let updateItem: UpdateItem
    private let deleteItem: DeleteItem

    public init() {
        self.copyMatching = SecItemCopyMatching
        self.addItem = SecItemAdd
        self.updateItem = SecItemUpdate
        self.deleteItem = SecItemDelete
    }

    public init(
        copyMatching: @escaping CopyMatching,
        addItem: @escaping AddItem,
        updateItem: @escaping UpdateItem,
        deleteItem: @escaping DeleteItem
    ) {
        self.copyMatching = copyMatching
        self.addItem = addItem
        self.updateItem = updateItem
        self.deleteItem = deleteItem
    }

    public func read(mode: CredentialAccessMode) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if mode == .background {
            query[kSecUseAuthenticationUI as String] = "fail"
        }

        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CredentialStoreReadError.unavailable
        }
        let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty == false) ? key : nil
    }

    public func write(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw CredentialStoreReadError.unavailable
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
            kSecAttrLabel as String: Self.service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = addItem(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: Self.account,
            ]
            let updateStatus = updateItem(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw CredentialStoreReadError.unavailable
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw CredentialStoreReadError.unavailable
        }
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let status = deleteItem(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreReadError.unavailable
        }
    }
}

/// Combines the Settings team ID with the Keychain-held management key.
/// Missing either is `.credentialUnavailable`. Does not read OpenCode's
/// `xai` inference key, env vars, or console cookies.
public struct XAIManagementCredentialReader: XAIManagementCredentialReading {
    private let keyStore: any XAIManagementKeyStoring
    private let teamID: @Sendable () -> String?

    public init(
        keyStore: any XAIManagementKeyStoring,
        teamID: @escaping @Sendable () -> String?
    ) {
        self.keyStore = keyStore
        self.teamID = teamID
    }

    public func read(mode: CredentialAccessMode) throws -> XAIManagementCredentialReadResult {
        let normalizedTeamID = XAITeamID.normalizedID(from: teamID())
        let key: String?
        do {
            key = try keyStore.read(mode: mode)
        } catch {
            return .stale(reason: .credentialUnavailable)
        }
        guard let normalizedTeamID,
              let key,
              !key.isEmpty
        else {
            return .stale(reason: .credentialUnavailable)
        }
        return .fresh(XAIManagementCredential(key: key, teamID: normalizedTeamID))
    }
}

public struct XAIPrepaidBalanceResponse: Sendable, Equatable {
    public let data: Data
    public let receivedAt: Date

    public init(data: Data, receivedAt: Date) {
        self.data = data
        self.receivedAt = receivedAt
    }
}

/// Extracts remaining prepaid USD from the official Management API ledger.
/// Pins only `total.val` (USD cents as a string). `changes[]` carries
/// invoices and payment processors and is never decoded.
///
/// Sign: PURCHASE amounts are negative cents; remaining dollars are
/// `-cents/100`. A missing `total.val` is a parse failure, never `$0.00`.
public struct XAIPrepaidBalanceParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> CreditBalance {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageParsingError.parseFailure
        }

        guard let cents = Int(response.total.val) else {
            throw UsageParsingError.parseFailure
        }

        return CreditBalance(balanceUSD: Double(-cents) / 100)
    }

    private struct Response: Decodable {
        let total: Total
    }

    private struct Total: Decodable {
        let val: String
    }
}

public enum XAIPrepaidTransportError: Error, Equatable, Sendable {
    /// HTTP 401/403: Management API rejected the key (inference keys fail here).
    case notAuthenticated
    /// HTTP 404: no prepaid ledger for this team (wrong id or postpaid-only).
    case prepaidUnavailable
}

public protocol XAIPrepaidTransporting: Sendable {
    func fetchBalance(
        credential: XAIManagementCredential
    ) async throws -> XAIPrepaidBalanceResponse
}

public struct XAIPrepaidHTTPTransport: XAIPrepaidTransporting {
    public static let host = "management-api.x.ai"

    private let sender: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        sender: any HTTPTransport = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sender = sender
        self.now = now
    }

    public static func endpoint(teamID: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/v1/billing/teams/\(teamID)/prepaid/balance"
        return components.url!
    }

    public func fetchBalance(
        credential: XAIManagementCredential
    ) async throws -> XAIPrepaidBalanceResponse {
        let (data, response) = try await sender.send(Self.request(for: credential))
        switch response.statusCode {
        case 401, 403:
            throw XAIPrepaidTransportError.notAuthenticated
        case 404:
            throw XAIPrepaidTransportError.prepaidUnavailable
        default:
            break
        }
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return XAIPrepaidBalanceResponse(data: data, receivedAt: now())
    }

    private static func request(for credential: XAIManagementCredential) -> URLRequest {
        var request = URLRequest(url: endpoint(teamID: credential.teamID))
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsageBar/\(UsageCore.version)", forHTTPHeaderField: "User-Agent")
        return request
    }
}

/// xAI developer-API prepaid credits. Dollar snapshot only; out of tone and
/// thresholds. Separate from Cursor Grok Bot and SuperGrok.
public struct XAIPrepaidUsageProvider: UsageProvider {
    private let credentialReader: any XAIManagementCredentialReading
    private let transport: any XAIPrepaidTransporting
    private let parser: XAIPrepaidBalanceParser

    public init(
        credentialReader: any XAIManagementCredentialReading,
        transport: any XAIPrepaidTransporting,
        parser: XAIPrepaidBalanceParser = XAIPrepaidBalanceParser()
    ) {
        self.credentialReader = credentialReader
        self.transport = transport
        self.parser = parser
    }

    public func fetch(previous: ProviderUsage?, mode: CredentialAccessMode) async -> ProviderState {
        await fetchReport(previous: previous, mode: mode).state
    }

    public func fetchReport(
        previous: ProviderUsage?,
        mode: CredentialAccessMode
    ) async -> ProviderFetchReport {
        let credential: XAIManagementCredential
        do {
            switch try credentialReader.read(mode: mode) {
            case let .fresh(fresh):
                credential = fresh
            case let .stale(reason):
                return ProviderFetchReport(
                    state: .stale(last: previous, reason: reason),
                    chain: [ProviderDataSourceStep(.xaiPrepaidBalance, .failed(reason))]
                )
            }
        } catch {
            return ProviderFetchReport(
                state: .stale(last: previous, reason: .credentialUnavailable),
                chain: [ProviderDataSourceStep(
                    .xaiPrepaidBalance,
                    .failed(.credentialUnavailable)
                )]
            )
        }

        let state: ProviderState
        do {
            let response = try await transport.fetchBalance(credential: credential)
            let credits = try parser.parse(response.data)
            state = .fresh(Self.usage(for: credits), asOf: response.receivedAt)
        } catch XAIPrepaidTransportError.notAuthenticated {
            state = .stale(last: previous, reason: .tokenExpired)
        } catch XAIPrepaidTransportError.prepaidUnavailable {
            state = .stale(last: previous, reason: .credentialUnavailable)
        } catch UsageParsingError.parseFailure {
            state = .stale(last: previous, reason: .parseFailure)
        } catch {
            state = .stale(last: previous, reason: .networkError)
        }

        let step = ProviderDataSourceStep.singlePath(.xaiPrepaidBalance, state: state)
        return ProviderFetchReport(state: state, chain: [step])
    }

    private static func usage(for credits: CreditBalance) -> ProviderUsage {
        ProviderUsage(
            fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
            weekly: UsageWindow(percentRemaining: nil, resetsAt: nil),
            credits: credits
        )
    }
}
