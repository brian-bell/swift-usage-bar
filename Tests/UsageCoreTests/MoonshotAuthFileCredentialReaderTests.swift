import Foundation
import Testing
import UsageCore

@Test
func moonshotAuthFileReaderReturnsKeyFromPresentFile() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try writeAuthFile(at: fileURL, entries: [
        MoonshotAuthFileCredentialReader.entryKey: ("api", "sk-moonshot"),
    ])

    let reader = MoonshotAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .fresh(KimiOpenPlatformCredential(key: "sk-moonshot")))
}

@Test
func moonshotAuthFileReaderIgnoresChinaAndKimiCodeEntries() throws {
    // `moonshotai-cn` and `kimi-for-coding` are different products. A file
    // that only has those must not authenticate the Open Platform provider.
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try writeAuthFile(at: fileURL, entries: [
        "moonshotai-cn": ("api", "sk-cn"),
        "kimi-for-coding": ("api", "sk-code"),
        "minimax-coding-plan": ("api", "sk-minimax"),
    ])

    let reader = MoonshotAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

@Test
func moonshotAuthFileReaderIsCredentialUnavailableWhenFileIsAbsent() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = MoonshotAuthFileCredentialReader(
        fileURL: directory.appendingPathComponent("auth.json")
    )

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

@Test
func moonshotAuthFileReaderIsCredentialUnavailableWhenJSONIsMalformed() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try Data("not json".utf8).write(to: fileURL)

    let reader = MoonshotAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

@Test
func moonshotAuthFileReaderIsCredentialUnavailableWhenEntryMissing() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try Data("{}".utf8).write(to: fileURL)

    let reader = MoonshotAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

@Test
func moonshotAuthFileReaderIsCredentialUnavailableWhenKeyIsEmpty() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try writeAuthFile(at: fileURL, entries: [
        MoonshotAuthFileCredentialReader.entryKey: ("api", ""),
    ])

    let reader = MoonshotAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

@Test
func moonshotAuthFileReaderIgnoresNonAPITypes() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try writeAuthFile(at: fileURL, entries: [
        MoonshotAuthFileCredentialReader.entryKey: ("oauth", "sk-moonshot"),
    ])

    let reader = MoonshotAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .fresh(KimiOpenPlatformCredential(key: "sk-moonshot")))
}

@Test
func moonshotAuthFileReaderDefaultsHonorXDGDataHome() throws {
    let dataHome = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dataHome) }
    let opencodeDir = dataHome.appendingPathComponent("opencode", isDirectory: true)
    try FileManager.default.createDirectory(at: opencodeDir, withIntermediateDirectories: true)
    try writeAuthFile(
        at: opencodeDir.appendingPathComponent("auth.json"),
        entries: [MoonshotAuthFileCredentialReader.entryKey: ("api", "sk-xdg")]
    )

    let reader = MoonshotAuthFileCredentialReader(
        environment: ["XDG_DATA_HOME": dataHome.path],
        homeDirectory: URL(fileURLWithPath: "/nonexistent-home")
    )

    #expect(try reader.read(mode: .background) == .fresh(KimiOpenPlatformCredential(key: "sk-xdg")))
}

@Test
func moonshotAuthFileReaderDefaultsFallBackToHome() throws {
    let home = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let authDir = home
        .appendingPathComponent(".local", isDirectory: true)
        .appendingPathComponent("share", isDirectory: true)
        .appendingPathComponent("opencode", isDirectory: true)
    try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
    try writeAuthFile(
        at: authDir.appendingPathComponent("auth.json"),
        entries: [MoonshotAuthFileCredentialReader.entryKey: ("api", "sk-home")]
    )

    let reader = MoonshotAuthFileCredentialReader(environment: [:], homeDirectory: home)

    #expect(try reader.read(mode: .background) == .fresh(KimiOpenPlatformCredential(key: "sk-home")))
}

@Test
func moonshotAuthFileReaderDefaultsTreatEmptyXDGDataHomeAsUnset() throws {
    let home = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let authDir = home
        .appendingPathComponent(".local", isDirectory: true)
        .appendingPathComponent("share", isDirectory: true)
        .appendingPathComponent("opencode", isDirectory: true)
    try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
    try writeAuthFile(
        at: authDir.appendingPathComponent("auth.json"),
        entries: [MoonshotAuthFileCredentialReader.entryKey: ("api", "sk-empty-xdg")]
    )

    let reader = MoonshotAuthFileCredentialReader(
        environment: ["XDG_DATA_HOME": ""],
        homeDirectory: home
    )

    #expect(try reader.read(mode: .background) == .fresh(KimiOpenPlatformCredential(key: "sk-empty-xdg")))
}

@Test
func moonshotAuthFileReaderAcceptsButIgnoresMode() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try writeAuthFile(at: fileURL, entries: [
        MoonshotAuthFileCredentialReader.entryKey: ("api", "sk-mode"),
    ])

    let reader = MoonshotAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .fresh(KimiOpenPlatformCredential(key: "sk-mode")))
    #expect(try reader.read(mode: .interactive) == .fresh(KimiOpenPlatformCredential(key: "sk-mode")))
}

@Test
func kimiOpenPlatformCredentialReadingProtocolExposesOnlyRead() throws {
    struct ReadOnlyReader: KimiOpenPlatformCredentialReading {
        func read(mode _: CredentialAccessMode) throws -> KimiOpenPlatformCredentialReadResult {
            .stale(reason: .credentialUnavailable)
        }
    }

    let reader: any KimiOpenPlatformCredentialReading = ReadOnlyReader()

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

private func writeAuthFile(
    at fileURL: URL,
    entries: [String: (type: String, key: String)]
) throws {
    let objects = entries.map { key, value in
        "\"\(key)\": {\"type\": \"\(value.type)\", \"key\": \"\(value.key)\"}"
    }.joined(separator: ",\n")
    try Data("{\n\(objects)\n}".utf8).write(to: fileURL)
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("moonshot-auth-file-reader-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
