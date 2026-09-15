import Foundation
import Testing
import UsageCore

@Test
func xaiProviderReturnsFreshCreditsOnSuccess() async throws {
    let receivedAt = Date(timeIntervalSince1970: 1_786_000_000)
    let fixture = try fixtureData("xai-prepaid-balance.json")
    let transport = FakeXAITransport(response: XAIPrepaidBalanceResponse(
        data: fixture,
        receivedAt: receivedAt
    ))
    let reader = FakeXAICredentialReader(result: .fresh(XAIManagementCredential(
        key: "xai-mgmt",
        teamID: "00000000-0000-4000-8000-000000000001"
    )))
    let provider = XAIPrepaidUsageProvider(credentialReader: reader, transport: transport)

    let report = await provider.fetchReport(previous: nil, mode: .interactive)
    let credits = try XAIPrepaidBalanceParser().parse(fixture)
    let expected = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: nil, resetsAt: nil),
        credits: credits
    )

    #expect(report.state == .fresh(expected, asOf: receivedAt))
    #expect(report.chain == [ProviderDataSourceStep(.xaiPrepaidBalance, .used)])
    #expect(report.source == .xaiPrepaidBalance)
    #expect(await transport.credentials == [
        XAIManagementCredential(key: "xai-mgmt", teamID: "00000000-0000-4000-8000-000000000001"),
    ])
    #expect(reader.modes == [.interactive])
}

@Test
func xaiProviderFreshUsageHasNoPercentWindows() async throws {
    let fixture = try fixtureData("xai-prepaid-balance.json")
    let provider = XAIPrepaidUsageProvider(
        credentialReader: FakeXAICredentialReader(result: .fresh(XAIManagementCredential(
            key: "k",
            teamID: "00000000-0000-4000-8000-000000000001"
        ))),
        transport: FakeXAITransport(response: XAIPrepaidBalanceResponse(
            data: fixture,
            receivedAt: Date()
        ))
    )

    let state = await provider.fetch(previous: nil, mode: .background)
    guard case let .fresh(usage, asOf: _) = state else {
        Issue.record("Expected fresh usage")
        return
    }
    #expect(usage.fiveHour.percentRemaining == nil)
    #expect(usage.weekly.percentRemaining == nil)
    #expect(usage.monthly == nil)
    #expect(usage.fable == nil)
    #expect(usage.grokBot == nil)
    #expect(usage.credits == CreditBalance(balanceUSD: 10))
}

@Test
func xaiProviderIsStaleCredentialUnavailableWhenReaderReturnsAbsent() async {
    let previous = sampleXAIUsage()
    let transport = FakeXAITransport(response: XAIPrepaidBalanceResponse(data: Data(), receivedAt: Date()))
    let provider = XAIPrepaidUsageProvider(
        credentialReader: FakeXAICredentialReader(result: .stale(reason: .credentialUnavailable)),
        transport: transport
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .credentialUnavailable))
    #expect(await transport.credentials.isEmpty)
}

@Test
func xaiProviderIsStaleTokenExpiredOn401() async {
    let previous = sampleXAIUsage()
    let provider = XAIPrepaidUsageProvider(
        credentialReader: FakeXAICredentialReader(result: .fresh(XAIManagementCredential(
            key: "bad",
            teamID: "00000000-0000-4000-8000-000000000001"
        ))),
        transport: FakeXAITransport(error: XAIPrepaidTransportError.notAuthenticated)
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .tokenExpired))
}

@Test
func xaiProviderIsStaleCredentialUnavailableOn404() async {
    let previous = sampleXAIUsage()
    let provider = XAIPrepaidUsageProvider(
        credentialReader: FakeXAICredentialReader(result: .fresh(XAIManagementCredential(
            key: "k",
            teamID: "00000000-0000-4000-8000-000000000001"
        ))),
        transport: FakeXAITransport(error: XAIPrepaidTransportError.prepaidUnavailable)
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .credentialUnavailable))
}

@Test
func xaiProviderIsStaleParseFailureOnMalformedBody() async {
    let previous = sampleXAIUsage()
    let provider = XAIPrepaidUsageProvider(
        credentialReader: FakeXAICredentialReader(result: .fresh(XAIManagementCredential(
            key: "k",
            teamID: "00000000-0000-4000-8000-000000000001"
        ))),
        transport: FakeXAITransport(response: XAIPrepaidBalanceResponse(
            data: Data("not json".utf8),
            receivedAt: Date()
        ))
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .parseFailure))
}

@Test
func xaiProviderIsStaleNetworkErrorOnTransportError() async {
    let previous = sampleXAIUsage()
    let provider = XAIPrepaidUsageProvider(
        credentialReader: FakeXAICredentialReader(result: .fresh(XAIManagementCredential(
            key: "k",
            teamID: "00000000-0000-4000-8000-000000000001"
        ))),
        transport: FakeXAITransport(error: TestError.boom)
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .networkError))
}

@Test
func xaiProviderPreservesLastKnownUsageOnEveryStaleMapping() async {
    let previous = sampleXAIUsage()
    let cases: [(any XAIManagementCredentialReading, any XAIPrepaidTransporting, StaleReason)] = [
        (
            FakeXAICredentialReader(result: .stale(reason: .credentialUnavailable)),
            FakeXAITransport(error: TestError.boom),
            .credentialUnavailable
        ),
        (
            FakeXAICredentialReader(result: .fresh(XAIManagementCredential(
                key: "k",
                teamID: "00000000-0000-4000-8000-000000000001"
            ))),
            FakeXAITransport(error: XAIPrepaidTransportError.notAuthenticated),
            .tokenExpired
        ),
        (
            FakeXAICredentialReader(result: .fresh(XAIManagementCredential(
                key: "k",
                teamID: "00000000-0000-4000-8000-000000000001"
            ))),
            FakeXAITransport(error: XAIPrepaidTransportError.prepaidUnavailable),
            .credentialUnavailable
        ),
        (
            FakeXAICredentialReader(result: .fresh(XAIManagementCredential(
                key: "k",
                teamID: "00000000-0000-4000-8000-000000000001"
            ))),
            FakeXAITransport(response: XAIPrepaidBalanceResponse(
                data: Data("not json".utf8),
                receivedAt: Date()
            )),
            .parseFailure
        ),
        (
            FakeXAICredentialReader(result: .fresh(XAIManagementCredential(
                key: "k",
                teamID: "00000000-0000-4000-8000-000000000001"
            ))),
            FakeXAITransport(error: TestError.boom),
            .networkError
        ),
    ]

    for (reader, transport, reason) in cases {
        let provider = XAIPrepaidUsageProvider(credentialReader: reader, transport: transport)
        let state = await provider.fetch(previous: previous, mode: .background)
        #expect(state == .stale(last: previous, reason: reason))
    }
}

@Test
func xaiProviderFreshPathThroughRealHTTPTransportAdapter() async throws {
    let receivedAt = Date(timeIntervalSince1970: 1_786_000_000)
    let fixture = try fixtureData("xai-prepaid-balance.json")
    let teamID = "00000000-0000-4000-8000-000000000001"
    let url = XAIPrepaidHTTPTransport.endpoint(teamID: teamID)
    let response = try #require(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    )
    let sender = RecordingHTTPTransport(response: (fixture, response))
    let transport = XAIPrepaidHTTPTransport(sender: sender, now: { receivedAt })
    let reader = FakeXAICredentialReader(result: .fresh(XAIManagementCredential(
        key: "xai-mgmt",
        teamID: teamID
    )))

    let provider = XAIPrepaidUsageProvider(credentialReader: reader, transport: transport)
    let report = await provider.fetchReport(previous: nil, mode: .interactive)

    let credits = try XAIPrepaidBalanceParser().parse(fixture)
    let expected = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: nil, resetsAt: nil),
        credits: credits
    )
    #expect(report.state == .fresh(expected, asOf: receivedAt))
    #expect(report.chain == [ProviderDataSourceStep(.xaiPrepaidBalance, .used)])
    #expect(sender.requests.count == 1)
}

private enum TestError: Error {
    case boom
}

private final class RecordingHTTPTransport: HTTPTransport, @unchecked Sendable {
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

private final class FakeXAICredentialReader: XAIManagementCredentialReading, @unchecked Sendable {
    let result: XAIManagementCredentialReadResult?
    let error: (any Error)?
    private(set) var modes: [CredentialAccessMode] = []

    init(result: XAIManagementCredentialReadResult) {
        self.result = result
        self.error = nil
    }

    func read(mode: CredentialAccessMode) throws -> XAIManagementCredentialReadResult {
        modes.append(mode)
        if let error {
            throw error
        }
        return result!
    }
}

private actor FakeXAITransport: XAIPrepaidTransporting {
    private let response: XAIPrepaidBalanceResponse?
    private let error: (any Error)?
    private(set) var credentials: [XAIManagementCredential] = []

    init(response: XAIPrepaidBalanceResponse) {
        self.response = response
        self.error = nil
    }

    init(error: any Error) {
        self.response = nil
        self.error = error
    }

    func fetchBalance(
        credential: XAIManagementCredential
    ) async throws -> XAIPrepaidBalanceResponse {
        credentials.append(credential)
        if let error {
            throw error
        }
        return response!
    }
}

private func sampleXAIUsage() -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: nil, resetsAt: nil),
        credits: CreditBalance(balanceUSD: 10)
    )
}

private func fixtureData(_ name: String) throws -> Data {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(
        contentsOf: packageRoot
            .appendingPathComponent("Tests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    )
}
