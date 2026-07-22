import Foundation
import Testing
@testable import UsageCore

@Test
func openCodeGoProviderForwardsModeAndReturnsConfiguredWorkspaceUsage() async throws {
    let responseTime = Date(timeIntervalSince1970: 2_000_000_000)
    let reader = RecordingOpenCodeSessionReader(session: OpenCodeSession(authenticationCookie: "auth=test"))
    let transport = StubOpenCodeGoTransport(
        workspaceIDs: ["wrk_ignored"],
        pages: [
            "wrk_selected": OpenCodeGoPageResponse(
                data: try fixtureData("opencode-go-usage.html"),
                receivedAt: responseTime
            ),
        ]
    )
    let provider = OpenCodeGoProvider(
        sessionReader: reader,
        transport: transport,
        workspaceOverride: { "https://opencode.ai/workspace/wrk_selected/go" }
    )

    let state = await provider.fetch(previous: nil, mode: .interactive)

    let expected = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 100, resetsAt: responseTime.addingTimeInterval(18_000)),
        weekly: UsageWindow(percentRemaining: 100, resetsAt: responseTime.addingTimeInterval(358_191)),
        monthly: UsageWindow(percentRemaining: 63, resetsAt: responseTime.addingTimeInterval(2_182_920))
    )
    #expect(state == .fresh(expected, asOf: responseTime))
    #expect(reader.modes == [.interactive])
    #expect(await transport.discoverCallCount == 0)
    #expect(await transport.requestedWorkspaceIDs == ["wrk_selected"])
}

@Test
func openCodeGoProviderRequiresSelectionWhenMultipleDiscoveredWorkspacesHaveGoUsage() async throws {
    let responseTime = Date(timeIntervalSince1970: 2_000_000_000)
    let page = OpenCodeGoPageResponse(
        data: try fixtureData("opencode-go-usage.html"),
        receivedAt: responseTime
    )
    let reader = RecordingOpenCodeSessionReader(session: OpenCodeSession(authenticationCookie: "auth=test"))
    let transport = StubOpenCodeGoTransport(
        workspaceIDs: ["wrk_first", "wrk_second"],
        pages: ["wrk_first": page, "wrk_second": page]
    )
    let previous = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 50, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 40, resetsAt: nil)
    )
    let provider = OpenCodeGoProvider(
        sessionReader: reader,
        transport: transport,
        workspaceOverride: { nil }
    )

    let state = await provider.fetch(previous: previous, mode: .background)

    #expect(state == .stale(last: previous, reason: .workspaceSelectionRequired))
    #expect(Set(await transport.requestedWorkspaceIDs) == ["wrk_first", "wrk_second"])
}

@Test
func openCodeGoProviderSelectsTheOnlyQualifyingWorkspaceDespitePartialFailures() async throws {
    let responseTime = Date(timeIntervalSince1970: 2_000_000_000)
    let reader = RecordingOpenCodeSessionReader(session: OpenCodeSession(authenticationCookie: "auth=test"))
    let transport = StubOpenCodeGoTransport(
        workspaceIDs: ["wrk_network", "wrk_invalid", "wrk_valid"],
        pages: [
            "wrk_invalid": OpenCodeGoPageResponse(data: Data("not usage".utf8), receivedAt: responseTime),
            "wrk_valid": OpenCodeGoPageResponse(
                data: try fixtureData("opencode-go-usage.html"),
                receivedAt: responseTime
            ),
        ]
    )
    let provider = OpenCodeGoProvider(
        sessionReader: reader,
        transport: transport,
        workspaceOverride: { nil },
        maximumConcurrentWorkspaceRequests: 2
    )

    let state = await provider.fetch(previous: nil, mode: .background)

    guard case .fresh = state else {
        Issue.record("Expected the sole qualifying workspace to be selected")
        return
    }
    #expect(Set(await transport.requestedWorkspaceIDs) == ["wrk_network", "wrk_invalid", "wrk_valid"])
    #expect(await transport.maximumObservedConcurrency <= 2)
}

@Test
func openCodeGoProviderPreservesLastKnownUsageWhenNoWorkspaceQualifies() async {
    let previous = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 44, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 55, resetsAt: nil)
    )
    let provider = OpenCodeGoProvider(
        sessionReader: RecordingOpenCodeSessionReader(
            session: OpenCodeSession(authenticationCookie: "auth=test")
        ),
        transport: StubOpenCodeGoTransport(workspaceIDs: ["wrk_none"], pages: [:]),
        workspaceOverride: { nil }
    )

    #expect(await provider.fetch(previous: previous, mode: .background) ==
        .stale(last: previous, reason: .credentialUnavailable))
}

@Test
func openCodeGoProviderMapsExpiredSessionAndPreservesLastKnownUsage() async {
    let previous = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 44, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 55, resetsAt: nil)
    )
    let provider = OpenCodeGoProvider(
        sessionReader: RecordingOpenCodeSessionReader(
            session: OpenCodeSession(authenticationCookie: "auth=test")
        ),
        transport: StubOpenCodeGoTransport(
            workspaceIDs: ["wrk_expired"],
            pages: [:],
            errors: ["wrk_expired": .sessionExpired]
        ),
        workspaceOverride: { nil }
    )

    #expect(await provider.fetch(previous: previous, mode: .background) ==
        .stale(last: previous, reason: .sessionExpired))
}

@Test
func openCodeGoTransportAllowsOnlyExactHTTPSOpenCodeHost() {
    #expect(OpenCodeGoHTTPTransport.isAllowedRequestURL(URL(string: "https://opencode.ai/_server")!))
    #expect(!OpenCodeGoHTTPTransport.isAllowedRequestURL(URL(string: "http://opencode.ai/_server")!))
    #expect(!OpenCodeGoHTTPTransport.isAllowedRequestURL(URL(string: "https://evil.opencode.ai/_server")!))
    #expect(!OpenCodeGoHTTPTransport.isAllowedRequestURL(URL(string: "https://opencode.ai.evil.test/_server")!))
}

@Test
func openCodeGoTransportAcceptsOnlyTheFilteredAuthenticationCookie() {
    #expect(OpenCodeGoHTTPTransport.isAllowedCookie("auth=session-value"))
    #expect(OpenCodeGoHTTPTransport.isAllowedCookie("__Host-auth=session-value"))
    #expect(!OpenCodeGoHTTPTransport.isAllowedCookie("analytics=value"))
    #expect(!OpenCodeGoHTTPTransport.isAllowedCookie("auth=value; analytics=value"))
    #expect(!OpenCodeGoHTTPTransport.isAllowedCookie("auth=value\r\nForwarded: secret"))
}

@Test
func openCodeGoTransportRejectsHostChangingAndInsecureRedirects() {
    let source = URL(string: "https://opencode.ai/workspace/wrk_test/go")!

    #expect(OpenCodeGoHTTPTransport.isAllowedRedirect(
        from: source,
        to: URL(string: "https://opencode.ai/login")!
    ))
    #expect(!OpenCodeGoHTTPTransport.isAllowedRedirect(
        from: source,
        to: URL(string: "https://accounts.opencode.ai/login")!
    ))
    #expect(!OpenCodeGoHTTPTransport.isAllowedRedirect(
        from: source,
        to: URL(string: "http://opencode.ai/login")!
    ))
}

@Test(arguments: [
    #"<a href="/auth/authorize">continue</a>"#,
    #"<button>Sign In</button>"#,
    #"actor of type "public""#,
])
func openCodeGoTransportRecognizesSignedOutResponses(_ body: String) {
    #expect(OpenCodeGoHTTPTransport.looksSignedOut(body))
}

private final class RecordingOpenCodeSessionReader: OpenCodeSessionReading, @unchecked Sendable {
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

private actor StubOpenCodeGoTransport: OpenCodeGoTransporting {
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
