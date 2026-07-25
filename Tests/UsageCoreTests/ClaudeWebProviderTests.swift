import Foundation
import Testing
@testable import UsageCore

private let webAsOf = Date(timeIntervalSince1970: 1_783_200_000)
private let apiAsOf = Date(timeIntervalSince1970: 1_783_128_465)

@Test
func claudeProviderPrefersWebCookiePathAndSkipsOAuthAndCache() async throws {
    let session = ClaudeWebSession(cookieHeader: "sessionKey=x", organizationHint: "max-org")
    let webReader = FakeWebSessionReader(result: session)
    let webTransport = FakeWebTransport(response: ClaudeWebPageResponse(
        data: try fixtureData("claude-usage.json"),
        receivedAt: webAsOf
    ))
    let oauth = FailingHTTPTransport()
    let cache = CountingCacheReader()
    let provider = ClaudeUsageProvider(
        credentialReader: FakeCredReader(result: .fresh(cred())),
        cacheReader: cache,
        transport: oauth,
        webSessionReader: webReader,
        webTransport: webTransport,
        now: { apiAsOf }
    )

    let state = await provider.fetch(previous: nil, mode: .background)

    guard case let .fresh(usage, asOf: asOf) = state else {
        Issue.record("Expected fresh state, got \(state)"); return
    }
    #expect(usage.fiveHour.percentRemaining == 89)
    #expect(usage.weekly.percentRemaining == 77)
    #expect(asOf == webAsOf)
    #expect(webReader.receivedModes == [.background])
    #expect(oauth.requestCount == 0)
    #expect(cache.readCount == 0)
}

@Test
func claudeProviderFallsBackToOAuthWhenNoWebSession() async throws {
    let webReader = FakeWebSessionReader(result: nil)
    let webTransport = FakeWebTransport(error: ClaudeWebTransportError.network)
    let oauth = StubOKTransport(body: try fixtureData("claude-usage.json"))
    let provider = ClaudeUsageProvider(
        credentialReader: FakeCredReader(result: .fresh(cred())),
        cacheReader: CountingCacheReader(),
        transport: oauth,
        webSessionReader: webReader,
        webTransport: webTransport,
        now: { apiAsOf }
    )

    let state = await provider.fetch(previous: nil, mode: .background)

    guard case let .fresh(_, asOf: asOf) = state else {
        Issue.record("Expected fresh OAuth state, got \(state)"); return
    }
    #expect(asOf == apiAsOf) // OAuth path uses `now`, not the web clock
    #expect(webTransport.callCount == 0) // no session -> transport never called
    #expect(oauth.requestCount == 1)
}

@Test
func claudeProviderSilentlyFallsBackWhenWebTransportFails() async throws {
    // Cloudflare challenge / expired session must not surface; OAuth wins.
    let session = ClaudeWebSession(cookieHeader: "sessionKey=x", organizationHint: nil)
    let oauth = StubOKTransport(body: try fixtureData("claude-usage.json"))
    let provider = ClaudeUsageProvider(
        credentialReader: FakeCredReader(result: .fresh(cred())),
        cacheReader: CountingCacheReader(),
        transport: oauth,
        webSessionReader: FakeWebSessionReader(result: session),
        webTransport: FakeWebTransport(error: ClaudeWebTransportError.sessionExpired),
        now: { apiAsOf }
    )

    let state = await provider.fetch(previous: nil, mode: .background)

    guard case .fresh = state else {
        Issue.record("Expected fresh OAuth fallback, got \(state)"); return
    }
    #expect(oauth.requestCount == 1)
}

@Test
func claudeProviderTriesEachCoherentWebSessionBeforeOAuth() async throws {
    let sessions = [
        ClaudeWebSession(cookieHeader: "sessionKey=first", organizationHint: nil),
        ClaudeWebSession(cookieHeader: "sessionKey=second", organizationHint: nil),
    ]
    let transport = SequencedWebTransport(results: [
        .failure(ClaudeWebTransportError.sessionExpired),
        .success(ClaudeWebPageResponse(data: try fixtureData("claude-usage.json"), receivedAt: webAsOf)),
    ])
    let oauth = FailingHTTPTransport()
    let provider = ClaudeUsageProvider(
        credentialReader: FakeCredReader(result: .fresh(cred())),
        cacheReader: CountingCacheReader(),
        transport: oauth,
        webSessionReader: CandidateWebSessionReader(sessions: sessions),
        webTransport: transport,
        now: { apiAsOf }
    )

    let state = await provider.fetch(previous: nil, mode: .background)

    guard case .fresh = state else {
        Issue.record("Expected second coherent web session to succeed, got \(state)"); return
    }
    #expect(transport.cookieHeaders == sessions.map(\.cookieHeader))
    #expect(oauth.requestCount == 0)
}

@Test
func claudeProviderSilentlyFallsBackWhenWebBodyIsUnparseable() async throws {
    let session = ClaudeWebSession(cookieHeader: "sessionKey=x", organizationHint: "max-org")
    let oauth = StubOKTransport(body: try fixtureData("claude-usage.json"))
    let provider = ClaudeUsageProvider(
        credentialReader: FakeCredReader(result: .fresh(cred())),
        cacheReader: CountingCacheReader(),
        transport: oauth,
        webSessionReader: FakeWebSessionReader(result: session),
        webTransport: FakeWebTransport(response: ClaudeWebPageResponse(
            data: Data("not json".utf8), receivedAt: webAsOf
        )),
        now: { apiAsOf }
    )

    let state = await provider.fetch(previous: nil, mode: .background)

    guard case .fresh = state else {
        Issue.record("Expected fresh OAuth fallback, got \(state)"); return
    }
    #expect(oauth.requestCount == 1)
}

@Test
func claudeProviderWebPathFallsBackToCacheWhenBothWebAndOAuthFail() async throws {
    let session = ClaudeWebSession(cookieHeader: "sessionKey=x", organizationHint: nil)
    let cacheAsOf = Date(timeIntervalSince1970: 1_783_000_000)
    let cached = usage(fiveHour: 62, weekly: 81)
    let provider = ClaudeUsageProvider(
        credentialReader: FakeCredReader(result: .stale(reason: .tokenExpired)),
        cacheReader: CountingCacheReader(result: .fresh(
            data: Data("{}".utf8), usage: cached, asOf: cacheAsOf
        )),
        transport: FailingHTTPTransport(),
        webSessionReader: FakeWebSessionReader(result: session),
        webTransport: FakeWebTransport(error: ClaudeWebTransportError.sessionExpired),
        now: { apiAsOf }
    )

    let state = await provider.fetch(previous: nil, mode: .background)

    #expect(state == .fresh(cached, asOf: cacheAsOf))
}

@Test
func claudeProviderDoesNotStartOAuthFallbackAfterWebRequestCancellation() async throws {
    let oauth = StubOKTransport(body: try fixtureData("claude-usage.json"))
    let provider = ClaudeUsageProvider(
        credentialReader: FakeCredReader(result: .fresh(cred())),
        cacheReader: CountingCacheReader(),
        transport: oauth,
        webSessionReader: FakeWebSessionReader(result: ClaudeWebSession(cookieHeader: "sessionKey=x", organizationHint: nil)),
        webTransport: SuspendedWebTransport(),
        now: { apiAsOf }
    )

    let task = Task { await provider.fetch(previous: nil, mode: .interactive) }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    _ = await task.value

    #expect(oauth.requestCount == 0)
}

// MARK: - Fakes

private final class FakeWebSessionReader: ClaudeWebSessionReading, @unchecked Sendable {
    private let result: ClaudeWebSession?
    private let error: (any Error)?
    private(set) var receivedModes: [CredentialAccessMode] = []

    init(result: ClaudeWebSession?) { self.result = result; self.error = nil }
    init(error: any Error) { self.result = nil; self.error = error }

    func readSession(mode: CredentialAccessMode) throws -> ClaudeWebSession? {
        receivedModes.append(mode)
        if let error { throw error }
        return result
    }
}

private struct CandidateWebSessionReader: ClaudeWebSessionCandidateReading {
    let sessions: [ClaudeWebSession]
    func readSession(mode _: CredentialAccessMode) throws -> ClaudeWebSession? { sessions.first }
    func readSessions(mode _: CredentialAccessMode) throws -> [ClaudeWebSession] { sessions }
}

private final class FakeWebTransport: ClaudeWebTransporting, @unchecked Sendable {
    private let response: ClaudeWebPageResponse?
    private let error: (any Error)?
    private(set) var callCount = 0

    init(response: ClaudeWebPageResponse) { self.response = response; self.error = nil }
    init(error: any Error) { self.response = nil; self.error = error }

    func fetchUsage(session: ClaudeWebSession) async throws -> ClaudeWebPageResponse {
        callCount += 1
        if let error { throw error }
        return response!
    }
}

private struct SuspendedWebTransport: ClaudeWebTransporting {
    func fetchUsage(session _: ClaudeWebSession) async throws -> ClaudeWebPageResponse {
        try await Task.sleep(for: .seconds(60))
        throw ClaudeWebTransportError.network
    }
}

private final class SequencedWebTransport: ClaudeWebTransporting, @unchecked Sendable {
    private var results: [Result<ClaudeWebPageResponse, ClaudeWebTransportError>]
    private(set) var cookieHeaders: [String] = []

    init(results: [Result<ClaudeWebPageResponse, ClaudeWebTransportError>]) {
        self.results = results
    }

    func fetchUsage(session: ClaudeWebSession) async throws -> ClaudeWebPageResponse {
        cookieHeaders.append(session.cookieHeader)
        return try results.removeFirst().get()
    }
}

private final class FailingHTTPTransport: HTTPTransport, @unchecked Sendable {
    private(set) var requestCount = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        throw URLError(.notConnectedToInternet)
    }
}

private final class StubOKTransport: HTTPTransport, @unchecked Sendable {
    private let body: Data
    private(set) var requestCount = 0
    init(body: Data) { self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        return (body, HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class CountingCacheReader: ClaudeStatuslineCacheReading, @unchecked Sendable {
    private let result: ClaudeStatuslineCacheReadResult
    private(set) var readCount = 0
    init(result: ClaudeStatuslineCacheReadResult = .stale(last: nil, reason: .networkError, hint: "")) {
        self.result = result
    }
    func read(now _: Date) throws -> ClaudeStatuslineCacheReadResult {
        readCount += 1
        return result
    }
}

private final class FakeCredReader: ClaudeCredentialReading, @unchecked Sendable {
    private let result: ClaudeCredentialReadResult
    init(result: ClaudeCredentialReadResult) { self.result = result }
    func read(mode _: CredentialAccessMode) throws -> ClaudeCredentialReadResult { result }
}

private func cred() -> ClaudeCredential {
    ClaudeCredential(accessToken: "access-token", expiresAt: Date(timeIntervalSince1970: 1_783_154_084))
}

private func usage(fiveHour: Int, weekly: Int) -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: fiveHour, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: weekly, resetsAt: nil)
    )
}

private func fixtureData(_ name: String) throws -> Data {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: packageRoot
        .appendingPathComponent("Tests/Fixtures").appendingPathComponent(name))
}
