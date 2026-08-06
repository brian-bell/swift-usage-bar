import Foundation
import Testing
import UsageCore

@Test
func openCodeAuthFileReaderReturnsKeyFromPresentFile() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try writeAuthFile(at: fileURL, key: "sk-test")

    let reader = OpenCodeAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .fresh(MiniMaxCredential(key: "sk-test")))
}

@Test
func openCodeAuthFileReaderIsCredentialUnavailableWhenFileIsAbsent() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = OpenCodeAuthFileCredentialReader(
        fileURL: directory.appendingPathComponent("auth.json")
    )

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

@Test
func openCodeAuthFileReaderIsCredentialUnavailableWhenJSONIsMalformed() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try Data("not json".utf8).write(to: fileURL)

    let reader = OpenCodeAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

@Test
func openCodeAuthFileReaderIsCredentialUnavailableWhenEntryMissing() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try Data("{}".utf8).write(to: fileURL)

    let reader = OpenCodeAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

@Test
func openCodeAuthFileReaderIsCredentialUnavailableWhenKeyIsEmpty() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try writeAuthFile(at: fileURL, key: "")

    let reader = OpenCodeAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

@Test
func openCodeAuthFileReaderIgnoresNonAPITypes() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try writeAuthFile(at: fileURL, key: "sk-test", type: "oauth")

    let reader = OpenCodeAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .fresh(MiniMaxCredential(key: "sk-test")))
}

@Test
func openCodeAuthFileReaderDefaultsHonorXDGDataHome() throws {
    let dataHome = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dataHome) }
    let opencodeDir = dataHome.appendingPathComponent("opencode", isDirectory: true)
    try FileManager.default.createDirectory(at: opencodeDir, withIntermediateDirectories: true)
    try writeAuthFile(at: opencodeDir.appendingPathComponent("auth.json"), key: "sk-xdg")

    let reader = OpenCodeAuthFileCredentialReader(
        environment: ["XDG_DATA_HOME": dataHome.path],
        homeDirectory: URL(fileURLWithPath: "/nonexistent-home")
    )

    #expect(try reader.read(mode: .background) == .fresh(MiniMaxCredential(key: "sk-xdg")))
}

@Test
func openCodeAuthFileReaderDefaultsFallBackToHome() throws {
    let home = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let authDir = home
        .appendingPathComponent(".local", isDirectory: true)
        .appendingPathComponent("share", isDirectory: true)
        .appendingPathComponent("opencode", isDirectory: true)
    try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
    try writeAuthFile(at: authDir.appendingPathComponent("auth.json"), key: "sk-home")

    let reader = OpenCodeAuthFileCredentialReader(environment: [:], homeDirectory: home)

    #expect(try reader.read(mode: .background) == .fresh(MiniMaxCredential(key: "sk-home")))
}

@Test
func openCodeAuthFileReaderDefaultsTreatEmptyXDGDataHomeAsUnset() throws {
    let home = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let authDir = home
        .appendingPathComponent(".local", isDirectory: true)
        .appendingPathComponent("share", isDirectory: true)
        .appendingPathComponent("opencode", isDirectory: true)
    try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
    try writeAuthFile(at: authDir.appendingPathComponent("auth.json"), key: "sk-empty-xdg")

    let reader = OpenCodeAuthFileCredentialReader(
        environment: ["XDG_DATA_HOME": ""],
        homeDirectory: home
    )

    #expect(try reader.read(mode: .background) == .fresh(MiniMaxCredential(key: "sk-empty-xdg")))
}

@Test
func openCodeAuthFileReaderAcceptsButIgnoresMode() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("auth.json")
    try writeAuthFile(at: fileURL, key: "sk-mode")

    let reader = OpenCodeAuthFileCredentialReader(fileURL: fileURL)

    #expect(try reader.read(mode: .background) == .fresh(MiniMaxCredential(key: "sk-mode")))
    #expect(try reader.read(mode: .interactive) == .fresh(MiniMaxCredential(key: "sk-mode")))
}

@Test
func miniMaxCredentialReadingProtocolExposesOnlyRead() throws {
    struct ReadOnlyReader: MiniMaxCredentialReading {
        func read(mode _: CredentialAccessMode) throws -> MiniMaxCredentialReadResult {
            .stale(reason: .credentialUnavailable)
        }
    }

    let reader: any MiniMaxCredentialReading = ReadOnlyReader()

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

private func writeAuthFile(at fileURL: URL, key: String, type: String = "api") throws {
    let payload = Data("""
    {
      "\(OpenCodeAuthFileCredentialReader.entryKey)": {
        "type": "\(type)",
        "key": "\(key)"
      }
    }
    """.utf8)
    try payload.write(to: fileURL)
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("opencode-auth-file-reader-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    return directory
}
