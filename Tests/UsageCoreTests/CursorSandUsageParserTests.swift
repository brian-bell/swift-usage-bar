import Foundation
import Testing
import UsageCore

@Test
func cursorSandParserMapsSanitizedLiveFixtureToGrokBotWindow() throws {
    let window = try CursorSandUsageParser().parse(cursorFixtureData("cursor-sand-usage-status.json"))

    let grokBot = try #require(window)
    #expect(grokBot.percentRemaining == 88)
    #expect(epochSeconds(grokBot.resetsAt) == 1_789_344_000)
}

@Test
func cursorSandParserIgnoresUpsellOnDemandAndPlanLabels() throws {
    // Live body carries upgrade CTAs, on-demand settings, and plan names.
    // Those are payment/account metadata — the parser must not need them
    // and must not fail if they disappear.
    let window = try CursorSandUsageParser().parse(cursorSandBody())

    #expect(window?.percentRemaining == 88)
}

@Test
func cursorSandParserOmitsWhenIncludedLimitIsZero() throws {
    let window = try CursorSandUsageParser().parse(
        cursorSandBody(hasNonZeroIncludedLimit: false)
    )

    #expect(window == nil)
}

@Test
func cursorSandParserOmitsWhenIncludedLimitFlagIsAbsent() throws {
    let window = try CursorSandUsageParser().parse(
        cursorSandBody(hasNonZeroIncludedLimit: nil)
    )

    #expect(window == nil)
}

@Test
func cursorSandParserFailsWhenIncludedLimitExistsWithoutUsagePercent() {
    #expect(throws: UsageParsingError.parseFailure) {
        try CursorSandUsageParser().parse(
            cursorSandBody(usagePercent: nil, hasNonZeroIncludedLimit: true)
        )
    }
}

@Test
func cursorSandParserFailsOnUndecodableBody() {
    for body in [Data("not json".utf8), Data("[]".utf8)] {
        #expect(throws: UsageParsingError.parseFailure) {
            try CursorSandUsageParser().parse(body)
        }
    }
}

@Test
func cursorSandParserAcceptsUnknownResetWithValidUsagePercent() throws {
    let window = try CursorSandUsageParser().parse(
        cursorSandBody(nextResetTimestampUtc: nil)
    )

    #expect(window?.percentRemaining == 88)
    #expect(window?.resetsAt == nil)
}

@Test
func cursorSandParserClampsUsedPercentToRemaining() throws {
    #expect(
        try CursorSandUsageParser().parse(cursorSandBody(usagePercent: 0))?.percentRemaining == 100
    )
    #expect(
        try CursorSandUsageParser().parse(cursorSandBody(usagePercent: 100))?.percentRemaining == 0
    )
    #expect(
        try CursorSandUsageParser().parse(cursorSandBody(usagePercent: 150))?.percentRemaining == 0
    )
}

@Test
func cursorSandParserDoesNotReadIncludedLimitZeroAlias() throws {
    // Peer parsers treat `includedLimitZero` as a later alias of
    // `hasNonZeroIncludedLimit`. This live body never carried that key,
    // so a body that only has the alias must omit — not invent eligibility.
    let window = try CursorSandUsageParser().parse(Data("""
    {
      "usagePercent": 12.34,
      "includedLimitZero": false
    }
    """.utf8))

    #expect(window == nil)
}

private func cursorSandBody(
    usagePercent: Double? = 12.34,
    hasNonZeroIncludedLimit: Bool? = true,
    nextResetTimestampUtc: String? = "2026-09-14T00:00:00.000Z"
) -> Data {
    let usageJSON = usagePercent.map { "\($0)" } ?? "null"
    let limitJSON = hasNonZeroIncludedLimit.map { $0 ? "true" : "false" } ?? "null"
    let resetJSON = nextResetTimestampUtc.map { "\"\($0)\"" } ?? "null"
    return Data("""
    {
      "usagePercent": \(usageJSON),
      "hasNonZeroIncludedLimit": \(limitJSON),
      "nextResetTimestampUtc": \(resetJSON)
    }
    """.utf8)
}

private func epochSeconds(_ date: Date?) -> Int? {
    guard let date else {
        return nil
    }
    return Int(date.timeIntervalSince1970)
}
