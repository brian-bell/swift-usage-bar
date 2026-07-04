import Foundation
import Testing
import UsageCore

@Test
func claudeUsageParserParsesSanitizedFixture() throws {
    let usage = try ClaudeUsageParser().parse(fixtureData("claude-usage.json"))

    #expect(usage.fiveHour.percentRemaining == 89)
    #expect(usage.weekly.percentRemaining == 77)
    #expect(epochSeconds(usage.fiveHour.resetsAt) == 1_783_145_400)
    #expect(epochSeconds(usage.weekly.resetsAt) == 1_783_332_000)
}

@Test
func claudeUsageParserParsesResetsAtWithoutFractionalSeconds() throws {
    let usage = try ClaudeUsageParser().parse(usageBody(
        fiveHourResetsAt: "2026-07-04T06:10:00+00:00",
        sevenDayResetsAt: "2026-07-06T10:00:00Z"
    ))

    #expect(epochSeconds(usage.fiveHour.resetsAt) == 1_783_145_400)
    #expect(epochSeconds(usage.weekly.resetsAt) == 1_783_332_000)
}

@Test
func claudeUsageParserParsesSixDigitFractionalResetsAt() throws {
    let usage = try ClaudeUsageParser().parse(usageBody(
        fiveHourResetsAt: "2026-07-04T06:10:00.229359+00:00",
        sevenDayResetsAt: "2026-07-06T10:00:00.229385+00:00"
    ))

    #expect(epochSeconds(usage.fiveHour.resetsAt) == 1_783_145_400)
    #expect(epochSeconds(usage.weekly.resetsAt) == 1_783_332_000)
}

@Test
func claudeUsageParserParsesShortFractionalResetsAt() throws {
    let usage = try ClaudeUsageParser().parse(usageBody(
        fiveHourResetsAt: "2026-07-04T06:10:00.2+00:00",
        sevenDayResetsAt: "2026-07-06T10:00:00.22Z"
    ))

    #expect(epochSeconds(usage.fiveHour.resetsAt) == 1_783_145_400)
    #expect(epochSeconds(usage.weekly.resetsAt) == 1_783_332_000)
}

@Test
func claudeUsageParserClampsUtilizationToPercentRemainingBounds() throws {
    let cases: [(Double, Int)] = [
        (-5, 100),
        (150, 0),
        (1e300, 0),
        (49.0, 51),
        (7.000000000000001, 93),
    ]

    for (utilization, expectedRemaining) in cases {
        let usage = try ClaudeUsageParser().parse(usageBody(fiveHourUtilization: utilization))

        #expect(usage.fiveHour.percentRemaining == expectedRemaining)
    }
}

@Test
func claudeUsageParserThrowsParseFailureForUnusableBodies() {
    let bodies: [Data] = [
        Data("not json".utf8),
        Data("{}".utf8),
        Data(#"{"five_hour": {"utilization": 11.0, "resets_at": "2026-07-04T06:10:00Z"}}"#.utf8),
        usageBody(fiveHourResetsAt: "not-a-date"),
        Data(#"{"five_hour": {"utilization": 11.0, "resets_at": 1783145400}, "seven_day": {"utilization": 23.0, "resets_at": 1783332000}}"#.utf8),
    ]

    for body in bodies {
        #expect(throws: UsageParsingError.parseFailure) {
            try ClaudeUsageParser().parse(body)
        }
    }
}

private func usageBody(
    fiveHourUtilization: Double = 11.0,
    fiveHourResetsAt: String = "2026-07-04T06:10:00.229359+00:00",
    sevenDayResetsAt: String = "2026-07-06T10:00:00.229385+00:00"
) -> Data {
    Data("""
    {
      "five_hour": {
        "utilization": \(fiveHourUtilization),
        "resets_at": "\(fiveHourResetsAt)"
      },
      "seven_day": {
        "utilization": 23.0,
        "resets_at": "\(sevenDayResetsAt)"
      }
    }
    """.utf8)
}

private func epochSeconds(_ date: Date?) -> Int? {
    guard let date else {
        return nil
    }

    return Int(date.timeIntervalSince1970)
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
