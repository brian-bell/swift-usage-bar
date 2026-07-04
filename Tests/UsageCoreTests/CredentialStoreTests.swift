import Foundation
import Security
import Testing
@testable import UsageCore

@Test
func codexCredentialReaderRequestsCodexCredentialFromStore() throws {
    let expiresAt = Date(timeIntervalSince1970: 1_783_006_145)
    let credentialData = codexCredentialData(accessToken: dummyJWT(exp: expiresAt))
    let store = InMemoryCredentialStore(dataByCredential: [.codex: credentialData])
    let reader = CodexCredentialReader(
        store: store,
        now: { Date(timeIntervalSince1970: 1_783_006_144) }
    )

    let result = try reader.read()

    #expect(store.readRequests == [.codex])
    #expect(result == .fresh(CodexCredential(
        accessToken: dummyJWT(exp: expiresAt),
        accountID: "account-123",
        expiresAt: expiresAt
    )))
}

@Test
func codexCredentialReaderReturnsTokenExpiredWhenStoreHasNoCredential() throws {
    let store = InMemoryCredentialStore(dataByCredential: [:])
    let reader = CodexCredentialReader(store: store)

    let result = try reader.read()

    #expect(store.readRequests == [.codex])
    #expect(result == .stale(reason: .tokenExpired))
}

@Test
func codexCredentialReaderReturnsTokenExpiredWhenCredentialIsExpired() throws {
    let expiresAt = Date(timeIntervalSince1970: 1_783_006_145)
    let credentialData = codexCredentialData(accessToken: dummyJWT(exp: expiresAt))
    let store = InMemoryCredentialStore(dataByCredential: [.codex: credentialData])
    let reader = CodexCredentialReader(
        store: store,
        now: { Date(timeIntervalSince1970: 1_783_006_145) }
    )

    let result = try reader.read()

    #expect(store.readRequests == [.codex])
    #expect(result == .stale(reason: .tokenExpired))
}

@Test
func codexCredentialReaderReturnsParseFailureWhenStoredCredentialIsMalformed() throws {
    let store = InMemoryCredentialStore(dataByCredential: [.codex: Data("not json".utf8)])
    let reader = CodexCredentialReader(store: store)

    let result = try reader.read()

    #expect(store.readRequests == [.codex])
    #expect(result == .stale(reason: .parseFailure))
}

@Test
func codexCredentialReaderReturnsCredentialUnavailableWhenStoreReadFails() throws {
    let store = FailingCredentialStore()
    let reader = CodexCredentialReader(store: store)

    let result = try reader.read()

    #expect(store.readRequests == [.codex])
    #expect(result == .stale(reason: .credentialUnavailable))
}

@Test
func codexCredentialReaderReturnsCredentialUnavailableWhenStoreReadThrowsUnexpectedError() throws {
    let store = UnexpectedFailingCredentialStore()
    let reader = CodexCredentialReader(store: store)

    let result = try reader.read()

    #expect(store.readRequests == [.codex])
    #expect(result == .stale(reason: .credentialUnavailable))
}

@Test
func keychainCredentialStoreBuildsScopedCodexReadQuery() throws {
    let recorder = KeychainQueryRecorder()
    let store = KeychainCredentialStore(
        accountResolver: { credential in
            #expect(credential == .codex)
            return "cli|abc123"
        },
        copyMatching: { query, _ in
            recorder.record(query)
            return errSecItemNotFound
        }
    )

    let data = try store.read(.codex)
    let query = try #require(recorder.query)

    #expect(data == nil)
    #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
    #expect(query[kSecAttrService as String] as? String == "Codex Auth")
    #expect(query[kSecAttrAccount as String] as? String == "cli|abc123")
    #expect(query[kSecReturnData as String] as? Bool == true)
    #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
}

@Test
func keychainCredentialStoreUsesDefaultCodexAccountHash() throws {
    let recorder = KeychainQueryRecorder()
    let store = KeychainCredentialStore(
        codexHomePath: "/Users/example/.codex",
        copyMatching: { query, _ in
            recorder.record(query)
            return errSecItemNotFound
        }
    )

    _ = try store.read(.codex)
    let query = try #require(recorder.query)

    #expect(query[kSecAttrAccount as String] as? String == "cli|8533f99d37c07dbb")
}

@Test
func keychainCredentialStoreBuildsClaudeReadQueryWithoutAccount() throws {
    let recorder = KeychainQueryRecorder()
    let store = KeychainCredentialStore(
        copyMatching: { query, _ in
            recorder.record(query)
            return errSecItemNotFound
        }
    )

    let data = try store.read(.claude)
    let query = try #require(recorder.query)

    #expect(data == nil)
    #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
    #expect(query[kSecAttrService as String] as? String == "Claude Code-credentials")
    #expect(query[kSecAttrAccount as String] == nil)
    #expect(query[kSecReturnData as String] as? Bool == true)
    #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
}

@Test
func keychainCredentialStoreThrowsWhenKeychainReadFails() throws {
    let store = KeychainCredentialStore(
        accountResolver: { _ in "cli|abc123" },
        copyMatching: { _, _ in errSecInteractionNotAllowed }
    )

    do {
        _ = try store.read(.codex)
        Issue.record("Expected credential store read failure")
    } catch CredentialStoreReadError.unavailable {
        return
    } catch {
        Issue.record("Expected CredentialStoreReadError.unavailable, got \(error)")
    }
}

@Test
func credentialStoreProtocolRequiresOnlyReadAccess() throws {
    struct ReadOnlyStore: CredentialStore {
        func read(_ credential: CredentialIdentifier) throws -> Data? {
            nil
        }
    }

    let store: any CredentialStore = ReadOnlyStore()

    #expect(try store.read(.codex) == nil)
}

@Test(.disabled("integration: reads the user's real Codex Keychain item"))
func keychainCredentialStoreCanReadCodexCredentialWhenInstalled() throws {
    let store = KeychainCredentialStore()

    #expect(try store.read(.codex)?.isEmpty == false)
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let dataByCredential: [CredentialIdentifier: Data]
    private(set) var readRequests: [CredentialIdentifier] = []

    init(dataByCredential: [CredentialIdentifier: Data]) {
        self.dataByCredential = dataByCredential
    }

    func read(_ credential: CredentialIdentifier) throws -> Data? {
        readRequests.append(credential)
        return dataByCredential[credential]
    }
}

private final class FailingCredentialStore: CredentialStore, @unchecked Sendable {
    private(set) var readRequests: [CredentialIdentifier] = []

    func read(_ credential: CredentialIdentifier) throws -> Data? {
        readRequests.append(credential)
        throw CredentialStoreReadError.unavailable
    }
}

private final class UnexpectedFailingCredentialStore: CredentialStore, @unchecked Sendable {
    enum Error: Swift.Error {
        case failed
    }

    private(set) var readRequests: [CredentialIdentifier] = []

    func read(_ credential: CredentialIdentifier) throws -> Data? {
        readRequests.append(credential)
        throw Error.failed
    }
}

private final class KeychainQueryRecorder: @unchecked Sendable {
    private(set) var query: [String: Any]?

    func record(_ query: CFDictionary) {
        self.query = query as NSDictionary as? [String: Any]
    }
}

private func codexCredentialData(accessToken: String) -> Data {
    Data("""
    {
      "auth_mode": "chatgpt",
      "last_refresh": "2026-07-02T11:22:33Z",
      "tokens": {
        "access_token": "\(accessToken)",
        "refresh_token": "refresh-token",
        "id_token": "id-token",
        "account_id": "account-123"
      }
    }
    """.utf8)
}

private func dummyJWT(exp: Date) -> String {
    let header = base64URL(#"{"alg":"none"}"#)
    let payload = base64URL(#"{"exp":\#(Int(exp.timeIntervalSince1970))}"#)

    return "\(header).\(payload)."
}

private func base64URL(_ string: String) -> String {
    Data(string.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
