import Foundation
import Testing
import UsageCore

@Test
func claudeWebReaderBuildsCookieHeaderRequiringSessionKeyAndExtractsOrgHint() throws {
    let cookies = StubClaudeWebCookieReading(records: [
        ChromeCookieRecord(name: "cf_clearance", encryptedValue: Data([3])),
        ChromeCookieRecord(name: "sessionKey", encryptedValue: Data([1])),
        ChromeCookieRecord(name: "lastActiveOrg", encryptedValue: Data([2])),
    ])
    let safeStorage = RecordingClaudeSafeStorage(password: Data("password".utf8))
    let reader = ChromeClaudeWebSessionReader(
        cookieReader: cookies,
        safeStorageReader: safeStorage,
        decrypt: { encrypted, _ in
            switch encrypted {
            case Data([1]): return "sk-ant-sid02-abc"
            case Data([2]): return "07061dc0-3e1d-455a-aea0-ab46aa4e46f8"
            case Data([3]): return "clearance-token"
            default: return nil
            }
        }
    )

    let session = try #require(try reader.readSession(mode: .interactive))

    // sessionKey leads; org hint comes from lastActiveOrg.
    #expect(session.cookieHeader ==
        "sessionKey=sk-ant-sid02-abc; lastActiveOrg=07061dc0-3e1d-455a-aea0-ab46aa4e46f8; cf_clearance=clearance-token")
    #expect(session.organizationHint == "07061dc0-3e1d-455a-aea0-ab46aa4e46f8")
    #expect(safeStorage.modes == [.interactive])
}

@Test
func claudeWebReaderReturnsNilAndSkipsSafeStorageWithoutSessionKey() throws {
    let safeStorage = RecordingClaudeSafeStorage(password: Data("password".utf8))
    let reader = ChromeClaudeWebSessionReader(
        cookieReader: StubClaudeWebCookieReading(records: [
            ChromeCookieRecord(name: "lastActiveOrg", encryptedValue: Data([2])),
            ChromeCookieRecord(name: "cf_clearance", encryptedValue: Data([3])),
        ]),
        safeStorageReader: safeStorage
    )

    #expect(try reader.readSession(mode: .background) == nil)
    #expect(safeStorage.modes.isEmpty)
}

@Test
func claudeWebReaderReturnsNilWhenSessionKeyDecryptsToUnsafeValue() throws {
    let reader = ChromeClaudeWebSessionReader(
        cookieReader: StubClaudeWebCookieReading(records: [
            ChromeCookieRecord(name: "sessionKey", encryptedValue: Data([1])),
        ]),
        safeStorageReader: RecordingClaudeSafeStorage(password: Data("password".utf8)),
        decrypt: { _, _ in "contains;semicolon" }
    )

    #expect(try reader.readSession(mode: .interactive) == nil)
}

@Test
func claudeWebReaderBuildsSessionWithoutOrgHintWhenLastActiveOrgMissing() throws {
    let reader = ChromeClaudeWebSessionReader(
        cookieReader: StubClaudeWebCookieReading(records: [
            ChromeCookieRecord(name: "sessionKey", encryptedValue: Data([1])),
        ]),
        safeStorageReader: RecordingClaudeSafeStorage(password: Data("password".utf8)),
        decrypt: { _, _ in "sk-ant-sid02-abc" }
    )

    let session = try #require(try reader.readSession(mode: .background))
    #expect(session.cookieHeader == "sessionKey=sk-ant-sid02-abc")
    #expect(session.organizationHint == nil)
}

@Test
func claudeWebReaderKeepsCookieSetsWithinTheirChromeProfile() throws {
    let reader = ChromeClaudeWebSessionReader(
        cookieReader: ProfiledClaudeCookieReader(profiles: [
            [
                ChromeCookieRecord(name: "sessionKey", encryptedValue: Data([1])),
                ChromeCookieRecord(name: "cf_clearance", encryptedValue: Data([2])),
            ],
            [
                ChromeCookieRecord(name: "sessionKey", encryptedValue: Data([3])),
                ChromeCookieRecord(name: "lastActiveOrg", encryptedValue: Data([4])),
            ],
        ]),
        safeStorageReader: RecordingClaudeSafeStorage(password: Data("password".utf8)),
        decrypt: { encrypted, _ in
            switch encrypted {
            case Data([1]): return "profile-one-session"
            case Data([2]): return "profile-one-clearance"
            case Data([3]): return "profile-two-session"
            case Data([4]): return "profile-two-org"
            default: return nil
            }
        }
    )

    let sessions = try reader.readSessions(mode: .background)

    #expect(sessions.map(\.cookieHeader) == [
        "sessionKey=profile-one-session; cf_clearance=profile-one-clearance",
        "sessionKey=profile-two-session; lastActiveOrg=profile-two-org",
    ])
    #expect(sessions.map(\.organizationHint) == [nil, "profile-two-org"])
}

private struct StubClaudeWebCookieReading: ChromeClaudeWebCookieReading {
    let records: [ChromeCookieRecord]
    func readCookies() throws -> [ChromeCookieRecord] { records }
}

private struct ProfiledClaudeCookieReader: ChromeClaudeWebCookieReading, ChromeClaudeWebCookieProfileReading {
    let profiles: [[ChromeCookieRecord]]
    func readCookies() throws -> [ChromeCookieRecord] { profiles.flatMap { $0 } }
    func readCookieProfiles() throws -> [[ChromeCookieRecord]] { profiles }
}

private final class RecordingClaudeSafeStorage: ChromeSafeStorageReading, @unchecked Sendable {
    let password: Data?
    private(set) var modes: [CredentialAccessMode] = []

    init(password: Data?) { self.password = password }

    func readPassword(mode: CredentialAccessMode) throws -> Data? {
        modes.append(mode)
        return password
    }
}
