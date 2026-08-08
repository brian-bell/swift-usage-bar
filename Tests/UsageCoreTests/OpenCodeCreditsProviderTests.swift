import Foundation
import Testing
@testable import UsageCore

// OpenCodeCreditsProvider mirrors OpenCodeGoProvider's session/discovery
// behavior with one difference in qualification: a workspace qualifies iff
// its page carries a configured billing record, and its usage carries the
// balance with both percent windows unavailable.

private let fixtureCredits = CreditBalance(
    balanceUSD: 12345678.0 / 100_000_000,
    monthlyUsedUSD: 87654321.0 / 100_000_000,
    monthlyLimitUSD: 99
)

private func creditsUsage(_ credits: CreditBalance) -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: nil, resetsAt: nil),
        credits: credits
    )
}

private let previousCredits = creditsUsage(CreditBalance(balanceUSD: 3.5))

@Test
func openCodeCreditsProviderForwardsModeAndReturnsConfiguredWorkspaceBalance() async throws {
    let responseTime = Date(timeIntervalSince1970: 2_000_000_000)
    let reader = RecordingCreditsSessionReader(session: OpenCodeSession(authenticationCookie: "auth=test"))
    let transport = StubCreditsTransport(
        workspaceIDs: ["wrk_ignored"],
        pages: [
            "wrk_selected": OpenCodeGoPageResponse(
                data: try fixtureData("opencode-go-usage-billing.html"),
                receivedAt: responseTime
            ),
        ]
    )
    let provider = OpenCodeCreditsProvider(
        sessionReader: reader,
        transport: transport,
        workspaceOverride: { "https://opencode.ai/workspace/wrk_selected/go" }
    )

    let state = await provider.fetch(previous: nil, mode: .interactive)

    #expect(state == .fresh(creditsUsage(fixtureCredits), asOf: responseTime))
    #expect(reader.modes == [.interactive])
    #expect(await transport.discoverCallCount == 0)
    #expect(await transport.requestedWorkspaceIDs == ["wrk_selected"])
}

@Test
func openCodeCreditsProviderMapsUnconfiguredBillingToCredentialUnavailable() async throws {
    // The Go-only fixture is a healthy workspace page without a billing
    // record: there is no balance to show, which is a missing data source,
    // not a parse failure.
    let provider = OpenCodeCreditsProvider(
        sessionReader: RecordingCreditsSessionReader(
            session: OpenCodeSession(authenticationCookie: "auth=test")
        ),
        transport: StubCreditsTransport(
            workspaceIDs: [],
            pages: [
                "wrk_selected": OpenCodeGoPageResponse(
                    data: try fixtureData("opencode-go-usage.html"),
                    receivedAt: Date(timeIntervalSince1970: 2_000_000_000)
                ),
            ]
        ),
        workspaceOverride: { "wrk_selected" }
    )

    let state = await provider.fetch(previous: previousCredits, mode: .background)

    #expect(state == .stale(last: previousCredits, reason: .credentialUnavailable))
}

@Test
func openCodeCreditsProviderMapsMalformedConfiguredRecordToParseFailure() async {
    let malformed = Data(#"""
    ((self.$R=self.$R||{}),$R[1]={customerID:"cus_x",balance:abc,monthlyLimit:50,monthlyUsage:1});
    """#.utf8)
    let provider = OpenCodeCreditsProvider(
        sessionReader: RecordingCreditsSessionReader(
            session: OpenCodeSession(authenticationCookie: "auth=test")
        ),
        transport: StubCreditsTransport(
            workspaceIDs: [],
            pages: [
                "wrk_selected": OpenCodeGoPageResponse(
                    data: malformed,
                    receivedAt: Date(timeIntervalSince1970: 2_000_000_000)
                ),
            ]
        ),
        workspaceOverride: { "wrk_selected" }
    )

    let state = await provider.fetch(previous: previousCredits, mode: .background)

    #expect(state == .stale(last: previousCredits, reason: .parseFailure))
}

@Test
func openCodeCreditsProviderRequiresSelectionWhenMultipleWorkspacesHaveBilling() async throws {
    let responseTime = Date(timeIntervalSince1970: 2_000_000_000)
    let page = OpenCodeGoPageResponse(
        data: try fixtureData("opencode-go-usage-billing.html"),
        receivedAt: responseTime
    )
    let provider = OpenCodeCreditsProvider(
        sessionReader: RecordingCreditsSessionReader(
            session: OpenCodeSession(authenticationCookie: "auth=test")
        ),
        transport: StubCreditsTransport(
            workspaceIDs: ["wrk_first", "wrk_second"],
            pages: ["wrk_first": page, "wrk_second": page]
        ),
        workspaceOverride: { nil }
    )

    let state = await provider.fetch(previous: previousCredits, mode: .background)

    #expect(state == .stale(last: previousCredits, reason: .workspaceSelectionRequired))
}

@Test
func openCodeCreditsProviderSelectsTheOnlyBillingWorkspaceDespitePartialFailures() async throws {
    // One workspace errors, one is Go-only (no billing record), one carries
    // billing: the billing one is the sole qualifier and must win.
    let responseTime = Date(timeIntervalSince1970: 2_000_000_000)
    let transport = StubCreditsTransport(
        workspaceIDs: ["wrk_network", "wrk_goonly", "wrk_billing"],
        pages: [
            "wrk_goonly": OpenCodeGoPageResponse(
                data: try fixtureData("opencode-go-usage.html"),
                receivedAt: responseTime
            ),
            "wrk_billing": OpenCodeGoPageResponse(
                data: try fixtureData("opencode-go-usage-billing.html"),
                receivedAt: responseTime
            ),
        ]
    )
    let provider = OpenCodeCreditsProvider(
        sessionReader: RecordingCreditsSessionReader(
            session: OpenCodeSession(authenticationCookie: "auth=test")
        ),
        transport: transport,
        workspaceOverride: { nil },
        maximumConcurrentWorkspaceRequests: 2
    )

    let state = await provider.fetch(previous: nil, mode: .background)

    #expect(state == .fresh(creditsUsage(fixtureCredits), asOf: responseTime))
    #expect(Set(await transport.requestedWorkspaceIDs) == ["wrk_network", "wrk_goonly", "wrk_billing"])
    #expect(await transport.maximumObservedConcurrency <= 2)
}

@Test
func openCodeCreditsProviderPreservesLastKnownUsageWhenNoWorkspaceQualifies() async throws {
    let provider = OpenCodeCreditsProvider(
        sessionReader: RecordingCreditsSessionReader(
            session: OpenCodeSession(authenticationCookie: "auth=test")
        ),
        transport: StubCreditsTransport(
            workspaceIDs: ["wrk_goonly"],
            pages: [
                "wrk_goonly": OpenCodeGoPageResponse(
                    data: try fixtureData("opencode-go-usage.html"),
                    receivedAt: Date(timeIntervalSince1970: 2_000_000_000)
                ),
            ]
        ),
        workspaceOverride: { nil }
    )

    #expect(await provider.fetch(previous: previousCredits, mode: .background) ==
        .stale(last: previousCredits, reason: .credentialUnavailable))
}

@Test
func openCodeCreditsProviderMapsExpiredSessionAndPreservesLastKnownUsage() async {
    let provider = OpenCodeCreditsProvider(
        sessionReader: RecordingCreditsSessionReader(
            session: OpenCodeSession(authenticationCookie: "auth=test")
        ),
        transport: StubCreditsTransport(
            workspaceIDs: ["wrk_expired"],
            pages: [:],
            errors: ["wrk_expired": .sessionExpired]
        ),
        workspaceOverride: { nil }
    )

    #expect(await provider.fetch(previous: previousCredits, mode: .background) ==
        .stale(last: previousCredits, reason: .sessionExpired))
}

@Test
func openCodeCreditsProviderReportsCredentialUnavailableWithoutASession() async {
    let reader = RecordingCreditsSessionReader(session: nil)
    let provider = OpenCodeCreditsProvider(
        sessionReader: reader,
        transport: StubCreditsTransport(workspaceIDs: [], pages: [:]),
        workspaceOverride: { nil }
    )

    let state = await provider.fetch(previous: previousCredits, mode: .background)

    #expect(state == .stale(last: previousCredits, reason: .credentialUnavailable))
    #expect(reader.modes == [.background])
}

@Test
func openCodeCreditsProviderReportsTheChromeCookieAsItsSource() async throws {
    let responseTime = Date(timeIntervalSince1970: 2_000_000_000)
    let provider = OpenCodeCreditsProvider(
        sessionReader: RecordingCreditsSessionReader(
            session: OpenCodeSession(authenticationCookie: "auth=test")
        ),
        transport: StubCreditsTransport(
            workspaceIDs: [],
            pages: [
                "wrk_selected": OpenCodeGoPageResponse(
                    data: try fixtureData("opencode-go-usage-billing.html"),
                    receivedAt: responseTime
                ),
            ]
        ),
        workspaceOverride: { "wrk_selected" }
    )

    let report = await provider.fetchReport(previous: nil, mode: .interactive)

    #expect(report.source == .openCodeCreditsChromeCookie)
    #expect(report.chain == [ProviderDataSourceStep(.openCodeCreditsChromeCookie, .used)])
}

@Test
func openCodeCreditsProviderChainStepFailureEqualsTheSurfacedReason() async {
    // Single-path provider: the one step's outcome is exactly the fetch's
    // outcome (the MiniMax-precedent trivial case of the display-only rule).
    let provider = OpenCodeCreditsProvider(
        sessionReader: RecordingCreditsSessionReader(
            session: OpenCodeSession(authenticationCookie: "auth=test")
        ),
        transport: StubCreditsTransport(
            workspaceIDs: ["wrk_expired"],
            pages: [:],
            errors: ["wrk_expired": .sessionExpired]
        ),
        workspaceOverride: { nil }
    )

    let report = await provider.fetchReport(previous: previousCredits, mode: .background)

    #expect(report.state == .stale(last: previousCredits, reason: .sessionExpired))
    #expect(report.chain == [
        ProviderDataSourceStep(.openCodeCreditsChromeCookie, .failed(.sessionExpired)),
    ])
    #expect(report.source == nil)
}

private final class RecordingCreditsSessionReader: OpenCodeSessionReading, @unchecked Sendable {
    let session: OpenCodeSession?
    private(set) var modes: [CredentialAccessMode] = []

    init(session: OpenCodeSession?) {
        self.session = session
    }

    func readSession(mode: CredentialAccessMode) throws -> OpenCodeSession? {
        modes.append(mode)
        return session
    }
}

private actor StubCreditsTransport: OpenCodeGoTransporting {
    let workspaceIDs: [String]
    let pages: [String: OpenCodeGoPageResponse]
    let errors: [String: OpenCodeGoTransportError]
    private(set) var discoverCallCount = 0
    private(set) var requestedWorkspaceIDs: [String] = []
    private(set) var activeRequestCount = 0
    private(set) var maximumObservedConcurrency = 0

    init(
        workspaceIDs: [String],
        pages: [String: OpenCodeGoPageResponse],
        errors: [String: OpenCodeGoTransportError] = [:]
    ) {
        self.workspaceIDs = workspaceIDs
        self.pages = pages
        self.errors = errors
    }

    func discoverWorkspaceIDs(session _: OpenCodeSession) async throws -> [String] {
        discoverCallCount += 1
        return workspaceIDs
    }

    func fetchUsagePage(
        workspaceID: String,
        session _: OpenCodeSession
    ) async throws -> OpenCodeGoPageResponse {
        requestedWorkspaceIDs.append(workspaceID)
        activeRequestCount += 1
        maximumObservedConcurrency = max(maximumObservedConcurrency, activeRequestCount)
        defer { activeRequestCount -= 1 }
        await Task.yield()
        if let error = errors[workspaceID] { throw error }
        guard let page = pages[workspaceID] else { throw OpenCodeGoTransportError.network }
        return page
    }
}

private func fixtureData(_ name: String) throws -> Data {
    let testFile = URL(fileURLWithPath: #filePath)
    return try Data(contentsOf: testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name))
}
