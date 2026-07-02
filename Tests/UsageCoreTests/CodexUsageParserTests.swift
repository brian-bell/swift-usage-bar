import Foundation
import Testing
import UsageCore

@Test
func codexParserMapsFixture() throws {
    let usage = try CodexUsageParser().parse(fixtureData("codex-usage.json"))

    #expect(usage.fiveHour.percentRemaining == 88)
    #expect(usage.fiveHour.resetsAt == Date(timeIntervalSince1970: 1_783_006_145))
    #expect(usage.weekly.percentRemaining == 56)
    #expect(usage.weekly.resetsAt == Date(timeIntervalSince1970: 1_783_388_608))
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
