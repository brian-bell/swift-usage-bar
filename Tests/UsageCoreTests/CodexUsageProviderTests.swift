import Foundation
import Testing
import UsageCore

@Test
func codexUsageProviderBuildsUsageRequestAndReturnsFreshUsage() async throws {
    let asOf = Date(timeIntervalSince1970: 1_783_000_120)
    let credential = CodexCredential(
        accessToken: "access-token",
        accountID: "account-123",
        expiresAt: Date(timeIntervalSince1970: 1_783_006_145)
    )
    let transport = FakeHTTPTransport(response: (
        try fixtureData("codex-usage.json"),
        try httpResponse(statusCode: 200)
    ))
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(result: .fresh(credential)),
        transport: transport,
        now: { asOf }
    )

    let state = await provider.fetch(previous: nil)
    let request = try #require(transport.requests.first)

    #expect(state == .fresh(ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(
            percentRemaining: 56,
            resetsAt: Date(timeIntervalSince1970: 1_783_388_608)
        )
    ), asOf: asOf))
    #expect(transport.requests.count == 1)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
    #expect(request.value(forHTTPHeaderField: "User-Agent")?.isEmpty == false)
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-123")
}

@Test
func codexUsageProviderUsesPrimaryAsWeeklyWhenSecondaryIsNull() async throws {
    let asOf = Date(timeIntervalSince1970: 1_783_000_120)
    let response = Data("""
    {
      "rate_limit": {
        "primary_window": {
          "limit_window_seconds": 604800,
          "reset_at": 1783006145,
          "used_percent": 24
        },
        "secondary_window": null
      }
    }
    """.utf8)
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(result: .fresh(validCredential())),
        transport: FakeHTTPTransport(response: (response, try httpResponse(statusCode: 200))),
        now: { asOf }
    )

    let state = await provider.fetch(previous: sampleUsage(fiveHour: 69, weekly: 77))

    #expect(state == .fresh(ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(
            percentRemaining: 76,
            resetsAt: Date(timeIntervalSince1970: 1_783_006_145)
        )
    ), asOf: asOf))
}

@Test
func codexUsageProviderKeepsPreviousUsageWhenBothWindowsAreNull() async throws {
    let previous = sampleUsage(fiveHour: 69, weekly: 77)
    let response = Data("""
    {
      "rate_limit": {
        "primary_window": null,
        "secondary_window": null
      }
    }
    """.utf8)
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(result: .fresh(validCredential())),
        transport: FakeHTTPTransport(response: (response, try httpResponse(statusCode: 200))),
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: previous, reason: .parseFailure))
}

@Test
func codexUsageProviderOmitsAccountHeaderWhenCredentialHasNoAccountID() async throws {
    let transport = FakeHTTPTransport(response: (
        try fixtureData("codex-usage.json"),
        try httpResponse(statusCode: 200)
    ))
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(result: .fresh(CodexCredential(
            accessToken: "access-token",
            accountID: nil,
            expiresAt: Date(timeIntervalSince1970: 1_783_006_145)
        ))),
        transport: transport,
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    _ = await provider.fetch(previous: nil)
    let request = try #require(transport.requests.first)

    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
}

@Test
func codexUsageProviderOmitsAccountHeaderWhenCredentialAccountIDIsBlank() async throws {
    let transport = FakeHTTPTransport(response: (
        try fixtureData("codex-usage.json"),
        try httpResponse(statusCode: 200)
    ))
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(result: .fresh(CodexCredential(
            accessToken: "access-token",
            accountID: "  ",
            expiresAt: Date(timeIntervalSince1970: 1_783_006_145)
        ))),
        transport: transport,
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    _ = await provider.fetch(previous: nil)
    let request = try #require(transport.requests.first)

    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
}

@Test
func codexUsageProviderMapsCredentialFailuresWithoutSendingRequest() async throws {
    let previous = sampleUsage(fiveHour: 44, weekly: 66)
    let cases: [(CodexCredentialReadResult, StaleReason)] = [
        (.stale(reason: .tokenExpired), .tokenExpired),
        (.stale(reason: .credentialUnavailable), .credentialUnavailable),
        (.stale(reason: .parseFailure), .parseFailure),
    ]

    for (credentialResult, expectedReason) in cases {
        let transport = FakeHTTPTransport(response: (
            try fixtureData("codex-usage.json"),
            try httpResponse(statusCode: 200)
        ))
        let provider = CodexUsageProvider(
            credentialReader: FakeCodexCredentialReader(result: credentialResult),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_783_000_120) }
        )

        let state = await provider.fetch(previous: previous)

        #expect(state == .stale(last: previous, reason: expectedReason))
        #expect(transport.requests.isEmpty)
    }
}

@Test
func codexUsageProviderMapsThrowingCredentialReaderToCredentialUnavailableWithoutSendingRequest() async throws {
    let previous = sampleUsage(fiveHour: 44, weekly: 66)
    let transport = FakeHTTPTransport(response: (
        try fixtureData("codex-usage.json"),
        try httpResponse(statusCode: 200)
    ))
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(error: CredentialReaderError.unavailable),
        transport: transport,
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: previous, reason: .credentialUnavailable))
    #expect(transport.requests.isEmpty)
}

@Test
func codexUsageProviderFallsBackToAppServerOnlyWhenCredentialIsUnavailable() async throws {
    let asOf = Date(timeIntervalSince1970: 1_783_000_120)
    let appServerUsage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(
            percentRemaining: 73,
            resetsAt: Date(timeIntervalSince1970: 1_783_388_608)
        )
    )
    let transport = FakeHTTPTransport(response: (
        try fixtureData("codex-usage.json"),
        try httpResponse(statusCode: 200)
    ))
    let appServer = FakeCodexAppServerUsageReader(result: .fresh(appServerUsage))
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(result: .stale(reason: .credentialUnavailable)),
        transport: transport,
        appServerReader: appServer,
        now: { asOf }
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    #expect(report.state == .fresh(appServerUsage, asOf: asOf))
    #expect(report.source == .codexAppServer)
    #expect(report.chain == [
        ProviderDataSourceStep(.codexAPI, .failed(.credentialUnavailable)),
        ProviderDataSourceStep(.codexAppServer, .used),
    ])
    #expect(transport.requests.isEmpty)
    #expect(appServer.readCount == 1)
}

@Test
func codexUsageProviderFallsBackToAppServerWhenKeychainHasNoCLICredential() async throws {
    let asOf = Date(timeIntervalSince1970: 1_783_000_120)
    let appServerUsage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(
            percentRemaining: 73,
            resetsAt: Date(timeIntervalSince1970: 1_783_388_608)
        )
    )
    let transport = FakeHTTPTransport(error: URLError(.notConnectedToInternet))
    let appServer = FakeCodexAppServerUsageReader(result: .fresh(appServerUsage))
    let provider = CodexUsageProvider(
        credentialReader: CodexCredentialReader(store: EmptyCredentialStore()),
        transport: transport,
        appServerReader: appServer,
        now: { asOf }
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    #expect(report.state == .fresh(appServerUsage, asOf: asOf))
    #expect(report.source == .codexAppServer)
    #expect(report.chain == [
        ProviderDataSourceStep(.codexAPI, .failed(.credentialUnavailable)),
        ProviderDataSourceStep(.codexAppServer, .used),
    ])
    #expect(transport.requests.isEmpty)
    #expect(appServer.readCount == 1)
}

@Test
func codexAppServerFallbackRemainsAvailableAfterPollerStopAndRestart() async {
    let asOf = Date(timeIntervalSince1970: 1_783_000_120)
    let appServerUsage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(
            percentRemaining: 73,
            resetsAt: Date(timeIntervalSince1970: 1_783_388_608)
        )
    )
    let appServer = RestartAwareCodexAppServerUsageReader(usage: appServerUsage)
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(
            result: .stale(reason: .credentialUnavailable)
        ),
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        appServerReader: appServer,
        now: { asOf }
    )
    let appState = await AppState()
    let poller = UsagePoller(providers: [.codex: provider], appState: appState)

    await poller.start()
    await poller.waitUntilIdle()
    await poller.stop()
    await poller.start()
    await poller.waitUntilIdle()

    #expect(appServer.successfulReadCount == 2)
    #expect(await appState.providerState(for: .codex) == .fresh(appServerUsage, asOf: asOf))

    await poller.stop()
}

@Test
func codexUsageProviderDoesNotFallBackForNonUnavailableCredentialFailures() async {
    for reason in [StaleReason.tokenExpired, .parseFailure] {
        let appServer = FakeCodexAppServerUsageReader(
            result: .stale(reason: .credentialUnavailable)
        )
        let provider = CodexUsageProvider(
            credentialReader: FakeCodexCredentialReader(result: .stale(reason: reason)),
            transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
            appServerReader: appServer
        )

        let report = await provider.fetchReport(previous: nil, mode: .background)

        #expect(report.state == .stale(last: nil, reason: reason))
        #expect(report.chain == [ProviderDataSourceStep(.codexAPI, .failed(reason))])
        #expect(appServer.readCount == 0)
    }
}

@Test
func codexUsageProviderDoesNotFallBackAfterValidPrimaryAuthentication() async throws {
    let appServer = FakeCodexAppServerUsageReader(
        result: .stale(reason: .credentialUnavailable)
    )
    let providers = [
        CodexUsageProvider(
            credentialReader: FakeCodexCredentialReader(result: .fresh(validCredential())),
            transport: FakeHTTPTransport(response: (
                try fixtureData("codex-usage.json"),
                try httpResponse(statusCode: 500)
            )),
            appServerReader: appServer
        ),
        CodexUsageProvider(
            credentialReader: FakeCodexCredentialReader(result: .fresh(validCredential())),
            transport: FakeHTTPTransport(response: (
                Data("not json".utf8),
                try httpResponse(statusCode: 200)
            )),
            appServerReader: appServer
        ),
        CodexUsageProvider(
            credentialReader: FakeCodexCredentialReader(result: .fresh(validCredential())),
            transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
            appServerReader: appServer
        ),
    ]
    let expectedReasons = [
        StaleReason.networkError,
        .parseFailure,
        .networkError,
    ]

    for (provider, reason) in zip(providers, expectedReasons) {
        let report = await provider.fetchReport(previous: nil, mode: .background)

        #expect(report.state == .stale(last: nil, reason: reason))
    }
    #expect(appServer.readCount == 0)
}

@Test
func codexUsageProviderPreservesOriginalReasonAndPreviousUsageWhenFallbackFails() async {
    let previous = sampleUsage(fiveHour: 44, weekly: 66)
    let appServer = FakeCodexAppServerUsageReader(result: .stale(reason: .parseFailure))
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(error: CredentialReaderError.unavailable),
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        appServerReader: appServer
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .credentialUnavailable))
    #expect(report.source == nil)
    #expect(report.chain == [
        ProviderDataSourceStep(.codexAPI, .failed(.credentialUnavailable)),
        ProviderDataSourceStep(.codexAppServer, .failed(.parseFailure)),
    ])
    #expect(appServer.readCount == 1)
}

@Test
func codexUsageProviderMapsHTTPFailuresToStaleReasons() async throws {
    let previous = sampleUsage(fiveHour: 44, weekly: 66)
    let cases: [(Int, StaleReason)] = [
        (401, .tokenExpired),
        (429, .networkError),
        (500, .networkError),
        (503, .networkError),
    ]

    for (statusCode, expectedReason) in cases {
        let transport = FakeHTTPTransport(response: (
            try fixtureData("codex-usage.json"),
            try httpResponse(statusCode: statusCode)
        ))
        let provider = CodexUsageProvider(
            credentialReader: FakeCodexCredentialReader(result: .fresh(validCredential())),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_783_000_120) }
        )

        let state = await provider.fetch(previous: previous)

        #expect(state == .stale(last: previous, reason: expectedReason))
        #expect(transport.requests.count == 1)
    }
}

@Test
func codexUsageProviderMapsMalformedResponseBodyToParseFailure() async throws {
    let previous = sampleUsage(fiveHour: 44, weekly: 66)
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(result: .fresh(validCredential())),
        transport: FakeHTTPTransport(response: (
            Data("not json".utf8),
            try httpResponse(statusCode: 200)
        )),
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: previous, reason: .parseFailure))
}

@Test
func codexUsageProviderMapsTransportThrowToNetworkError() async {
    let previous = sampleUsage(fiveHour: 44, weekly: 66)
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(result: .fresh(validCredential())),
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: previous, reason: .networkError))
}

@Test
func codexUsageProviderForwardsInteractiveModeToCredentialReader() async {
    let reader = FakeCodexCredentialReader(result: .stale(reason: .tokenExpired))
    let provider = CodexUsageProvider(
        credentialReader: reader,
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    _ = await provider.fetch(previous: nil, mode: .interactive)

    #expect(reader.receivedModes == [.interactive])
}

@Test
func codexUsageProviderDefaultsToBackgroundMode() async {
    let reader = FakeCodexCredentialReader(result: .stale(reason: .tokenExpired))
    let provider = CodexUsageProvider(
        credentialReader: reader,
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    _ = await provider.fetch(previous: nil)

    #expect(reader.receivedModes == [.background])
}

private final class FakeCodexCredentialReader: CodexCredentialReading, @unchecked Sendable {
    private let result: CodexCredentialReadResult?
    private let error: (any Error)?
    private(set) var receivedModes: [CredentialAccessMode] = []

    init(result: CodexCredentialReadResult) {
        self.result = result
        self.error = nil
    }

    init(error: any Error) {
        self.result = nil
        self.error = error
    }

    func read(mode: CredentialAccessMode) throws -> CodexCredentialReadResult {
        receivedModes.append(mode)
        if let error {
            throw error
        }

        return result!
    }
}

private enum CredentialReaderError: Error {
    case unavailable
}

private struct EmptyCredentialStore: CredentialStore {
    func read(
        _ credential: CredentialIdentifier,
        mode: CredentialAccessMode
    ) throws -> Data? {
        nil
    }
}

private final class FakeCodexAppServerUsageReader: CodexAppServerUsageReading, @unchecked Sendable {
    private let result: CodexAppServerUsageReadResult
    private(set) var readCount = 0

    init(result: CodexAppServerUsageReadResult) {
        self.result = result
    }

    func readUsage() async -> CodexAppServerUsageReadResult {
        readCount += 1
        return result
    }
}

private final class RestartAwareCodexAppServerUsageReader:
    CodexAppServerUsageReading,
    @unchecked Sendable
{
    private let usage: ProviderUsage
    private var isShutDown = false
    private(set) var successfulReadCount = 0

    init(usage: ProviderUsage) {
        self.usage = usage
    }

    func readUsage() async -> CodexAppServerUsageReadResult {
        guard !isShutDown else {
            return .stale(reason: .credentialUnavailable)
        }
        successfulReadCount += 1
        return .fresh(usage)
    }

    func shutdown() async {
        isShutDown = true
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

private func validCredential() -> CodexCredential {
    CodexCredential(
        accessToken: "access-token",
        accountID: "account-123",
        expiresAt: Date(timeIntervalSince1970: 1_783_006_145)
    )
}

private func sampleUsage(fiveHour: Int, weekly: Int) -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(
            percentRemaining: fiveHour,
            resetsAt: Date(timeIntervalSince1970: 1_783_008_000)
        ),
        weekly: UsageWindow(
            percentRemaining: weekly,
            resetsAt: Date(timeIntervalSince1970: 1_783_555_200)
        )
    )
}

private func httpResponse(statusCode: Int) throws -> HTTPURLResponse {
    let url = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))

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

// MARK: - Winning data source reporting

@Test
func codexUsageProviderReportsTheChatGPTAPIAsItsSource() async throws {
    let asOf = Date(timeIntervalSince1970: 1_783_000_120)
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(result: .fresh(validCredential())),
        transport: FakeHTTPTransport(response: (
            try fixtureData("codex-usage.json"),
            try httpResponse(statusCode: 200)
        )),
        now: { asOf }
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    #expect(report.source == .codexAPI)
    #expect(report.state == .fresh(ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(
            percentRemaining: 56,
            resetsAt: Date(timeIntervalSince1970: 1_783_388_608)
        )
    ), asOf: asOf))
}

@Test
func codexUsageProviderReportsNoSourceAndPreservesStaleReasonWhenItFails() async {
    let previous = sampleUsage(fiveHour: 69, weekly: 77)
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(result: .stale(reason: .tokenExpired)),
        transport: FakeHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.source == nil)
    #expect(report.state == .stale(last: previous, reason: .tokenExpired))
}
