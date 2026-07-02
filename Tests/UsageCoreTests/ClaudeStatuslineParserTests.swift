import Foundation
import Testing
import UsageCore

@Test
func claudeParserMapsFixture() throws {
    let usage = try ClaudeStatuslineParser().parse(fixtureData("claude-statusline.json"))

    #expect(usage.fiveHour.percentRemaining == 62)
    #expect(usage.fiveHour.resetsAt == Date(timeIntervalSince1970: 1_783_008_000))
    #expect(usage.weekly.percentRemaining == 81)
    #expect(usage.weekly.resetsAt == Date(timeIntervalSince1970: 1_783_555_200))
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
