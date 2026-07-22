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
