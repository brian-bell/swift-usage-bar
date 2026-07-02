import Foundation
import Testing
import UsageCore

@Test
func codexCredentialReaderRequestsCodexCredentialFromStore() throws {
    let expiresAt = Date(timeIntervalSince1970: 1_783_006_145)
    let credentialData = codexCredentialData(accessToken: dummyJWT(exp: expiresAt))
    let store = InMemoryCredentialStore(dataByCredential: [.codex: credentialData])
    let reader = CodexCredentialReader(store: store)

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
func credentialStoreProtocolRequiresOnlyReadAccess() {
    struct ReadOnlyStore: CredentialStore {
        func read(_ credential: CredentialIdentifier) -> Data? {
            nil
        }
    }

    let store: any CredentialStore = ReadOnlyStore()

    #expect(store.read(.codex) == nil)
}

@Test(.disabled("integration: reads the user's real Codex Keychain item"))
func keychainCredentialStoreCanReadCodexCredentialWhenInstalled() {
    let store = KeychainCredentialStore()

    #expect(store.read(.codex)?.isEmpty == false)
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let dataByCredential: [CredentialIdentifier: Data]
    private(set) var readRequests: [CredentialIdentifier] = []

    init(dataByCredential: [CredentialIdentifier: Data]) {
        self.dataByCredential = dataByCredential
    }

    func read(_ credential: CredentialIdentifier) -> Data? {
        readRequests.append(credential)
        return dataByCredential[credential]
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
