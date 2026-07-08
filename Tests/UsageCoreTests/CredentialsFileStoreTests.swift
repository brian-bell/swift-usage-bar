import Foundation
import Testing
import UsageCore

@Test
func credentialsFileStoreReadsDataFromInjectedFileURL() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent(".credentials.json")
    let payload = Data(#"{"claudeAiOauth": {"accessToken": "file-token"}}"#.utf8)
    try payload.write(to: fileURL)

    let store = ClaudeCredentialsFileStore(fileURL: fileURL)

    #expect(try store.read(.claude) == payload)
}

@Test
func credentialsFileStoreReturnsNilWhenFileIsAbsent() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClaudeCredentialsFileStore(
        fileURL: directory.appendingPathComponent(".credentials.json")
    )

    #expect(try store.read(.claude) == nil)
}

@Test
func credentialsFileStoreThrowsUnavailableWhenFileIsUnreadable() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent(".credentials.json")
    try Data("secret".utf8).write(to: fileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    let store = ClaudeCredentialsFileStore(fileURL: fileURL)

    #expect(throws: CredentialStoreReadError.unavailable) {
        try store.read(.claude)
    }
}

@Test
func credentialsFileStoreDefaultPathHonorsClaudeConfigDir() throws {
    let configDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: configDir) }
    let payload = Data(#"{"claudeAiOauth": {}}"#.utf8)
    try payload.write(to: configDir.appendingPathComponent(".credentials.json"))

    let store = ClaudeCredentialsFileStore(
        environment: ["CLAUDE_CONFIG_DIR": configDir.path],
        homeDirectory: URL(fileURLWithPath: "/nonexistent-home")
    )

    #expect(try store.read(.claude) == payload)
}

@Test
func credentialsFileStoreDefaultPathFallsBackToDotClaudeUnderHome() throws {
    let home = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let configDir = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let payload = Data(#"{"claudeAiOauth": {}}"#.utf8)
    try payload.write(to: configDir.appendingPathComponent(".credentials.json"))

    let store = ClaudeCredentialsFileStore(environment: [:], homeDirectory: home)

    #expect(try store.read(.claude) == payload)
}

@Test
func credentialsFileStoreTreatsEmptyClaudeConfigDirAsUnset() throws {
    let home = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let configDir = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let payload = Data(#"{"claudeAiOauth": {}}"#.utf8)
    try payload.write(to: configDir.appendingPathComponent(".credentials.json"))

    let store = ClaudeCredentialsFileStore(
        environment: ["CLAUDE_CONFIG_DIR": ""],
        homeDirectory: home
    )

    #expect(try store.read(.claude) == payload)
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("credentials-file-store-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    return directory
}
