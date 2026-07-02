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

@Test
func claudeParserThrowsParseFailureWhenWeeklyLimitIsMissing() throws {
    let data = Data("""
    {
      "rate_limits": {
        "five_hour": {
          "used_percentage": 38,
          "resets_at": 1783008000
        }
      }
    }
    """.utf8)

    try expectParseFailure {
        _ = try ClaudeStatuslineParser().parse(data)
    }
}

@Test
func claudeParserClampsOverusedWindowsToZeroRemaining() throws {
    let data = Data("""
    {
      "rate_limits": {
        "five_hour": {
          "used_percentage": 105,
          "resets_at": 1783008000
        },
        "seven_day": {
          "used_percentage": 19,
          "resets_at": 1783555200
        }
      }
    }
    """.utf8)

    let usage = try ClaudeStatuslineParser().parse(data)

    #expect(usage.fiveHour.percentRemaining == 0)
    #expect(usage.weekly.percentRemaining == 81)
}

@Test
func claudeParserClampsExtremeNegativeUsedPercentageToFullRemaining() throws {
    let data = Data("""
    {
      "rate_limits": {
        "five_hour": {
          "used_percentage": -9223372036854775808,
          "resets_at": 1783008000
        },
        "seven_day": {
          "used_percentage": 19,
          "resets_at": 1783555200
        }
      }
    }
    """.utf8)

    let usage = try ClaudeStatuslineParser().parse(data)

    #expect(usage.fiveHour.percentRemaining == 100)
    #expect(usage.weekly.percentRemaining == 81)
}

@Test
func claudeParserIgnoresNullOrAbsentModelSpecificWeeklyLimits() throws {
    let nullModelSpecificLimitData = Data("""
    {
      "rate_limits": {
        "five_hour": {
          "used_percentage": 38,
          "resets_at": 1783008000
        },
        "seven_day": {
          "used_percentage": 19,
          "resets_at": 1783555200
        },
        "seven_day_sonnet": null
      }
    }
    """.utf8)

    let usageWithNullModelSpecificLimit = try ClaudeStatuslineParser()
        .parse(nullModelSpecificLimitData)

    #expect(usageWithNullModelSpecificLimit.fiveHour.percentRemaining == 62)
    #expect(usageWithNullModelSpecificLimit.weekly.percentRemaining == 81)

    let absentModelSpecificLimitsData = Data("""
    {
      "rate_limits": {
        "five_hour": {
          "used_percentage": 38,
          "resets_at": 1783008000
        },
        "seven_day": {
          "used_percentage": 19,
          "resets_at": 1783555200
        }
      }
    }
    """.utf8)

    let usageWithAbsentModelSpecificLimits = try ClaudeStatuslineParser()
        .parse(absentModelSpecificLimitsData)

    #expect(usageWithAbsentModelSpecificLimits.fiveHour.percentRemaining == 62)
    #expect(usageWithAbsentModelSpecificLimits.weekly.percentRemaining == 81)
}

@Test
func claudeParserThrowsParseFailureForMalformedJSON() throws {
    let data = Data(#"{"rate_limits": "#.utf8)

    try expectParseFailure {
        _ = try ClaudeStatuslineParser().parse(data)
    }
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

private func expectParseFailure(_ operation: () throws -> Void) throws {
    do {
        try operation()
        Issue.record("Expected parse failure")
    } catch UsageParsingError.parseFailure {
        return
    } catch {
        Issue.record("Expected UsageParsingError.parseFailure, got \(error)")
    }
}
