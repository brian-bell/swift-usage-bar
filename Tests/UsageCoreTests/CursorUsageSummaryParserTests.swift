import Foundation
import Testing
import UsageCore

@Test
func cursorParserMapsSanitizedUltraFixtureToBothPools() throws {
    let usage = try CursorUsageSummaryParser().parse(cursorFixtureData("cursor-usage-summary.json"))

    #expect(usage.fiveHour.percentRemaining == nil)
    #expect(usage.weekly.percentRemaining == 95)
    #expect(usage.monthly?.percentRemaining == 90)
    #expect(epochSeconds(usage.weekly.resetsAt) == 1_789_424_885)
    #expect(epochSeconds(usage.monthly?.resetsAt) == 1_789_424_885)
    #expect(usage.credits == nil)
    #expect(usage.fable == nil)
}

@Test
func cursorParserIgnoresUsedLimitWhichDisagreesWithPoolPercents() throws {
    // Live Ultra: used/limit 14366/40000 is 35.9%, but Cursor's own
    // display message rounded apiPercentUsed 10.092 to "10% of API usage".
    let usage = try CursorUsageSummaryParser().parse(cursorFixtureData("cursor-usage-summary.json"))

    #expect(usage.monthly?.percentRemaining != 64)
    #expect(usage.monthly?.percentRemaining == 90)
}

@Test
func cursorParserOmitsCursorModelsWhenAutoPercentIsAbsent() throws {
    let usage = try CursorUsageSummaryParser().parse(cursorSummaryBody(autoPercentUsed: nil))

    #expect(usage.weekly.percentRemaining == nil)
    #expect(usage.monthly?.percentRemaining == 90)
}

@Test
func cursorParserFailsWhenAPIPercentIsMissing() {
    #expect(throws: UsageParsingError.parseFailure) {
        try CursorUsageSummaryParser().parse(cursorSummaryBody(apiPercentUsed: nil))
    }
}

@Test
func cursorParserFailsOnUndecodableBody() {
    for body in [Data("not json".utf8), Data("{}".utf8)] {
        #expect(throws: UsageParsingError.parseFailure) {
            try CursorUsageSummaryParser().parse(body)
        }
    }
}

@Test
func cursorParserAcceptsUnknownResetWithValidAPIPercent() throws {
    let usage = try CursorUsageSummaryParser().parse(
        cursorSummaryBody(billingCycleEnd: nil, autoPercentUsed: 4.66)
    )

    #expect(usage.weekly.percentRemaining == 95)
    #expect(usage.weekly.resetsAt == nil)
    #expect(usage.monthly?.percentRemaining == 90)
    #expect(usage.monthly?.resetsAt == nil)
}

@Test
func cursorParserClampsUsedPercentToRemaining() throws {
    #expect(try CursorUsageSummaryParser().parse(cursorSummaryBody(apiPercentUsed: 0)).monthly?.percentRemaining == 100)
    #expect(try CursorUsageSummaryParser().parse(cursorSummaryBody(apiPercentUsed: 100)).monthly?.percentRemaining == 0)
    #expect(try CursorUsageSummaryParser().parse(cursorSummaryBody(apiPercentUsed: 150)).monthly?.percentRemaining == 0)
}

private func cursorSummaryBody(
    billingCycleEnd: String? = "2026-09-14T22:28:05.000Z",
    apiPercentUsed: Double? = 10.092,
    autoPercentUsed: Double? = 4.66
) -> Data {
    let resetJSON = billingCycleEnd.map { "\"\($0)\"" } ?? "null"
    let apiJSON = apiPercentUsed.map { "\($0)" } ?? "null"
    let autoJSON = autoPercentUsed.map { "\($0)" } ?? "null"
    return Data("""
    {
      "billingCycleEnd": \(resetJSON),
      "individualUsage": {
        "plan": {
          "apiPercentUsed": \(apiJSON),
          "autoPercentUsed": \(autoJSON)
        }
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

func cursorFixtureData(_ name: String) throws -> Data {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(
        contentsOf: packageRoot
            .appendingPathComponent("Tests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    )
}
