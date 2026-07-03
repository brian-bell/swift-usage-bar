import Foundation
import Testing
import UsageCore

@Test
func codexCredentialParserReadsTokenAccountAndJWTExpiry() throws {
    let expiresAt = Date(timeIntervalSince1970: 1_783_006_145)
    let credentialJSON = Data("""
    {
      "auth_mode": "chatgpt",
      "last_refresh": "2026-07-02T11:22:33Z",
      "tokens": {
        "access_token": "\(dummyJWT(exp: expiresAt))",
        "refresh_token": "refresh-token",
        "id_token": "id-token",
        "account_id": "account-123"
      }
    }
    """.utf8)

    let credential = try CodexCredentialParser().parse(credentialJSON)

    #expect(credential.accessToken == dummyJWT(exp: expiresAt))
    #expect(credential.accountID == "account-123")
    #expect(credential.expiresAt == expiresAt)
}

@Test
func codexCredentialParserReadsTokenAndJWTExpiryWhenAccountIDIsMissing() throws {
    let expiresAt = Date(timeIntervalSince1970: 1_783_006_145)
    let credentialJSON = Data("""
    {
      "auth_mode": "chatgpt",
      "last_refresh": "2026-07-02T11:22:33Z",
      "tokens": {
        "access_token": "\(dummyJWT(exp: expiresAt))",
        "refresh_token": "refresh-token",
        "id_token": "id-token"
      }
    }
    """.utf8)

    let credential = try CodexCredentialParser().parse(credentialJSON)

    #expect(credential.accessToken == dummyJWT(exp: expiresAt))
    #expect(credential.accountID == nil)
    #expect(credential.expiresAt == expiresAt)
}

@Test
func codexCredentialParserThrowsParseFailureWhenJWTExpiryIsMissing() throws {
    let credentialJSON = Data("""
    {
      "tokens": {
        "access_token": "\(dummyJWT(payload: #"{"sub":"user"}"#))",
        "account_id": "account-123"
      }
    }
    """.utf8)

    try expectParseFailure {
        _ = try CodexCredentialParser().parse(credentialJSON)
    }
}

private func dummyJWT(exp: Date) -> String {
    dummyJWT(payload: #"{"exp":\#(Int(exp.timeIntervalSince1970))}"#)
}

private func dummyJWT(payload: String) -> String {
    let header = base64URL(#"{"alg":"none"}"#)

    return "\(header).\(base64URL(payload))."
}

private func base64URL(_ string: String) -> String {
    Data(string.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func expectParseFailure(_ operation: () throws -> Void) throws {
    do {
        try operation()
        Issue.record("Expected parse failure")
    } catch UsageParsingError.parseFailure {
        return
    } catch {
        Issue.record("Expected UsageParsingError.parseFailure, got \(error)")
    }
}

@Test
func codexCredentialParserThrowsParseFailureWhenAccessTokenIsEmpty() throws {
    let credentialJSON = Data("""
    {
      "tokens": {
        "access_token": "",
        "account_id": "account-123"
      }
    }
    """.utf8)

    try expectParseFailure {
        _ = try CodexCredentialParser().parse(credentialJSON)
    }
}

@Test
func codexCredentialParserTreatsBlankAccountIDAsMissing() throws {
    let credentialJSON = Data("""
    {
      "tokens": {
        "access_token": "\(dummyJWT(exp: Date(timeIntervalSince1970: 1_783_006_145)))",
        "account_id": "  "
      }
    }
    """.utf8)

    let credential = try CodexCredentialParser().parse(credentialJSON)

    #expect(credential.accountID == nil)
}
