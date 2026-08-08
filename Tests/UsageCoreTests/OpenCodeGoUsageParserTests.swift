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

@Test(arguments: [
    #"weeklyUsage:null"#,
    #"weeklyUsage:{resetInSec:20,usagePercent:30}"#,
    #"monthlyUsage:null"#,
    #"monthlyUsage:{resetInSec:20,usagePercent:30}"#,
    #"weeklyUsage:null,weeklyUsage:$R[2]={resetInSec:20,usagePercent:30}"#,
    #"monthlyUsage:$R[2]={resetInSec:20,usagePercent:30},monthlyUsage:null"#,
    #"weeklyUsage:$R[2]={resetInSec:20,weeklyUsage:null,usagePercent:30}"#,
    #"monthlyUsage:$R[2]={resetInSec:20,monthlyUsage:null,usagePercent:30}"#,
])
func openCodeGoParserRejectsNamedOptionalWindowsInUnobservedShapes(_ optionalWindow: String) {
    let data = Data("rollingUsage:$R[1]={resetInSec:10,usagePercent:0}\n\(optionalWindow)".utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try OpenCodeGoUsageParser().parse(data, now: .distantPast)
    }
}

@Test(arguments: [
    #"{mine:!0,monthlyUsage:null}"#,
    #"{mine:!0,monthlyUsage:{resetInSec:20,usagePercent:30}}"#,
])
func openCodeGoParserRejectsAlteredMonthlyUsagePastTheBillingClosingBrace(_ sibling: String) {
    // The billing record's plain-number `monthlyUsage` is the sole exemption
    // from window-drift validation, and it ends at the billing object's
    // closing brace. A record that omits the key must not extend the
    // exemption to a same-line sibling object, which would silently drop the
    // monthly window instead of reporting drift.
    let data = Data("""
    rollingUsage:$R[1]={resetInSec:10,usagePercent:0}
    $R[2]={customerID:"cus_x",balance:100000000,monthlyLimit:50},\(sibling)
    """.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try OpenCodeGoUsageParser().parse(data, now: .distantPast)
    }
}

@Test
func openCodeGoParserLeavesCreditsToTheCreditsProvider() throws {
    // Ownership: the billing record belongs to OpenCodeCreditsParser. Even
    // on a page with a configured record, Go parses only its windows — a
    // single owner means the balance can never render twice when both
    // OpenCode toggles are on.
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let usage = try OpenCodeGoUsageParser().parse(
        fixtureData("opencode-go-usage-billing.html"),
        now: now
    )

    #expect(usage.credits == nil)
    #expect(usage.fiveHour.percentRemaining == 0)
    #expect(usage.weekly.percentRemaining == 11)
    #expect(usage.monthly?.percentRemaining == 18)
}

// Billing-record drift must never make otherwise valid Go windows stale:
// the record lives on the same page, but it belongs to OpenCodeCreditsParser
// (which validates it strictly). These pin that Go's window parsing — and
// the `monthlyUsage` anti-drift exemption in particular — survives every
// observed and adversarial billing-record shape.

@Test
func openCodeGoParserWindowsSurviveNullCustomerBillingRecord() throws {
    let data = Data(#"""
    rollingUsage:$R[1]={resetInSec:10,usagePercent:0}
    $R[2]={customerID:null,balance:0,monthlyLimit:0,monthlyUsage:0}
    """#.utf8)

    let usage = try OpenCodeGoUsageParser().parse(data, now: .distantPast)

    #expect(usage.fiveHour.percentRemaining == 100)
}

@Test
func openCodeGoParserWindowsSurviveMalformedBillingBalance() throws {
    let data = Data(#"""
    rollingUsage:$R[1]={resetInSec:10,usagePercent:0}
    $R[2]={customerID:"cus_x",balance:abc,monthlyLimit:50,monthlyUsage:200000000}
    """#.utf8)

    let usage = try OpenCodeGoUsageParser().parse(data, now: .distantPast)

    #expect(usage.fiveHour.percentRemaining == 100)
}

@Test(arguments: ["null", "abc"])
func openCodeGoParserWindowsSurviveMalformedBillingMonthlyUsage(_ monthlyUsage: String) throws {
    // The malformed plain-number `monthlyUsage:` key still sits inside the
    // billing record, so the window validator's exemption must keep
    // covering it rather than reporting drift.
    let data = Data(#"""
    rollingUsage:$R[1]={resetInSec:10,usagePercent:0}
    $R[2]={customerID:"cus_x",balance:100000000,monthlyLimit:50,monthlyUsage:\#(monthlyUsage)}
    """#.utf8)

    let usage = try OpenCodeGoUsageParser().parse(data, now: .distantPast)

    #expect(usage.fiveHour.percentRemaining == 100)
}

@Test
func openCodeGoParserWindowsSurviveNestedBillingObject() throws {
    let data = Data(#"""
    rollingUsage:$R[1]={resetInSec:10,usagePercent:0}
    $R[2]={customerID:"cus_x",nested:{balance:99,monthlyLimit:99,monthlyUsage:99}
    """#.utf8)

    let usage = try OpenCodeGoUsageParser().parse(data, now: .distantPast)

    #expect(usage.fiveHour.percentRemaining == 100)
}

@Test
func openCodeGoParserWindowsSurviveOverflowingBillingBalance() throws {
    let overflowDigits = String(repeating: "9", count: 400)
    let data = Data(#"""
    rollingUsage:$R[1]={resetInSec:10,usagePercent:0}
    \#(overflowDigits)R[2]={customerID:"cus_x",balance:\#(overflowDigits),monthlyLimit:50,monthlyUsage:200000000}
    """#.utf8)

    let usage = try OpenCodeGoUsageParser().parse(data, now: .distantPast)

    #expect(usage.fiveHour.percentRemaining == 100)
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
