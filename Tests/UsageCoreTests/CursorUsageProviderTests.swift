import Foundation
import Testing
import UsageCore

@Test
func cursorProviderReturnsFreshUsageOnSuccess() async throws {
    let receivedAt = Date(timeIntervalSince1970: 1_786_000_000)
    let fixture = try cursorFixtureData("cursor-usage-summary.json")
    let transport = FakeCursorTransport(response: CursorUsageSummaryResponse(
        data: fixture,
        receivedAt: receivedAt
    ))
    let credential = sampleCursorCredential()
    let reader = FakeCursorCredentialReader(result: .fresh(credential))
    let provider = CursorUsageProvider(credentialReader: reader, transport: transport)

    let report = await provider.fetchReport(previous: nil, mode: .interactive)
    let expected = try CursorUsageSummaryParser().parse(fixture)

    #expect(report.state == .fresh(expected, asOf: receivedAt))
    #expect(report.chain == [ProviderDataSourceStep(.cursorUsageSummary, .used)])
    #expect(report.source == .cursorUsageSummary)
    #expect(await transport.credentials == [credential])
    #expect(reader.modes == [.interactive])
}

@Test
func cursorProviderIsStaleCredentialUnavailableWhenReaderReturnsAbsent() async {
    let previous = sampleCursorUsage()
    let transport = FakeCursorTransport(error: TestCursorError.boom)
    let provider = CursorUsageProvider(
        credentialReader: FakeCursorCredentialReader(result: .stale(reason: .credentialUnavailable)),
        transport: transport
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .credentialUnavailable))
    #expect(await transport.credentials.isEmpty)
}

@Test
func cursorProviderIsStaleTokenExpiredWhenReaderReportsExpiry() async {
    let previous = sampleCursorUsage()
    let transport = FakeCursorTransport(error: TestCursorError.boom)
    let provider = CursorUsageProvider(
        credentialReader: FakeCursorCredentialReader(result: .stale(reason: .tokenExpired)),
        transport: transport
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .tokenExpired))
    #expect(await transport.credentials.isEmpty)
}

@Test
func cursorProviderIsStaleTokenExpiredOnHTTP401() async {
    let previous = sampleCursorUsage()
    let provider = CursorUsageProvider(
        credentialReader: FakeCursorCredentialReader(result: .fresh(sampleCursorCredential())),
        transport: FakeCursorTransport(error: CursorUsageTransportError.notAuthenticated)
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .tokenExpired))
}

@Test
func cursorProviderIsStaleParseFailureOnMalformedBody() async {
    let previous = sampleCursorUsage()
    let provider = CursorUsageProvider(
        credentialReader: FakeCursorCredentialReader(result: .fresh(sampleCursorCredential())),
        transport: FakeCursorTransport(response: CursorUsageSummaryResponse(
            data: Data("not json".utf8),
            receivedAt: Date()
        ))
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .parseFailure))
}

@Test
func cursorProviderIsStaleNetworkErrorOnTransportError() async {
    let previous = sampleCursorUsage()
    let provider = CursorUsageProvider(
        credentialReader: FakeCursorCredentialReader(result: .fresh(sampleCursorCredential())),
        transport: FakeCursorTransport(error: TestCursorError.boom)
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .networkError))
}

@Test
func cursorProviderPreservesLastKnownUsageOnEveryStaleMapping() async {
    let previous = sampleCursorUsage()
    let cases: [(any CursorCredentialReading, any CursorUsageTransporting, StaleReason)] = [
        (
            FakeCursorCredentialReader(result: .stale(reason: .credentialUnavailable)),
            FakeCursorTransport(error: TestCursorError.boom),
            .credentialUnavailable
        ),
        (
            FakeCursorCredentialReader(result: .stale(reason: .tokenExpired)),
            FakeCursorTransport(error: TestCursorError.boom),
            .tokenExpired
        ),
        (
            FakeCursorCredentialReader(result: .fresh(sampleCursorCredential())),
            FakeCursorTransport(error: CursorUsageTransportError.notAuthenticated),
            .tokenExpired
        ),
        (
            FakeCursorCredentialReader(result: .fresh(sampleCursorCredential())),
            FakeCursorTransport(response: CursorUsageSummaryResponse(
                data: Data("not json".utf8),
                receivedAt: Date()
            )),
            .parseFailure
        ),
        (
            FakeCursorCredentialReader(result: .fresh(sampleCursorCredential())),
            FakeCursorTransport(error: TestCursorError.boom),
            .networkError
        ),
    ]

    for (reader, transport, reason) in cases {
        let provider = CursorUsageProvider(credentialReader: reader, transport: transport)
        let state = await provider.fetch(previous: previous, mode: .background)
        #expect(state == .stale(last: previous, reason: reason))
    }
}

@Test
func cursorProviderFreshPathThroughRealHTTPTransportAdapter() async throws {
    let receivedAt = Date(timeIntervalSince1970: 1_786_000_000)
    let fixture = try cursorFixtureData("cursor-usage-summary.json")
    let url = try #require(URL(string: "https://cursor.com/api/usage-summary"))
    let response = try #require(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    )
    let sender = RecordingCursorHTTPTransport(response: (fixture, response))
    let transport = CursorUsageHTTPTransport(sender: sender, now: { receivedAt })
    let credential = sampleCursorCredential()
    let reader = FakeCursorCredentialReader(result: .fresh(credential))

    let provider = CursorUsageProvider(credentialReader: reader, transport: transport)
    let report = await provider.fetchReport(previous: nil, mode: .interactive)

    let expected = try CursorUsageSummaryParser().parse(fixture)
    #expect(report.state == .fresh(expected, asOf: receivedAt))
    #expect(report.source == .cursorUsageSummary)
    let request = try #require(sender.requests.first)
    #expect(request.url == CursorUsageHTTPTransport.endpoint)
    #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=\(credential.cookieValue)")
    #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.com")
}

@Test
func cursorHTTPTransportMaps401ToNotAuthenticated() async throws {
    let url = try #require(URL(string: "https://cursor.com/api/usage-summary"))
    let response = try #require(
        HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)
    )
    let sender = RecordingCursorHTTPTransport(response: (Data("{\"error\":\"not_authenticated\"}".utf8), response))
    let transport = CursorUsageHTTPTransport(sender: sender)

    await #expect(throws: CursorUsageTransportError.notAuthenticated) {
        try await transport.fetchUsageSummary(credential: sampleCursorCredential())
    }
}

private enum TestCursorError: Error {
    case boom
}

private func sampleCursorCredential() -> CursorSessionCredential {
    CursorSessionCredential(
        accessToken: "token",
        cookieValue: "user_01TEST%3A%3Atoken",
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
}

private func sampleCursorUsage() -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 90, resetsAt: nil),
        monthly: UsageWindow(percentRemaining: 95, resetsAt: nil)
    )
}

private final class FakeCursorCredentialReader: CursorCredentialReading, @unchecked Sendable {
    let result: CursorCredentialReadResult?
    let error: (any Error)?
    private(set) var modes: [CredentialAccessMode] = []

    init(result: CursorCredentialReadResult) {
        self.result = result
        self.error = nil
    }

    init(error: any Error) {
        self.result = nil
        self.error = error
    }

    func read(mode: CredentialAccessMode, now _: Date) throws -> CursorCredentialReadResult {
        modes.append(mode)
        if let error {
            throw error
        }
        return result!
    }
}

private actor FakeCursorTransport: CursorUsageTransporting {
    private let response: CursorUsageSummaryResponse?
    private let error: (any Error)?
    private(set) var credentials: [CursorSessionCredential] = []

    init(response: CursorUsageSummaryResponse) {
        self.response = response
        self.error = nil
    }

    init(error: any Error) {
        self.response = nil
        self.error = error
    }

    func fetchUsageSummary(credential: CursorSessionCredential) async throws -> CursorUsageSummaryResponse {
        credentials.append(credential)
        if let error {
            throw error
        }
        return response!
    }
}

private final class RecordingCursorHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let response: (Data, HTTPURLResponse)
    private(set) var requests: [URLRequest] = []

    init(response: (Data, HTTPURLResponse)) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return response
    }
}
