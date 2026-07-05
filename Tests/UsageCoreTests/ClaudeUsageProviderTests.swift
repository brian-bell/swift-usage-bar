import Foundation
import Testing
import UsageCore

@Test
func claudeUsageProviderBuildsUsageRequestAndReturnsFreshUsageWithoutConsultingCache() async throws {
    let asOf = Date(timeIntervalSince1970: 1_783_128_465)
    let cacheReader = FakeClaudeStatuslineCacheReader(result: .fresh(
        data: Data("{}".utf8),
        usage: sampleUsage(fiveHour: 1, weekly: 1),
        asOf: Date(timeIntervalSince1970: 1_783_000_000)
    ))
    let transport = FakeHTTPTransport(response: (
        try fixtureData("claude-usage.json"),
        try httpResponse(statusCode: 200)
    ))
    let provider = ClaudeUsageProvider(
        credentialReader: FakeClaudeCredentialReader(result: .fresh(validCredential())),
        cacheReader: cacheReader,
        transport: transport,
        now: { asOf }
    )

    let state = await provider.fetch(previous: nil)
    let request = try #require(transport.requests.first)

    guard case let .fresh(usage, asOf: freshAsOf) = state else {
        Issue.record("Expected fresh state, got \(state)")
        return
    }

    #expect(usage.fiveHour.percentRemaining == 89)
    #expect(usage.weekly.percentRemaining == 77)
    #expect(usage.fiveHour.resetsAt.map { Int($0.timeIntervalSince1970) } == 1_783_145_400)
    #expect(usage.weekly.resetsAt.map { Int($0.timeIntervalSince1970) } == 1_783_332_000)
    #expect(freshAsOf == asOf)
    #expect(transport.requests.count == 1)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(request.value(forHTTPHeaderField: "User-Agent")?.isEmpty == false)
    #expect(cacheReader.readCount == 0)
}

@Test
func claudeUsageProviderExposesFableScopedWeeklyWindowFromLimits() async throws {
    let asOf = Date(timeIntervalSince1970: 1_783_128_465)
    let transport = FakeHTTPTransport(response: (
        try fixtureData("claude-usage.json"),
        try httpResponse(statusCode: 200)
    ))
    let provider = ClaudeUsageProvider(
        credentialReader: FakeClaudeCredentialReader(result: .fresh(validCredential())),
        cacheReader: FakeClaudeStatuslineCacheReader(result: .stale(
            last: nil,
            reason: .networkError,
            hint: ""
        )),
        transport: transport,
        now: { asOf }
    )

    let state = await provider.fetch(previous: nil)

    guard case let .fresh(usage, asOf: _) = state else {
        Issue.record("Expected fresh state, got \(state)")
        return
    }

    let fable = try #require(usage.fable)
    #expect(fable.percentRemaining == 56)
    #expect(fable.resetsAt.map { Int($0.timeIntervalSince1970) } == 1_783_332_001)
}

@Test
func claudeUsageParserKeepsPrimaryWindowsWhenALimitEntryIsMalformed() throws {
    // A future/non-Fable limit entry missing `percent` must not fail the whole
    // decode; the valid five_hour/seven_day windows and Fable still parse.
    let json = """
    {
      "five_hour": {"utilization": 11.0, "resets_at": "2026-07-04T06:10:00.229359+00:00"},
      "seven_day": {"utilization": 23.0, "resets_at": "2026-07-06T10:00:00.229385+00:00"},
      "limits": [
        {"kind": "session", "group": "session"},
        {"kind": "weekly_scoped", "percent": 44, "resets_at": "2026-07-06T10:00:01.229732+00:00", "scope": {"model": {"display_name": "Fable"}}}
      ]
    }
    """
    let usage = try ClaudeUsageParser().parse(Data(json.utf8))

    #expect(usage.fiveHour.percentRemaining == 89)
    #expect(usage.weekly.percentRemaining == 77)
    let fable = try #require(usage.fable)
    #expect(fable.percentRemaining == 56)
}

@Test
func claudeUsageProviderSkipsRequestAndFallsBackToCacheWhenCredentialIsStale() async throws {
    let previous = sampleUsage(fiveHour: 44, weekly: 66)
    let cases: [(ClaudeCredentialReadResult, StaleReason)] = [
        (.stale(reason: .tokenExpired), .tokenExpired),
        (.stale(reason: .credentialUnavailable), .credentialUnavailable),
        (.stale(reason: .parseFailure), .parseFailure),
    ]

    for (credentialResult, expectedReason) in cases {
        let cacheReader = FakeClaudeStatuslineCacheReader(result: .stale(
            last: nil,
            reason: .networkError,
            hint: "Configure Claude Code statusline to write its cache."
        ))
        let transport = FakeHTTPTransport(response: (
            try fixtureData("claude-usage.json"),
            try httpResponse(statusCode: 200)
        ))
        let provider = ClaudeUsageProvider(
            credentialReader: FakeClaudeCredentialReader(result: credentialResult),
            cacheReader: cacheReader,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_783_128_465) }
        )

        let state = await provider.fetch(previous: previous)

        #expect(state == .stale(last: previous, reason: expectedReason))
        #expect(transport.requests.isEmpty)
        #expect(cacheReader.readCount == 1)
    }
}

@Test
func claudeUsageProviderMapsThrowingCredentialReaderToCredentialUnavailable() async throws {
    let previous = sampleUsage(fiveHour: 44, weekly: 66)
    let transport = FakeHTTPTransport(response: (
        try fixtureData("claude-usage.json"),
        try httpResponse(statusCode: 200)
    ))
    let provider = ClaudeUsageProvider(
        credentialReader: FakeClaudeCredentialReader(error: FakeCredentialReaderError.failed),
        cacheReader: FakeClaudeStatuslineCacheReader(error: CocoaError(.fileReadUnknown)),
        transport: transport,
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: previous, reason: .credentialUnavailable))
    #expect(transport.requests.isEmpty)
}

@Test
func claudeUsageProviderMapsHTTPFailuresToAPIStaleReasons() async throws {
    let previous = sampleUsage(fiveHour: 44, weekly: 66)
    let cases: [(Int, StaleReason)] = [
        (401, .tokenExpired),
        (429, .networkError),
        (500, .networkError),
    ]

    for (statusCode, expectedReason) in cases {
        let transport = FakeHTTPTransport(response: (
            try fixtureData("claude-usage.json"),
            try httpResponse(statusCode: statusCode)
        ))
        let provider = ClaudeUsageProvider(
            credentialReader: FakeClaudeCredentialReader(result: .fresh(validCredential())),
            cacheReader: FakeClaudeStatuslineCacheReader(result: .stale(
                last: nil,
                reason: .networkError,
                hint: "Configure Claude Code statusline to write its cache."
            )),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_783_128_465) }
        )

        let state = await provider.fetch(previous: previous)

        #expect(state == .stale(last: previous, reason: expectedReason))
        #expect(transport.requests.count == 1)
    }
}

@Test
func claudeUsageProviderMapsMalformedResponseBodyToParseFailure() async throws {
    let previous = sampleUsage(fiveHour: 44, weekly: 66)
    let provider = ClaudeUsageProvider(
        credentialReader: FakeClaudeCredentialReader(result: .fresh(validCredential())),
        cacheReader: FakeClaudeStatuslineCacheReader(error: CocoaError(.fileReadUnknown)),
        transport: FakeHTTPTransport(response: (
            Data("not json".utf8),
            try httpResponse(statusCode: 200)
        )),
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: previous, reason: .parseFailure))
}

@Test
func claudeUsageProviderMapsTransportThrowToNetworkError() async {
    let previous = sampleUsage(fiveHour: 44, weekly: 66)
    let provider = ClaudeUsageProvider(
        credentialReader: FakeClaudeCredentialReader(result: .fresh(validCredential())),
        cacheReader: FakeClaudeStatuslineCacheReader(error: CocoaError(.fileReadUnknown)),
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: previous, reason: .networkError))
}

@Test
func claudeUsageProviderReturnsFreshCacheUsageWhenAPIPathIsStale() async {
    let cacheAsOf = Date(timeIntervalSince1970: 1_783_000_000)
    let cached = sampleUsage(fiveHour: 62, weekly: 81)
    let provider = ClaudeUsageProvider(
        credentialReader: FakeClaudeCredentialReader(result: .stale(reason: .tokenExpired)),
        cacheReader: FakeClaudeStatuslineCacheReader(result: .fresh(
            data: Data("{}".utf8),
            usage: cached,
            asOf: cacheAsOf
        )),
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    let state = await provider.fetch(previous: nil)

    #expect(state == .fresh(cached, asOf: cacheAsOf))
}

@Test
func claudeUsageProviderPrefersStaleCacheUsageOverPreviousWithAPIStaleReason() async {
    let cached = sampleUsage(fiveHour: 62, weekly: 81)
    let previous = sampleUsage(fiveHour: 55, weekly: 75)
    let provider = ClaudeUsageProvider(
        credentialReader: FakeClaudeCredentialReader(result: .stale(reason: .tokenExpired)),
        cacheReader: FakeClaudeStatuslineCacheReader(result: .stale(
            last: cached,
            reason: .networkError,
            hint: "Configure Claude Code statusline to write its cache."
        )),
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: cached, reason: .tokenExpired))
}

@Test
func claudeUsageProviderFallsBackToPreviousUsageWhenCacheHasNoData() async {
    let previous = sampleUsage(fiveHour: 55, weekly: 75)
    let provider = ClaudeUsageProvider(
        credentialReader: FakeClaudeCredentialReader(result: .stale(reason: .tokenExpired)),
        cacheReader: FakeClaudeStatuslineCacheReader(result: .stale(
            last: nil,
            reason: .parseFailure,
            hint: "Configure Claude Code statusline to write its cache."
        )),
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: previous, reason: .tokenExpired))
}

@Test
func claudeUsageProviderFallsBackToPreviousUsageWhenCacheReaderThrows() async {
    let previous = sampleUsage(fiveHour: 55, weekly: 75)
    let provider = ClaudeUsageProvider(
        credentialReader: FakeClaudeCredentialReader(result: .stale(reason: .tokenExpired)),
        cacheReader: FakeClaudeStatuslineCacheReader(error: CocoaError(.fileReadUnknown)),
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: previous, reason: .tokenExpired))
}

@Test
func claudeUsageProviderForwardsInteractiveModeToCredentialReader() async {
    let reader = FakeClaudeCredentialReader(result: .stale(reason: .tokenExpired))
    let cacheReader = FakeClaudeStatuslineCacheReader(
        result: .stale(last: nil, reason: .parseFailure, hint: "hint")
    )
    let provider = ClaudeUsageProvider(
        credentialReader: reader,
        cacheReader: cacheReader,
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    _ = await provider.fetch(previous: nil, mode: .interactive)

    #expect(reader.receivedModes == [.interactive])
}

@Test
func claudeUsageProviderDefaultsToBackgroundMode() async {
    let reader = FakeClaudeCredentialReader(result: .stale(reason: .tokenExpired))
    let cacheReader = FakeClaudeStatuslineCacheReader(
        result: .stale(last: nil, reason: .parseFailure, hint: "hint")
    )
    let provider = ClaudeUsageProvider(
        credentialReader: reader,
        cacheReader: cacheReader,
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { Date(timeIntervalSince1970: 1_783_128_465) }
    )

    _ = await provider.fetch(previous: nil)

    #expect(reader.receivedModes == [.background])
}

private final class FakeClaudeCredentialReader: ClaudeCredentialReading, @unchecked Sendable {
    private let result: ClaudeCredentialReadResult?
    private let error: (any Error)?
    private(set) var receivedModes: [CredentialAccessMode] = []

    init(result: ClaudeCredentialReadResult) {
        self.result = result
        self.error = nil
    }

    init(error: any Error) {
        self.result = nil
        self.error = error
    }

    func read(mode: CredentialAccessMode) throws -> ClaudeCredentialReadResult {
        receivedModes.append(mode)
        if let error {
            throw error
        }

        return result!
    }
}

private enum FakeCredentialReaderError: Error {
    case failed
}

private final class FakeClaudeStatuslineCacheReader: ClaudeStatuslineCacheReading, @unchecked Sendable {
    private let result: ClaudeStatuslineCacheReadResult?
    private let error: (any Error)?
    private(set) var readCount = 0

    init(result: ClaudeStatuslineCacheReadResult) {
        self.result = result
        self.error = nil
    }

    init(error: any Error) {
        self.result = nil
        self.error = error
    }

    func read(now _: Date) throws -> ClaudeStatuslineCacheReadResult {
        readCount += 1
        if let error {
            throw error
        }

        return result!
    }
}

private final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let response: (Data, HTTPURLResponse)?
    private let error: (any Error)?
    private(set) var requests: [URLRequest] = []

    init(response: (Data, HTTPURLResponse)) {
        self.response = response
        self.error = nil
    }

    init(error: any Error) {
        self.response = nil
        self.error = error
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let error {
            throw error
        }

        return response!
    }
}

private func validCredential() -> ClaudeCredential {
    ClaudeCredential(
        accessToken: "access-token",
        expiresAt: Date(timeIntervalSince1970: 1_783_154_084.847)
    )
}

private func sampleUsage(fiveHour: Int, weekly: Int) -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(
            percentRemaining: fiveHour,
            resetsAt: Date(timeIntervalSince1970: 1_783_145_400)
        ),
        weekly: UsageWindow(
            percentRemaining: weekly,
            resetsAt: Date(timeIntervalSince1970: 1_783_332_000)
        )
    )
}

private func httpResponse(statusCode: Int) throws -> HTTPURLResponse {
    let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))

    return try #require(HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    ))
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
