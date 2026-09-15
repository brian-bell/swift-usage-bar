import Foundation
import Testing
import UsageCore

@Test
func kimiProviderReturnsFreshCreditsOnSuccess() async throws {
    let receivedAt = Date(timeIntervalSince1970: 1_786_000_000)
    let fixture = try fixtureData("kimi-open-platform-balance.json")
    let transport = FakeKimiTransport(response: KimiOpenPlatformBalanceResponse(
        data: fixture,
        receivedAt: receivedAt
    ))
    let reader = FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk-test")))
    let provider = KimiOpenPlatformUsageProvider(
        credentialReader: reader,
        transport: transport
    )

    let report = await provider.fetchReport(previous: nil, mode: .interactive)
    let credits = try KimiOpenPlatformBalanceParser().parse(fixture)
    let expected = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: nil, resetsAt: nil),
        credits: credits
    )

    #expect(report.state == .fresh(expected, asOf: receivedAt))
    #expect(report.chain == [ProviderDataSourceStep(.kimiOpenPlatformBalance, .used)])
    #expect(report.source == .kimiOpenPlatformBalance)
    #expect(await transport.credentials == [KimiOpenPlatformCredential(key: "sk-test")])
    #expect(reader.modes == [.interactive])
}

@Test
func kimiProviderFreshUsageHasNoPercentWindows() async throws {
    let fixture = try fixtureData("kimi-open-platform-balance.json")
    let provider = KimiOpenPlatformUsageProvider(
        credentialReader: FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk"))),
        transport: FakeKimiTransport(response: KimiOpenPlatformBalanceResponse(
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
    #expect(usage.credits == CreditBalance(balanceUSD: 12.34))
}

@Test
func kimiProviderIsStaleCredentialUnavailableWhenReaderReturnsAbsent() async {
    let previous = sampleKimiUsage()
    let transport = FakeKimiTransport(response: KimiOpenPlatformBalanceResponse(
        data: Data(),
        receivedAt: Date()
    ))
    let provider = KimiOpenPlatformUsageProvider(
        credentialReader: FakeKimiCredentialReader(result: .stale(reason: .credentialUnavailable)),
        transport: transport
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .credentialUnavailable))
    #expect(await transport.credentials.isEmpty)
}

@Test
func kimiProviderIsStaleCredentialUnavailableWhenReaderThrows() async {
    let previous = sampleKimiUsage()
    let transport = FakeKimiTransport(response: KimiOpenPlatformBalanceResponse(
        data: Data(),
        receivedAt: Date()
    ))
    let provider = KimiOpenPlatformUsageProvider(
        credentialReader: FakeKimiCredentialReader(error: TestError.boom),
        transport: transport
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .credentialUnavailable))
    #expect(await transport.credentials.isEmpty)
}

@Test
func kimiProviderIsStaleTokenExpiredOn401() async {
    let previous = sampleKimiUsage()
    let provider = KimiOpenPlatformUsageProvider(
        credentialReader: FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk-bad"))),
        transport: FakeKimiTransport(error: KimiOpenPlatformTransportError.notAuthenticated)
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .tokenExpired))
}

@Test
func kimiProviderIsStaleParseFailureOnMalformedBody() async {
    let previous = sampleKimiUsage()
    let provider = KimiOpenPlatformUsageProvider(
        credentialReader: FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk-test"))),
        transport: FakeKimiTransport(response: KimiOpenPlatformBalanceResponse(
            data: Data("not json".utf8),
            receivedAt: Date()
        ))
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .parseFailure))
}

@Test
func kimiProviderIsStaleNetworkErrorOnTransportError() async {
    let previous = sampleKimiUsage()
    let provider = KimiOpenPlatformUsageProvider(
        credentialReader: FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk-test"))),
        transport: FakeKimiTransport(error: TestError.boom)
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .networkError))
}

@Test
func kimiProviderPreservesLastKnownUsageOnEveryStaleMapping() async throws {
    let previous = sampleKimiUsage()
    let cases: [(any KimiOpenPlatformCredentialReading, any KimiOpenPlatformTransporting, StaleReason)] = [
        (
            FakeKimiCredentialReader(result: .stale(reason: .credentialUnavailable)),
            FakeKimiTransport(error: TestError.boom),
            .credentialUnavailable
        ),
        (
            FakeKimiCredentialReader(error: TestError.boom),
            FakeKimiTransport(error: TestError.boom),
            .credentialUnavailable
        ),
        (
            FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk"))),
            FakeKimiTransport(error: KimiOpenPlatformTransportError.notAuthenticated),
            .tokenExpired
        ),
        (
            FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk"))),
            FakeKimiTransport(response: KimiOpenPlatformBalanceResponse(
                data: Data("not json".utf8),
                receivedAt: Date()
            )),
            .parseFailure
        ),
        (
            FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk"))),
            FakeKimiTransport(error: TestError.boom),
            .networkError
        ),
    ]

    for (reader, transport, reason) in cases {
        let provider = KimiOpenPlatformUsageProvider(credentialReader: reader, transport: transport)
        let state = await provider.fetch(previous: previous, mode: .background)
        #expect(state == .stale(last: previous, reason: reason))
    }
}

@Test
func kimiProviderReportsSingleStepFailedOnEveryStaleMapping() async throws {
    let cases: [(any KimiOpenPlatformCredentialReading, any KimiOpenPlatformTransporting, StaleReason)] = [
        (
            FakeKimiCredentialReader(result: .stale(reason: .credentialUnavailable)),
            FakeKimiTransport(error: TestError.boom),
            .credentialUnavailable
        ),
        (
            FakeKimiCredentialReader(error: TestError.boom),
            FakeKimiTransport(error: TestError.boom),
            .credentialUnavailable
        ),
        (
            FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk"))),
            FakeKimiTransport(error: KimiOpenPlatformTransportError.notAuthenticated),
            .tokenExpired
        ),
        (
            FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk"))),
            FakeKimiTransport(response: KimiOpenPlatformBalanceResponse(
                data: Data("not json".utf8),
                receivedAt: Date()
            )),
            .parseFailure
        ),
        (
            FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk"))),
            FakeKimiTransport(error: TestError.boom),
            .networkError
        ),
    ]

    for (reader, transport, reason) in cases {
        let provider = KimiOpenPlatformUsageProvider(credentialReader: reader, transport: transport)
        let report = await provider.fetchReport(previous: nil, mode: .background)
        #expect(report.chain == [ProviderDataSourceStep(.kimiOpenPlatformBalance, .failed(reason))])
        #expect(report.source == nil)
    }
}

@Test
func kimiProviderChainStepFailureEqualsSurfacedReason() async throws {
    let cases: [(any KimiOpenPlatformCredentialReading, any KimiOpenPlatformTransporting, StaleReason)] = [
        (
            FakeKimiCredentialReader(result: .stale(reason: .credentialUnavailable)),
            FakeKimiTransport(error: TestError.boom),
            .credentialUnavailable
        ),
        (
            FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk"))),
            FakeKimiTransport(error: KimiOpenPlatformTransportError.notAuthenticated),
            .tokenExpired
        ),
        (
            FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk"))),
            FakeKimiTransport(response: KimiOpenPlatformBalanceResponse(
                data: Data("not json".utf8),
                receivedAt: Date()
            )),
            .parseFailure
        ),
        (
            FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk"))),
            FakeKimiTransport(error: TestError.boom),
            .networkError
        ),
    ]

    for (reader, transport, expectedReason) in cases {
        let provider = KimiOpenPlatformUsageProvider(credentialReader: reader, transport: transport)
        let report = await provider.fetchReport(previous: sampleKimiUsage(), mode: .background)

        guard case let .stale(_, reason: surfaced) = report.state else {
            Issue.record("Expected stale state")
            continue
        }
        #expect(surfaced == expectedReason)
        #expect(report.chain.count == 1)
        guard case let .failed(stepReason) = report.chain[0].outcome else {
            Issue.record("Expected failed chain step")
            continue
        }
        #expect(stepReason == surfaced)
    }
}

@Test
func kimiProviderFreshPathThroughRealHTTPTransportAdapter() async throws {
    let receivedAt = Date(timeIntervalSince1970: 1_786_000_000)
    let fixture = try fixtureData("kimi-open-platform-balance.json")
    let url = try #require(URL(string: "https://api.moonshot.ai/v1/users/me/balance"))
    let response = try #require(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    )
    let sender = RecordingHTTPTransport(response: (fixture, response))
    let transport = KimiOpenPlatformHTTPTransport(sender: sender, now: { receivedAt })
    let reader = FakeKimiCredentialReader(result: .fresh(KimiOpenPlatformCredential(key: "sk-test")))

    let provider = KimiOpenPlatformUsageProvider(credentialReader: reader, transport: transport)
    let report = await provider.fetchReport(previous: nil, mode: .interactive)

    let credits = try KimiOpenPlatformBalanceParser().parse(fixture)
    let expected = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: nil, resetsAt: nil),
        credits: credits
    )
    #expect(report.state == .fresh(expected, asOf: receivedAt))
    #expect(report.chain == [ProviderDataSourceStep(.kimiOpenPlatformBalance, .used)])
    #expect(report.source == .kimiOpenPlatformBalance)
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

private final class FakeKimiCredentialReader: KimiOpenPlatformCredentialReading, @unchecked Sendable {
    let result: KimiOpenPlatformCredentialReadResult?
    let error: (any Error)?
    private(set) var modes: [CredentialAccessMode] = []

    init(result: KimiOpenPlatformCredentialReadResult) {
        self.result = result
        self.error = nil
    }

    init(error: any Error) {
        self.result = nil
        self.error = error
    }

    func read(mode: CredentialAccessMode) throws -> KimiOpenPlatformCredentialReadResult {
        modes.append(mode)
        if let error {
            throw error
        }
        return result!
    }
}

private actor FakeKimiTransport: KimiOpenPlatformTransporting {
    private let response: KimiOpenPlatformBalanceResponse?
    private let error: (any Error)?
    private(set) var credentials: [KimiOpenPlatformCredential] = []

    init(response: KimiOpenPlatformBalanceResponse) {
        self.response = response
        self.error = nil
    }

    init(error: any Error) {
        self.response = nil
        self.error = error
    }

    func fetchBalance(credential: KimiOpenPlatformCredential) async throws -> KimiOpenPlatformBalanceResponse {
        credentials.append(credential)
        if let error {
            throw error
        }
        return response!
    }
}

private func sampleKimiUsage() -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: nil, resetsAt: nil),
        credits: CreditBalance(balanceUSD: 12.34)
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
