import Foundation
import Testing
import UsageCore

@Test
func miniMaxParserParsesSanitizedFixture() throws {
    let usage = try MiniMaxTokenPlanParser().parse(fixtureData("minimax-token-plan.json"))

    #expect(usage.fiveHour.percentRemaining == 100)
    #expect(usage.weekly.percentRemaining == 99)
    #expect(epochSeconds(usage.fiveHour.resetsAt) == 1_786_046_400)
    #expect(epochSeconds(usage.weekly.resetsAt) == 1_786_320_000)
    #expect(usage.monthly == nil)
}

@Test
func miniMaxParserIgnoresVideoEntryAndSelectsGeneral() throws {
    let usage = try MiniMaxTokenPlanParser().parse(
        tokenPlanBody(entries: [generalEntry(), videoEntry()])
    )

    #expect(usage.fiveHour.percentRemaining == 100)
    #expect(usage.weekly.percentRemaining == 99)
}

@Test
func miniMaxParserThrowsAuthFailureOn1004() {
    #expect(throws: MiniMaxTokenPlanParser.AuthFailure.rejectedKey) {
        try MiniMaxTokenPlanParser().parse(fixtureData("minimax-token-plan-auth-failure.json"))
    }
}

@Test
func miniMaxParserFailsOnOtherNonZeroStatusCode() {
    #expect(throws: UsageParsingError.parseFailure) {
        try MiniMaxTokenPlanParser().parse(tokenPlanBody(statusCode: 7))
    }
}

@Test
func miniMaxParserConvertsEpochMillisecondsToResetsAt() throws {
    let usage = try MiniMaxTokenPlanParser().parse(
        tokenPlanBody(entries: [generalEntry(
            endTime: 1_786_046_400_000,
            weeklyEndTime: 1_786_320_000_000
        )])
    )

    #expect(epochSeconds(usage.fiveHour.resetsAt) == 1_786_046_400)
    #expect(epochSeconds(usage.weekly.resetsAt) == 1_786_320_000)
}

@Test
func miniMaxParserToleratesMalformedSiblingEntries() throws {
    let body = Data("""
    {
      "model_remains": [
        {
          "model_name": "general",
          "end_time": 1786046400000,
          "current_interval_remaining_percent": 100,
          "weekly_end_time": 1786320000000,
          "current_weekly_remaining_percent": 99
        },
        {
          "model_name": 123,
          "end_time": "not-a-number"
        }
      ],
      "base_resp": { "status_code": 0 }
    }
    """.utf8)

    let usage = try MiniMaxTokenPlanParser().parse(body)

    #expect(usage.fiveHour.percentRemaining == 100)
    #expect(usage.weekly.percentRemaining == 99)
}

@Test
func miniMaxParserRejectsPercentOutOfRange() {
    // Only finite out-of-range values: NaN/Infinity cannot be encoded as JSON
    // numbers, so interpolating them would only re-test undecodable bodies.
    let cases: [Double] = [150, -5]

    for percent in cases {
        #expect(throws: UsageParsingError.parseFailure) {
            try MiniMaxTokenPlanParser().parse(
                tokenPlanBody(entries: [generalEntry(intervalPercent: percent)])
            )
        }
    }
}

@Test
func miniMaxParserAcceptsUnknownResetWithValidPercent() throws {
    let usage = try MiniMaxTokenPlanParser().parse(
        tokenPlanBody(entries: [generalEntry(endTime: nil, weeklyEndTime: nil)])
    )

    #expect(usage.fiveHour.percentRemaining == 100)
    #expect(usage.fiveHour.resetsAt == nil)
    #expect(usage.weekly.percentRemaining == 99)
    #expect(usage.weekly.resetsAt == nil)
}

@Test
func miniMaxParserFailsOnMissingGeneralEntry() {
    #expect(throws: UsageParsingError.parseFailure) {
        try MiniMaxTokenPlanParser().parse(tokenPlanBody(entries: [videoEntry()]))
    }
    #expect(throws: UsageParsingError.parseFailure) {
        try MiniMaxTokenPlanParser().parse(tokenPlanBody(entries: []))
    }
}

@Test
func miniMaxParserFailsOnUndecodableBody() {
    let bodies: [Data] = [
        Data("not json".utf8),
        Data("{}".utf8),
    ]

    for body in bodies {
        #expect(throws: UsageParsingError.parseFailure) {
            try MiniMaxTokenPlanParser().parse(body)
        }
    }
}

@Test
func miniMaxParserFailsOnMissingPercentFields() {
    let missingInterval = Data("""
    {
      "model_remains": [
        {
          "model_name": "general",
          "end_time": 1786046400000,
          "weekly_end_time": 1786320000000,
          "current_weekly_remaining_percent": 99
        }
      ],
      "base_resp": { "status_code": 0 }
    }
    """.utf8)
    let missingWeekly = Data("""
    {
      "model_remains": [
        {
          "model_name": "general",
          "end_time": 1786046400000,
          "current_interval_remaining_percent": 100,
          "weekly_end_time": 1786320000000
        }
      ],
      "base_resp": { "status_code": 0 }
    }
    """.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try MiniMaxTokenPlanParser().parse(missingInterval)
    }
    #expect(throws: UsageParsingError.parseFailure) {
        try MiniMaxTokenPlanParser().parse(missingWeekly)
    }
}

private func tokenPlanBody(
    statusCode: Int = 0,
    entries: [String] = [generalEntry()]
) -> Data {
    let joined = entries.joined(separator: ",\n")
    return Data("""
    {
      "model_remains": [
        \(joined)
      ],
      "base_resp": { "status_code": \(statusCode) }
    }
    """.utf8)
}

private func generalEntry(
    endTime: Int64? = 1_786_046_400_000,
    weeklyEndTime: Int64? = 1_786_320_000_000,
    intervalPercent: Double = 100,
    weeklyPercent: Double = 99
) -> String {
    let endTimeJSON = endTime.map(String.init) ?? "null"
    let weeklyEndTimeJSON = weeklyEndTime.map(String.init) ?? "null"
    return """
    {
      "model_name": "general",
      "end_time": \(endTimeJSON),
      "current_interval_remaining_percent": \(intervalPercent),
      "weekly_end_time": \(weeklyEndTimeJSON),
      "current_weekly_remaining_percent": \(weeklyPercent)
    }
    """
}

private func videoEntry() -> String {
    """
    {
      "model_name": "video",
      "end_time": 1786046400000,
      "current_interval_remaining_percent": 50,
      "weekly_end_time": 1786320000000,
      "current_weekly_remaining_percent": 50
    }
    """
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
