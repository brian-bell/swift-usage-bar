import Foundation
import Testing
import UsageCore

@Test
func codexParserMapsFixtureToWeeklyOnly() throws {
    let usage = try CodexUsageParser().parse(fixtureData("codex-usage.json"))

    #expect(usage.fiveHour.percentRemaining == nil)
    #expect(usage.fiveHour.resetsAt == nil)
    #expect(usage.weekly.percentRemaining == 56)
    #expect(usage.weekly.resetsAt == Date(timeIntervalSince1970: 1_783_388_608))
}

@Test
func codexParserIgnoresDeprecatedPrimaryWindow() throws {
    let data = Data("""
    {
      "rate_limit": {
        "primary_window": {
          "reset_at": 1783006145,
          "used_percent": 12
        },
        "secondary_window": {
          "reset_at": 1783388608,
          "used_percent": 44
        }
      }
    }
    """.utf8)

    let usage = try CodexUsageParser().parse(data)

    #expect(usage.fiveHour.percentRemaining == nil)
    #expect(usage.fiveHour.resetsAt == nil)
    #expect(usage.weekly.percentRemaining == 56)
    #expect(usage.weekly.resetsAt == Date(timeIntervalSince1970: 1_783_388_608))
}

@Test
func codexParserUsesPrimaryAsWeeklyWhenSecondaryIsNullAndPrimaryIsWeeklyShaped() throws {
    // Live API (Jul 2026): weekly moved into primary_window; secondary is null.
    let data = Data("""
    {
      "rate_limit": {
        "primary_window": {
          "limit_window_seconds": 604800,
          "reset_at": 1783006145,
          "used_percent": 12
        },
        "secondary_window": null
      }
    }
    """.utf8)

    let usage = try CodexUsageParser().parse(data)

    #expect(usage.fiveHour.percentRemaining == nil)
    #expect(usage.fiveHour.resetsAt == nil)
    #expect(usage.weekly.percentRemaining == 88)
    #expect(usage.weekly.resetsAt == Date(timeIntervalSince1970: 1_783_006_145))
}

@Test
func codexParserUsesPrimaryAsWeeklyWhenSecondaryWindowKeyIsOmittedAndPrimaryIsWeeklyShaped() throws {
    let data = Data("""
    {
      "rate_limit": {
        "primary_window": {
          "limit_window_seconds": 604800,
          "reset_at": 1783006145,
          "used_percent": 12
        }
      }
    }
    """.utf8)

    let usage = try CodexUsageParser().parse(data)

    #expect(usage.fiveHour.percentRemaining == nil)
    #expect(usage.weekly.percentRemaining == 88)
    #expect(usage.weekly.resetsAt == Date(timeIntervalSince1970: 1_783_006_145))
}

@Test
func codexParserThrowsParseFailureWhenOnlyPrimaryIsFiveHourShaped() throws {
    // Legacy/transition: primary is still 5h (18000s) and secondary is gone —
    // must not misreport the 5h percentage as weekly.
    let data = Data("""
    {
      "rate_limit": {
        "primary_window": {
          "limit_window_seconds": 18000,
          "reset_at": 1783006145,
          "used_percent": 12
        },
        "secondary_window": null
      }
    }
    """.utf8)

    try expectParseFailure {
        _ = try CodexUsageParser().parse(data)
    }
}

@Test
func codexParserThrowsParseFailureWhenPrimaryLacksWeeklyDurationAndSecondaryIsAbsent() throws {
    let data = Data("""
    {
      "rate_limit": {
        "primary_window": {
          "reset_at": 1783006145,
          "used_percent": 12
        }
      }
    }
    """.utf8)

    try expectParseFailure {
        _ = try CodexUsageParser().parse(data)
    }
}

@Test
func codexParserThrowsParseFailureWhenBothWindowsAreNull() throws {
    let data = Data("""
    {
      "rate_limit": {
        "primary_window": null,
        "secondary_window": null
      }
    }
    """.utf8)

    try expectParseFailure {
        _ = try CodexUsageParser().parse(data)
    }
}

@Test
func codexParserMapsWeeklyWhenPrimaryLimitIsNull() throws {
    let data = Data("""
    {
      "rate_limit": {
        "primary_window": null,
        "secondary_window": {
          "reset_at": 1783388608,
          "used_percent": 44
        }
      }
    }
    """.utf8)

    let usage = try CodexUsageParser().parse(data)

    #expect(usage.fiveHour.percentRemaining == nil)
    #expect(usage.fiveHour.resetsAt == nil)
    #expect(usage.weekly.percentRemaining == 56)
    #expect(usage.weekly.resetsAt == Date(timeIntervalSince1970: 1_783_388_608))
}

@Test
func codexParserThrowsParseFailureWhenRequiredUsageFieldIsMissing() throws {
    let data = Data("""
    {
      "rate_limit": {
        "primary_window": {
          "reset_at": 1783006145
        },
        "secondary_window": {
          "reset_at": 1783388608
        }
      }
    }
    """.utf8)

    try expectParseFailure {
        _ = try CodexUsageParser().parse(data)
    }
}

@Test
func codexParserClampsWeeklyUsedPercentOutsideExpectedRange() throws {
    let data = Data("""
    {
      "rate_limit": {
        "secondary_window": {
          "reset_at": 1783388608,
          "used_percent": 140
        }
      }
    }
    """.utf8)

    let usage = try CodexUsageParser().parse(data)

    #expect(usage.fiveHour.percentRemaining == nil)
    #expect(usage.weekly.percentRemaining == 0)
}

@Test
func codexParserClampsExtremeNegativeWeeklyUsedPercentToFullRemaining() throws {
    let data = Data("""
    {
      "rate_limit": {
        "secondary_window": {
          "reset_at": 1783388608,
          "used_percent": -9223372036854775808
        }
      }
    }
    """.utf8)

    let usage = try CodexUsageParser().parse(data)

    #expect(usage.fiveHour.percentRemaining == nil)
    #expect(usage.weekly.percentRemaining == 100)
}

@Test
func codexParserThrowsParseFailureForMalformedJSON() throws {
    let data = Data(#"{"rate_limit": "#.utf8)

    try expectParseFailure {
        _ = try CodexUsageParser().parse(data)
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
