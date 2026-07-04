import Foundation
import Testing
import UsageCore

@Test
func claudeCredentialParserParsesKeychainCredential() throws {
    let credential = try ClaudeCredentialParser().parse(claudeCredentialData(
        accessToken: "access-token",
        expiresAt: "1783154084847"
    ))

    #expect(credential == ClaudeCredential(
        accessToken: "access-token",
        expiresAt: Date(timeIntervalSince1970: 1_783_154_084.847)
    ))
}

@Test
func claudeCredentialParserThrowsParseFailureForBlankAccessToken() {
    #expect(throws: UsageParsingError.parseFailure) {
        try ClaudeCredentialParser().parse(claudeCredentialData(
            accessToken: "  ",
            expiresAt: "1783154084847"
        ))
    }
}

@Test
func claudeCredentialParserThrowsParseFailureForMissingOAuthObject() {
    #expect(throws: UsageParsingError.parseFailure) {
        try ClaudeCredentialParser().parse(Data(#"{"otherKey": {}}"#.utf8))
    }
}

@Test
func claudeCredentialParserThrowsParseFailureForNonNumericExpiresAt() {
    #expect(throws: UsageParsingError.parseFailure) {
        try ClaudeCredentialParser().parse(claudeCredentialData(
            accessToken: "access-token",
            expiresAt: #""2026-07-04T00:34:44Z""#
        ))
    }
}

@Test
func claudeCredentialParserThrowsParseFailureForNonJSONData() {
    #expect(throws: UsageParsingError.parseFailure) {
        try ClaudeCredentialParser().parse(Data("not json".utf8))
    }
}

private func claudeCredentialData(accessToken: String, expiresAt: String) -> Data {
    Data("""
    {
      "claudeAiOauth": {
        "accessToken": "\(accessToken)",
        "refreshToken": "refresh-token",
        "expiresAt": \(expiresAt),
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": "max",
        "rateLimitTier": "tier"
      }
    }
    """.utf8)
}
