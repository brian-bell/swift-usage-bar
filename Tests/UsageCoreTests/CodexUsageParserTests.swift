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

@Test
func codexParserThrowsParseFailureWhenWeeklyLimitIsMissing() throws {
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
func codexParserThrowsParseFailureWhenRequiredUsageFieldIsMissing() throws {
    let data = Data("""
    {
      "rate_limit": {
        "primary_window": {
          "reset_at": 1783006145
        },
        "secondary_window": {
          "reset_at": 1783388608,
          "used_percent": 44
        }
      }
    }
    """.utf8)

    try expectParseFailure {
        _ = try CodexUsageParser().parse(data)
    }
}

@Test
func codexParserClampsUsedPercentOutsideExpectedRange() throws {
    let data = Data("""
    {
      "rate_limit": {
        "primary_window": {
          "reset_at": 1783006145,
          "used_percent": 140
        },
        "secondary_window": {
          "reset_at": 1783388608,
          "used_percent": -20
        }
      }
    }
    """.utf8)

    let usage = try CodexUsageParser().parse(data)

    #expect(usage.fiveHour.percentRemaining == 0)
    #expect(usage.weekly.percentRemaining == 100)
}

@Test
func codexParserClampsExtremeNegativeUsedPercentToFullRemaining() throws {
    let data = Data("""
    {
      "rate_limit": {
        "primary_window": {
          "reset_at": 1783006145,
          "used_percent": -9223372036854775808
        },
        "secondary_window": {
          "reset_at": 1783388608,
          "used_percent": 44
        }
      }
    }
    """.utf8)

    let usage = try CodexUsageParser().parse(data)

    #expect(usage.fiveHour.percentRemaining == 100)
    #expect(usage.weekly.percentRemaining == 56)
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
