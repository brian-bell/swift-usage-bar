import Foundation
import Testing
import UsageCore

@Test
func claudeCredentialReaderRequestsClaudeCredentialFromStore() throws {
    let store = InMemoryClaudeCredentialStore(data: claudeCredentialData(expiresAtMilliseconds: 1_783_154_084_847))
    let reader = ClaudeCredentialReader(
        store: store,
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    let result = try reader.read()

    #expect(store.readRequests == [.claude])
    #expect(result == .fresh(ClaudeCredential(
        accessToken: "access-token",
        expiresAt: Date(timeIntervalSince1970: 1_783_154_084.847)
    )))
}

@Test
func claudeCredentialReaderReturnsTokenExpiredWhenStoreHasNoCredential() throws {
    let store = InMemoryClaudeCredentialStore(data: nil)
    let reader = ClaudeCredentialReader(store: store)

    let result = try reader.read()

    #expect(store.readRequests == [.claude])
    #expect(result == .stale(reason: .tokenExpired))
}

@Test
func claudeCredentialReaderReturnsTokenExpiredWhenCredentialIsExpired() throws {
    let store = InMemoryClaudeCredentialStore(data: claudeCredentialData(expiresAtMilliseconds: 1_783_154_084_000))
    let reader = ClaudeCredentialReader(
        store: store,
        now: { Date(timeIntervalSince1970: 1_783_154_084) }
    )

    let result = try reader.read()

    #expect(result == .stale(reason: .tokenExpired))
}

@Test
func claudeCredentialReaderReturnsParseFailureWhenStoredCredentialIsMalformed() throws {
    let store = InMemoryClaudeCredentialStore(data: Data("not json".utf8))
    let reader = ClaudeCredentialReader(store: store)

    let result = try reader.read()

    #expect(result == .stale(reason: .parseFailure))
}

@Test
func claudeCredentialReaderReturnsCredentialUnavailableWhenStoreReadFails() throws {
    let store = ThrowingClaudeCredentialStore()
    let reader = ClaudeCredentialReader(store: store)

    let result = try reader.read()

    #expect(store.readRequests == [.claude])
    #expect(result == .stale(reason: .credentialUnavailable))
}

private final class InMemoryClaudeCredentialStore: CredentialStore, @unchecked Sendable {
    private let data: Data?
    private(set) var readRequests: [CredentialIdentifier] = []

    init(data: Data?) {
        self.data = data
    }

    func read(_ credential: CredentialIdentifier) throws -> Data? {
        readRequests.append(credential)
        return data
    }
}

private final class ThrowingClaudeCredentialStore: CredentialStore, @unchecked Sendable {
    private(set) var readRequests: [CredentialIdentifier] = []

    func read(_ credential: CredentialIdentifier) throws -> Data? {
        readRequests.append(credential)
        throw CredentialStoreReadError.unavailable
    }
}

private func claudeCredentialData(expiresAtMilliseconds: Int64) -> Data {
    Data("""
    {
      "claudeAiOauth": {
        "accessToken": "access-token",
        "refreshToken": "refresh-token",
        "expiresAt": \(expiresAtMilliseconds),
        "scopes": ["user:inference"],
        "subscriptionType": "max",
        "rateLimitTier": "tier"
      }
    }
    """.utf8)
}
