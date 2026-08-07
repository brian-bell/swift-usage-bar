import Foundation
import Testing
import UsageCore

@Test
func openCodeGoParserParsesCapturedThreeWindowFixtureFromOneResponseTime() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let usage = try OpenCodeGoUsageParser().parse(
        fixtureData("opencode-go-usage.html"),
        now: now
    )

    #expect(usage.fiveHour.percentRemaining == 100)
    #expect(usage.weekly.percentRemaining == 100)
    #expect(usage.monthly?.percentRemaining == 63)
    #expect(usage.fiveHour.resetsAt == now.addingTimeInterval(18_000))
    #expect(usage.weekly.resetsAt == now.addingTimeInterval(358_191))
    #expect(usage.monthly?.resetsAt == now.addingTimeInterval(2_182_920))
}

@Test
func openCodeGoParserParsesCapturedFixtureWithBillingRecordBeforeGoWindows() throws {
    // 2026-08-07 capture: the page's Seroval stream also carries the workspace
    // billing record, whose plain-number `monthlyUsage:` can precede the go
    // window object of the same name (resolution order is nondeterministic).
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let usage = try OpenCodeGoUsageParser().parse(
        fixtureData("opencode-go-usage-billing.html"),
        now: now
    )

    #expect(usage.fiveHour.percentRemaining == 0)
    #expect(usage.weekly.percentRemaining == 11)
    #expect(usage.monthly?.percentRemaining == 18)
    #expect(usage.fiveHour.resetsAt == now.addingTimeInterval(16_437))
    #expect(usage.weekly.resetsAt == now.addingTimeInterval(181_584))
    #expect(usage.monthly?.resetsAt == now.addingTimeInterval(796_729))
}

@Test
func openCodeGoWorkspaceParserReadsAllDistinctCapturedWorkspaceIDs() throws {
    let ids = try OpenCodeGoWorkspaceParser().parse(fixtureData("opencode-go-workspaces.js"))

    #expect(ids == ["wrk_FIXTURE1"])
}

@Test
func openCodeGoParserAcceptsRollingOnlyAndFloatingPointPercentages() throws {
    let now = Date(timeIntervalSince1970: 100)
    let data = Data(#"rollingUsage:$R[1]={resetInSec:12.5,usagePercent:7.25}"#.utf8)

    let usage = try OpenCodeGoUsageParser().parse(data, now: now)

    #expect(usage.fiveHour.percentRemaining == 93)
    #expect(usage.fiveHour.resetsAt == now.addingTimeInterval(12.5))
    #expect(usage.weekly == UsageWindow(percentRemaining: nil, resetsAt: nil))
    #expect(usage.monthly == nil)
}

@Test
func openCodeGoParserExtractsCreditsFromBillingFixture() throws {
    // Fixture (synthetic): balance:12345678 / monthlyUsage:87654321 /
    // monthlyLimit:99, 10⁻⁸ dollars for the first two. 1e-9 tolerance
    // accounts for the non-power-of-two divisor.
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let usage = try OpenCodeGoUsageParser().parse(
        fixtureData("opencode-go-usage-billing.html"),
        now: now
    )

    let credits = try #require(usage.credits, "Credits should be parsed from the billing fixture")
    #expect(abs(credits.balanceUSD - (12345678.0 / 100_000_000)) < 1e-9)
    let monthlyUsed = try #require(
        credits.monthlyUsedUSD,
        "monthlyUsage is present in the fixture"
    )
    #expect(abs(monthlyUsed - (87654321.0 / 100_000_000)) < 1e-9)
    #expect(credits.monthlyLimitUSD == 99)
}

@Test
func openCodeGoParserReturnsNilCreditsWhenNoBillingRecord() throws {
    // Old fixture has no billing record; credits must be nil without
    // affecting the Go windows.
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let usage = try OpenCodeGoUsageParser().parse(
        fixtureData("opencode-go-usage.html"),
        now: now
    )

    #expect(usage.credits == nil)
    #expect(usage.fiveHour.percentRemaining == 100)
    #expect(usage.weekly.percentRemaining == 100)
    #expect(usage.monthly?.percentRemaining == 63)
}

@Test
func openCodeGoParserReturnsNilCreditsWhenCustomerIDIsNull() throws {
    // customerID:null means billing is not configured (CodexBar's
    // sentinel for "no real balance"). The parser must drop credits
    // rather than report a fabricated $0.00.
    let data = Data(#"""
    rollingUsage:$R[1]={resetInSec:10,usagePercent:0}
    $R[2]={customerID:null,balance:0,monthlyLimit:0,monthlyUsage:0}
    """#.utf8)

    let usage = try OpenCodeGoUsageParser().parse(data, now: .distantPast)

    #expect(usage.credits == nil)
    #expect(usage.fiveHour.percentRemaining == 100)
}

@Test
func openCodeGoParserReturnsNilCreditsWhenBalanceDigitsAreMalformed() throws {
    // A future console deploy that renames or restructures the billing
    // record must never break window parsing.
    let data = Data(#"""
    rollingUsage:$R[1]={resetInSec:10,usagePercent:0}
    $R[2]={customerID:"cus_x",balance:abc,monthlyLimit:50,monthlyUsage:200000000}
    """#.utf8)

    let usage = try OpenCodeGoUsageParser().parse(data, now: .distantPast)

    #expect(usage.credits == nil)
    #expect(usage.fiveHour.percentRemaining == 100)
}

@Test
func openCodeGoParserCreditsCannotLeakPaymentMetadata() throws {
    // CreditBalance has no fields for payment metadata (customerID,
    // paymentMethodID, subscription, lite, …), so the parsed result must
    // be value-equal to one constructed from the three numbers alone.
    // The structural limit on the type is the privacy guarantee.
    let usage = try OpenCodeGoUsageParser().parse(
        fixtureData("opencode-go-usage-billing.html"),
        now: Date(timeIntervalSince1970: 2_000_000_000)
    )

    let manual = CreditBalance(
        balanceUSD: 12345678.0 / 100_000_000,
        monthlyUsedUSD: 87654321.0 / 100_000_000,
        monthlyLimitUSD: 99
    )
    #expect(usage.credits == manual)
}

@Test(arguments: [
    #"rollingUsage:$R[1]={resetInSec:10,usagePercent:-25}"#,
    #"rollingUsage:$R[1]={resetInSec:10,usagePercent:125}"#,
])
func openCodeGoParserClampsUsedPercentages(_ source: String) throws {
    let usage = try OpenCodeGoUsageParser().parse(Data(source.utf8), now: .distantPast)
    #expect(usage.fiveHour.percentRemaining == (source.contains("-25") ? 100 : 0))
}

@Test(arguments: [
    Data("not a usage response".utf8),
    Data(#"rollingUsage:$R[1]={resetInSec:-1,usagePercent:10}"#.utf8),
    Data(#"rollingUsage:$R[1]={resetInSec:NaN,usagePercent:10}"#.utf8),
    Data(#"rollingUsage:$R[1]={resetInSec:10,usagePercent:Infinity}"#.utf8),
])
func openCodeGoParserRejectsMalformedOrNonFiniteWindows(_ data: Data) {
    #expect(throws: UsageParsingError.parseFailure) {
        try OpenCodeGoUsageParser().parse(data, now: .distantPast)
    }
}

@Test
func openCodeGoParserRejectsCapturedSignedOutPage() throws {
    #expect(throws: UsageParsingError.parseFailure) {
        try OpenCodeGoUsageParser().parse(fixtureData("opencode-go-signed-out.html"), now: .distantPast)
    }
}

private func fixtureData(_ name: String) throws -> Data {
    let testFile = URL(fileURLWithPath: #filePath)
    let fixture = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    return try Data(contentsOf: fixture)
}
