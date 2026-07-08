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

// Claude Code 2.1.x can leave only MCP-server OAuth state in the Keychain item,
// with the real credential in ~/.claude/.credentials.json (see
// docs/plan-credentials-file-fallback.md). The reader must fall back to the file.
@Test
func claudeCredentialReaderFallsBackToFileWhenKeychainHoldsOnlyMCPState() throws {
    let keychain = InMemoryClaudeCredentialStore(
        data: Data(#"{"mcpOAuth": {"some-server": {"accessToken": "mcp-token"}}}"#.utf8)
    )
    let file = InMemoryClaudeCredentialStore(
        data: claudeCredentialData(expiresAtMilliseconds: 1_783_154_084_847)
    )
    let reader = ClaudeCredentialReader(
        store: keychain,
        fallbackStore: file,
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    let result = try reader.read()

    #expect(result == .fresh(ClaudeCredential(
        accessToken: "access-token",
        expiresAt: Date(timeIntervalSince1970: 1_783_154_084.847)
    )))
}

@Test
func claudeCredentialReaderDoesNotConsultFallbackWhenKeychainCredentialIsFresh() throws {
    let keychain = InMemoryClaudeCredentialStore(
        data: claudeCredentialData(expiresAtMilliseconds: 1_783_154_084_847)
    )
    let file = InMemoryClaudeCredentialStore(data: nil)
    let reader = ClaudeCredentialReader(
        store: keychain,
        fallbackStore: file,
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    let result = try reader.read()

    guard case .fresh = result else {
        Issue.record("Expected fresh state, got \(result)")
        return
    }
    #expect(file.readRequests.isEmpty)
}

@Test
func claudeCredentialReaderKeepsKeychainReasonWhenFallbackFileIsAbsent() throws {
    // An absent credentials file proves nothing about CLI state; the keychain's
    // reason is the actionable one. Standard macOS setups (keychain-only, no
    // file) must behave exactly as before the fallback existed.
    let keychain = InMemoryClaudeCredentialStore(
        data: Data(#"{"mcpOAuth": {"some-server": {"accessToken": "mcp-token"}}}"#.utf8)
    )
    let file = InMemoryClaudeCredentialStore(data: nil)
    let reader = ClaudeCredentialReader(store: keychain, fallbackStore: file)

    let result = try reader.read()

    #expect(result == .stale(reason: .parseFailure))
}

@Test
func claudeCredentialReaderFallsBackToFileWhenKeychainItemIsMissing() throws {
    let keychain = InMemoryClaudeCredentialStore(data: nil)
    let file = InMemoryClaudeCredentialStore(
        data: claudeCredentialData(expiresAtMilliseconds: 1_783_154_084_847)
    )
    let reader = ClaudeCredentialReader(
        store: keychain,
        fallbackStore: file,
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    let result = try reader.read()

    guard case .fresh = result else {
        Issue.record("Expected fresh state, got \(result)")
        return
    }
}

@Test
func claudeCredentialReaderPrefersFreshFileOverExpiredKeychainCredential() throws {
    // The sources drift while the CLI migrates storage; whichever holds a live
    // token wins.
    let keychain = InMemoryClaudeCredentialStore(
        data: claudeCredentialData(expiresAtMilliseconds: 1_000)
    )
    let file = InMemoryClaudeCredentialStore(
        data: claudeCredentialData(expiresAtMilliseconds: 1_783_154_084_847)
    )
    let reader = ClaudeCredentialReader(
        store: keychain,
        fallbackStore: file,
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    let result = try reader.read()

    guard case .fresh = result else {
        Issue.record("Expected fresh state, got \(result)")
        return
    }
}

@Test
func claudeCredentialReaderSurfacesPresentFileVerdictWhenBothSourcesFail() throws {
    // A readable credentials file is stronger evidence of CLI state than the
    // keychain, so its reason wins when both fail.
    let cases: [(fileData: Data, expectedReason: StaleReason)] = [
        (claudeCredentialData(expiresAtMilliseconds: 1_000), .tokenExpired),
        (Data("not json".utf8), .parseFailure),
    ]

    for (fileData, expectedReason) in cases {
        let reader = ClaudeCredentialReader(
            store: ThrowingClaudeCredentialStore(),
            fallbackStore: InMemoryClaudeCredentialStore(data: fileData),
            now: { Date(timeIntervalSince1970: 1_783_128_465) }
        )

        let result = try reader.read()

        #expect(result == .stale(reason: expectedReason))
    }
}

@Test
func claudeCredentialReaderKeepsKeychainReasonWhenFallbackStoreThrows() throws {
    // An unreadable file proves nothing about CLI state.
    let keychain = InMemoryClaudeCredentialStore(data: nil)
    let reader = ClaudeCredentialReader(
        store: keychain,
        fallbackStore: ThrowingClaudeCredentialStore()
    )

    let result = try reader.read()

    #expect(result == .stale(reason: .tokenExpired))
}

private final class InMemoryClaudeCredentialStore: CredentialStore, @unchecked Sendable {
    private let data: Data?
    private(set) var readRequests: [CredentialIdentifier] = []

    init(data: Data?) {
        self.data = data
    }

    func read(_ credential: CredentialIdentifier, mode _: CredentialAccessMode) throws -> Data? {
        readRequests.append(credential)
        return data
    }
}

private final class ThrowingClaudeCredentialStore: CredentialStore, @unchecked Sendable {
    private(set) var readRequests: [CredentialIdentifier] = []

    func read(_ credential: CredentialIdentifier, mode _: CredentialAccessMode) throws -> Data? {
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
