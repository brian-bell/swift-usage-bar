import Foundation
import Testing
import UsageCore

@Test
func miniMaxProviderReturnsFreshUsageOnSuccess() async throws {
    let receivedAt = Date(timeIntervalSince1970: 1_786_000_000)
    let fixture = try fixtureData("minimax-token-plan.json")
    let transport = FakeMiniMaxTransport(response: MiniMaxTokenPlanResponse(
        data: fixture,
        receivedAt: receivedAt
    ))
    let reader = FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk-test")))
    let provider = MiniMaxUsageProvider(
        credentialReader: reader,
        transport: transport
    )

    let report = await provider.fetchReport(previous: nil, mode: .interactive)
    let expected = try MiniMaxTokenPlanParser().parse(fixture)

    #expect(report.state == .fresh(expected, asOf: receivedAt))
    #expect(report.chain == [ProviderDataSourceStep(.minimaxTokenPlanAPI, .used)])
    #expect(report.source == .minimaxTokenPlanAPI)
    #expect(await transport.credentials == [MiniMaxCredential(key: "sk-test")])
    #expect(reader.modes == [.interactive])
}

@Test
func miniMaxProviderIsStaleCredentialUnavailableWhenReaderReturnsAbsent() async {
    let previous = sampleMiniMaxUsage()
    let transport = FakeMiniMaxTransport(response: MiniMaxTokenPlanResponse(
        data: Data(),
        receivedAt: Date()
    ))
    let provider = MiniMaxUsageProvider(
        credentialReader: FakeMiniMaxCredentialReader(result: .stale(reason: .credentialUnavailable)),
        transport: transport
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .credentialUnavailable))
    #expect(await transport.credentials.isEmpty)
}

@Test
func miniMaxProviderIsStaleCredentialUnavailableWhenReaderThrows() async {
    let previous = sampleMiniMaxUsage()
    let transport = FakeMiniMaxTransport(response: MiniMaxTokenPlanResponse(
        data: Data(),
        receivedAt: Date()
    ))
    let provider = MiniMaxUsageProvider(
        credentialReader: FakeMiniMaxCredentialReader(error: TestError.boom),
        transport: transport
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .credentialUnavailable))
    #expect(await transport.credentials.isEmpty)
}

@Test
func miniMaxProviderIsStaleTokenExpiredOn1004() async throws {
    let previous = sampleMiniMaxUsage()
    let provider = MiniMaxUsageProvider(
        credentialReader: FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk-bad"))),
        transport: FakeMiniMaxTransport(response: MiniMaxTokenPlanResponse(
            data: try fixtureData("minimax-token-plan-auth-failure.json"),
            receivedAt: Date()
        ))
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .tokenExpired))
}

@Test
func miniMaxProviderIsStaleParseFailureOnMalformedBody() async {
    let previous = sampleMiniMaxUsage()
    let provider = MiniMaxUsageProvider(
        credentialReader: FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk-test"))),
        transport: FakeMiniMaxTransport(response: MiniMaxTokenPlanResponse(
            data: Data("not json".utf8),
            receivedAt: Date()
        ))
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .parseFailure))
}

@Test
func miniMaxProviderIsStaleNetworkErrorOnTransportError() async {
    let previous = sampleMiniMaxUsage()
    let provider = MiniMaxUsageProvider(
        credentialReader: FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk-test"))),
        transport: FakeMiniMaxTransport(error: TestError.boom)
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .networkError))
}

@Test
func miniMaxProviderPreservesLastKnownUsageOnEveryStaleMapping() async throws {
    let previous = sampleMiniMaxUsage()
    let cases: [(any MiniMaxCredentialReading, any MiniMaxTransporting, StaleReason)] = [
        (
            FakeMiniMaxCredentialReader(result: .stale(reason: .credentialUnavailable)),
            FakeMiniMaxTransport(error: TestError.boom),
            .credentialUnavailable
        ),
        (
            FakeMiniMaxCredentialReader(error: TestError.boom),
            FakeMiniMaxTransport(error: TestError.boom),
            .credentialUnavailable
        ),
        (
            FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk"))),
            FakeMiniMaxTransport(response: MiniMaxTokenPlanResponse(
                data: try fixtureData("minimax-token-plan-auth-failure.json"),
                receivedAt: Date()
            )),
            .tokenExpired
        ),
        (
            FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk"))),
            FakeMiniMaxTransport(response: MiniMaxTokenPlanResponse(
                data: Data("not json".utf8),
                receivedAt: Date()
            )),
            .parseFailure
        ),
        (
            FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk"))),
            FakeMiniMaxTransport(error: TestError.boom),
            .networkError
        ),
    ]

    for (reader, transport, reason) in cases {
        let provider = MiniMaxUsageProvider(credentialReader: reader, transport: transport)
        let state = await provider.fetch(previous: previous, mode: .background)
        #expect(state == .stale(last: previous, reason: reason))
    }
}

@Test
func miniMaxProviderReportsSingleStepUsedOnSuccess() async throws {
    let provider = MiniMaxUsageProvider(
        credentialReader: FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk"))),
        transport: FakeMiniMaxTransport(response: MiniMaxTokenPlanResponse(
            data: try fixtureData("minimax-token-plan.json"),
            receivedAt: Date(timeIntervalSince1970: 1)
        ))
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    #expect(report.chain.count == 1)
    #expect(report.chain == [ProviderDataSourceStep(.minimaxTokenPlanAPI, .used)])
    #expect(report.source == .minimaxTokenPlanAPI)
}

@Test
func miniMaxProviderReportsSingleStepFailedOnEveryStaleMapping() async throws {
    let cases: [(any MiniMaxCredentialReading, any MiniMaxTransporting, StaleReason)] = [
        (
            FakeMiniMaxCredentialReader(result: .stale(reason: .credentialUnavailable)),
            FakeMiniMaxTransport(error: TestError.boom),
            .credentialUnavailable
        ),
        (
            FakeMiniMaxCredentialReader(error: TestError.boom),
            FakeMiniMaxTransport(error: TestError.boom),
            .credentialUnavailable
        ),
        (
            FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk"))),
            FakeMiniMaxTransport(response: MiniMaxTokenPlanResponse(
                data: try fixtureData("minimax-token-plan-auth-failure.json"),
                receivedAt: Date()
            )),
            .tokenExpired
        ),
        (
            FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk"))),
            FakeMiniMaxTransport(response: MiniMaxTokenPlanResponse(
                data: Data("not json".utf8),
                receivedAt: Date()
            )),
            .parseFailure
        ),
        (
            FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk"))),
            FakeMiniMaxTransport(error: TestError.boom),
            .networkError
        ),
    ]

    for (reader, transport, reason) in cases {
        let provider = MiniMaxUsageProvider(credentialReader: reader, transport: transport)
        let report = await provider.fetchReport(previous: nil, mode: .background)
        #expect(report.chain == [ProviderDataSourceStep(.minimaxTokenPlanAPI, .failed(reason))])
        #expect(report.source == nil)
    }
}

@Test
func miniMaxProviderChainStepFailureEqualsSurfacedReason() async throws {
    let cases: [(any MiniMaxCredentialReading, any MiniMaxTransporting, StaleReason)] = [
        (
            FakeMiniMaxCredentialReader(result: .stale(reason: .credentialUnavailable)),
            FakeMiniMaxTransport(error: TestError.boom),
            .credentialUnavailable
        ),
        (
            FakeMiniMaxCredentialReader(error: TestError.boom),
            FakeMiniMaxTransport(error: TestError.boom),
            .credentialUnavailable
        ),
        (
            FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk"))),
            FakeMiniMaxTransport(response: MiniMaxTokenPlanResponse(
                data: try fixtureData("minimax-token-plan-auth-failure.json"),
                receivedAt: Date()
            )),
            .tokenExpired
        ),
        (
            FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk"))),
            FakeMiniMaxTransport(response: MiniMaxTokenPlanResponse(
                data: Data("not json".utf8),
                receivedAt: Date()
            )),
            .parseFailure
        ),
        (
            FakeMiniMaxCredentialReader(result: .fresh(MiniMaxCredential(key: "sk"))),
            FakeMiniMaxTransport(error: TestError.boom),
            .networkError
        ),
    ]

    for (reader, transport, expectedReason) in cases {
        let provider = MiniMaxUsageProvider(credentialReader: reader, transport: transport)
        let report = await provider.fetchReport(previous: sampleMiniMaxUsage(), mode: .background)

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

private enum TestError: Error {
    case boom
}

private final class FakeMiniMaxCredentialReader: MiniMaxCredentialReading, @unchecked Sendable {
    let result: MiniMaxCredentialReadResult?
    let error: (any Error)?
    private(set) var modes: [CredentialAccessMode] = []

    init(result: MiniMaxCredentialReadResult) {
        self.result = result
        self.error = nil
    }

    init(error: any Error) {
        self.result = nil
        self.error = error
    }

    func read(mode: CredentialAccessMode) throws -> MiniMaxCredentialReadResult {
        modes.append(mode)
        if let error {
            throw error
        }
        return result!
    }
}

private actor FakeMiniMaxTransport: MiniMaxTransporting {
    private let response: MiniMaxTokenPlanResponse?
    private let error: (any Error)?
    private(set) var credentials: [MiniMaxCredential] = []

    init(response: MiniMaxTokenPlanResponse) {
        self.response = response
        self.error = nil
    }

    init(error: any Error) {
        self.response = nil
        self.error = error
    }

    func fetchTokenPlan(credential: MiniMaxCredential) async throws -> MiniMaxTokenPlanResponse {
        credentials.append(credential)
        if let error {
            throw error
        }
        return response!
    }
}

private func sampleMiniMaxUsage() -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 80, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 70, resetsAt: nil)
    )
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
