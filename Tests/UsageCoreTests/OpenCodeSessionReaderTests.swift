import Foundation
import Testing
import UsageCore

@Test
func chromeSessionReaderFiltersCookieNamesAndForwardsCredentialMode() throws {
    let cookies = StubChromeCookieReading(records: [
        ChromeCookieRecord(name: "analytics", encryptedValue: Data([1])),
        ChromeCookieRecord(name: "auth", encryptedValue: Data([2])),
    ])
    let safeStorage = RecordingChromeSafeStorageReading(password: Data("password".utf8))
    let reader = ChromeOpenCodeSessionReader(
        cookieReader: cookies,
        safeStorageReader: safeStorage,
        decrypt: { encrypted, _ in encrypted == Data([2]) ? "session-value" : nil }
    )

    let session = try reader.readSession(mode: .interactive)

    #expect(session == OpenCodeSession(authenticationCookie: "auth=session-value"))
    #expect(safeStorage.modes == [.interactive])
}

@Test
func chromeSessionReaderDoesNotReadSafeStorageWithoutAnOpenCodeCookie() throws {
    let safeStorage = RecordingChromeSafeStorageReading(password: Data("password".utf8))
    let reader = ChromeOpenCodeSessionReader(
        cookieReader: StubChromeCookieReading(records: [
            ChromeCookieRecord(name: "analytics", encryptedValue: Data([1])),
        ]),
        safeStorageReader: safeStorage
    )

    #expect(try reader.readSession(mode: .background) == nil)
    #expect(safeStorage.modes.isEmpty)
}

@Test(arguments: ["contains;another=cookie", "contains\nnewline", "contains\rreturn", ""])
func chromeSessionReaderRejectsUnsafeDecryptedCookieValues(_ value: String) throws {
    let reader = ChromeOpenCodeSessionReader(
        cookieReader: StubChromeCookieReading(records: [
            ChromeCookieRecord(name: "auth", encryptedValue: Data([1])),
        ]),
        safeStorageReader: RecordingChromeSafeStorageReading(password: Data("password".utf8)),
        decrypt: { _, _ in value }
    )

    #expect(try reader.readSession(mode: .interactive) == nil)
}

private struct StubChromeCookieReading: ChromeOpenCodeCookieReading {
    let records: [ChromeCookieRecord]
    func readCookies() throws -> [ChromeCookieRecord] { records }
}

private final class RecordingChromeSafeStorageReading: ChromeSafeStorageReading, @unchecked Sendable {
    let password: Data?
    private(set) var modes: [CredentialAccessMode] = []

    init(password: Data?) { self.password = password }

    func readPassword(mode: CredentialAccessMode) throws -> Data? {
        modes.append(mode)
        return password
    }
}
