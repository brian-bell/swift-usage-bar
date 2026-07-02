import Foundation
import Testing
import UsageCore

@Test
func claudeStatuslineCacheReaderReturnsFreshDataFromRecentCacheFile() throws {
    let fixture = try fixtureData("claude-statusline.json")
    let cacheURL = try writeTemporaryCacheFile(
        data: fixture,
        modifiedAt: Date(timeIntervalSince1970: 1_783_000_000)
    )
    let reader = ClaudeStatuslineCacheReader(cacheURL: cacheURL, maximumAge: 300)

    let result = try reader.read(now: Date(timeIntervalSince1970: 1_783_000_120))

    #expect(result == .fresh(
        data: fixture,
        usage: ProviderUsage(
            fiveHour: UsageWindow(
                percentRemaining: 62,
                resetsAt: Date(timeIntervalSince1970: 1_783_008_000)
            ),
            weekly: UsageWindow(
                percentRemaining: 81,
                resetsAt: Date(timeIntervalSince1970: 1_783_555_200)
            )
        ),
        asOf: Date(timeIntervalSince1970: 1_783_000_000)
    ))
}

@Test
func claudeStatuslineCacheReaderReturnsStaleHintWhenCacheFileIsMissing() throws {
    let missingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("claude-status.json")
    let reader = ClaudeStatuslineCacheReader(cacheURL: missingURL, maximumAge: 300)

    let result = try reader.read(now: Date(timeIntervalSince1970: 1_783_000_120))

    #expect(result == .stale(
        last: nil,
        reason: .networkError,
        hint: "Configure Claude Code statusline to write its cache."
    ))
}

@Test
func claudeStatuslineCacheReaderReturnsLastKnownUsageWhenCacheFileIsOld() throws {
    let cacheURL = try writeTemporaryCacheFile(
        data: fixtureData("claude-statusline.json"),
        modifiedAt: Date(timeIntervalSince1970: 1_783_000_000)
    )
    let reader = ClaudeStatuslineCacheReader(cacheURL: cacheURL, maximumAge: 300)

    let result = try reader.read(now: Date(timeIntervalSince1970: 1_783_000_301))

    #expect(result == .stale(
        last: ProviderUsage(
            fiveHour: UsageWindow(
                percentRemaining: 62,
                resetsAt: Date(timeIntervalSince1970: 1_783_008_000)
            ),
            weekly: UsageWindow(
                percentRemaining: 81,
                resetsAt: Date(timeIntervalSince1970: 1_783_555_200)
            )
        ),
        reason: .networkError,
        hint: "Configure Claude Code statusline to write its cache."
    ))
}

private func writeTemporaryCacheFile(data: Data, modifiedAt: Date) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let fileURL = directory.appendingPathComponent("claude-status.json")
    try data.write(to: fileURL)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: fileURL.path)

    return fileURL
}

private func fixtureData(_ name: String) throws -> Data {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtureURL = packageRoot
        .appendingPathComponent("Tests")
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)

    return try Data(contentsOf: fixtureURL)
}
