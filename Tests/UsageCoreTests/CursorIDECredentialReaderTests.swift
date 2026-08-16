import Foundation
import SQLite3
import Testing
import UsageCore

private let freshCursorJWT =
    "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJnb29nbGUtb2F1dGgyfHVzZXJfMDFURVNUQ1VSU09SVVNFUjAwMDAwMDAwMDEiLCJleHAiOjIwMDAwMDAwMDB9.sig"
private let expiredCursorJWT =
    "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJnb29nbGUtb2F1dGgyfHVzZXJfMDFURVNUQ1VSU09SVVNFUjAwMDAwMDAwMDEiLCJleHAiOjF9.sig"
private let cursorNow = Date(timeIntervalSince1970: 1_786_902_874)

@Test
func cursorReaderAccessTokenKeyMatchesObservedIDEStore() {
    #expect(CursorIDECredentialReader.accessTokenKey == "cursorAuth/accessToken")
}

@Test
func cursorReaderDerivesCookieFromFreshIDEToken() throws {
    let databaseURL = try writeCursorStateDatabase(token: freshCursorJWT)
    let reader = CursorIDECredentialReader(databaseURL: databaseURL)

    let result = try reader.read(mode: .background, now: cursorNow)

    guard case let .fresh(credential) = result else {
        Issue.record("expected a fresh credential, got \(result)")
        return
    }
    #expect(credential.accessToken == freshCursorJWT)
    #expect(credential.cookieValue == "user_01TESTCURSORUSER0000000001%3A%3A\(freshCursorJWT)")
    #expect(credential.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
}

@Test
func cursorReaderIsTokenExpiredWhenJWTExpHasPassed() throws {
    let databaseURL = try writeCursorStateDatabase(token: expiredCursorJWT)
    let reader = CursorIDECredentialReader(databaseURL: databaseURL)

    #expect(try reader.read(mode: .background, now: cursorNow) == .stale(reason: .tokenExpired))
}

@Test
func cursorReaderIsCredentialUnavailableWhenDatabaseIsMissing() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("state.vscdb")
    let reader = CursorIDECredentialReader(databaseURL: missing)

    #expect(try reader.read(mode: .background, now: cursorNow) == .stale(reason: .credentialUnavailable))
}

@Test
func cursorReaderIsCredentialUnavailableWhenAccessTokenKeyIsMissing() throws {
    let databaseURL = try writeCursorStateDatabase(token: nil)
    let reader = CursorIDECredentialReader(databaseURL: databaseURL)

    #expect(try reader.read(mode: .background, now: cursorNow) == .stale(reason: .credentialUnavailable))
}

@Test
func cursorReaderIsParseFailureWhenTokenIsNotAJWT() throws {
    let databaseURL = try writeCursorStateDatabase(token: "not-a-jwt")
    let reader = CursorIDECredentialReader(databaseURL: databaseURL)

    #expect(try reader.read(mode: .background, now: cursorNow) == .stale(reason: .parseFailure))
}

private func writeCursorStateDatabase(token: String?) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("state.vscdb")

    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);", nil, nil, nil)
        == SQLITE_OK
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    if let token {
        let sql = "INSERT INTO ItemTable (key, value) VALUES ('\(CursorIDECredentialReader.accessTokenKey)', ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }
        let inserted = token.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, nil)
            return sqlite3_step(statement)
        }
        guard inserted == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    return databaseURL
}
