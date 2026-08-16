import Foundation
import Testing
import UsageCore

// Per-step chain accumulation: every provider reports the ordered list of
// retrieval steps it walked, not just the winner. Claude is the interesting
// case — three steps, tried in order, each with its own outcome.

// MARK: - Declared chains

@Test
func providerDataSourceChainListsEachProvidersSourcesInFallbackOrder() {
    #expect(ProviderID.claude.dataSourceChain == [
        .claudeWebSession,
        .claudeOAuthAPI,
        .claudeStatuslineCache,
    ])
    #expect(ProviderID.codex.dataSourceChain == [.codexAPI, .codexAppServer])
    #expect(ProviderID.openCodeGo.dataSourceChain == [.openCodeGoChromeCookie])
    #expect(ProviderID.openCodeCredits.dataSourceChain == [.openCodeCreditsChromeCookie])
    #expect(ProviderID.miniMax.dataSourceChain == [.minimaxTokenPlanAPI])
    #expect(ProviderID.cursor.dataSourceChain == [.cursorUsageSummary])
}

@Test
func openCodeCreditsChromeCookieDataSourceNamesMatchTheProviderStatusConvention() {
    #expect(ProviderDataSource.openCodeCreditsChromeCookie.provider == .openCodeCredits)
    #expect(ProviderDataSource.openCodeCreditsChromeCookie.displayName == "Chrome cookie")
    #expect(
        ProviderDataSource.openCodeCreditsChromeCookie.chainStepName
            == "Chrome cookie \u{00B7} opencode.ai"
    )
}

@Test
func minimaxTokenPlanAPIDataSourceNamesMatchTheProviderStatusConvention() {
    #expect(ProviderDataSource.minimaxTokenPlanAPI.provider == .miniMax)
    #expect(ProviderDataSource.minimaxTokenPlanAPI.displayName == "MiniMax token plan API")
    #expect(ProviderDataSource.minimaxTokenPlanAPI.chainStepName == "MiniMax token plan API (OpenCode key)")
}

@Test
func cursorUsageSummaryDataSourceNamesMatchTheProviderStatusConvention() {
    #expect(ProviderDataSource.cursorUsageSummary.provider == .cursor)
    #expect(ProviderDataSource.cursorUsageSummary.displayName == "Cursor usage-summary API")
    #expect(
        ProviderDataSource.cursorUsageSummary.chainStepName
            == "Cursor usage-summary \u{00B7} Local IDE session"
    )
}

@Test
func providerFetchReportDerivesTheWinningSourceFromTheUsedStep() {
    let report = ProviderFetchReport(
        state: .fresh(chainUsage(fiveHour: 88, weekly: 74), asOf: chainNow),
        chain: [
            ProviderDataSourceStep(.claudeWebSession, .failed(.sessionExpired)),
            ProviderDataSourceStep(.claudeOAuthAPI, .used),
        ]
    )

    #expect(report.source == .claudeOAuthAPI)
}

@Test
func providerFetchReportWithoutAUsedStepReportsNoWinningSource() {
    let report = ProviderFetchReport(
        state: .stale(last: nil, reason: .tokenExpired),
        chain: [ProviderDataSourceStep(.claudeOAuthAPI, .failed(.tokenExpired))]
    )

    #expect(report.source == nil)
}

@Test
func providerFetchReportBuiltFromASourceSynthesizesASingleUsedStep() {
    // The slice-#31 initialiser stays valid: naming a winning source is the same
    // thing as a one-step chain whose only step was used.
    let report = ProviderFetchReport(
        state: .fresh(chainUsage(fiveHour: 88, weekly: 74), asOf: chainNow),
        source: .codexAPI
    )

    #expect(report.chain == [ProviderDataSourceStep(.codexAPI, .used)])
    #expect(report.source == .codexAPI)
}

// MARK: - Claude chain permutations

@Test
func claudeChainReportsWebSessionUsedAndLeavesLaterStepsUnattempted() async throws {
    let provider = ClaudeUsageProvider(
        credentialReader: ChainCredentialReader(result: .fresh(chainCredential())),
        cacheReader: ChainCacheReader(),
        transport: ChainHTTPTransport(error: URLError(.notConnectedToInternet)),
        webSessionReader: ChainWebSessionReader(result: chainWebSession),
        webTransport: ChainWebTransport(response: ClaudeWebPageResponse(
            data: try chainFixtureData("claude-usage.json"),
            receivedAt: chainNow
        )),
        now: { chainNow }
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    // Only the step that ran is reported; the view model pads the rest as
    // "Standing by", which is exactly what an unattempted later step means.
    #expect(report.chain == [ProviderDataSourceStep(.claudeWebSession, .used)])
    #expect(report.source == .claudeWebSession)
}

@Test
func claudeChainReportsWebFailureThenOAuthUsed() async throws {
    let provider = ClaudeUsageProvider(
        credentialReader: ChainCredentialReader(result: .fresh(chainCredential())),
        cacheReader: ChainCacheReader(),
        transport: ChainHTTPTransport(response: (
            try chainFixtureData("claude-usage.json"),
            try chainHTTPResponse(statusCode: 200)
        )),
        webSessionReader: ChainWebSessionReader(result: chainWebSession),
        webTransport: ChainWebTransport(error: ClaudeWebTransportError.sessionExpired),
        now: { chainNow }
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    #expect(report.chain == [
        ProviderDataSourceStep(.claudeWebSession, .failed(.sessionExpired)),
        ProviderDataSourceStep(.claudeOAuthAPI, .used),
    ])
    #expect(report.source == .claudeOAuthAPI)
}

@Test
func claudeChainReportsWebAndOAuthFailuresThenStatuslineCacheUsed() async {
    let cacheAsOf = Date(timeIntervalSince1970: 1_783_000_000)
    let cached = chainUsage(fiveHour: 62, weekly: 81)
    let provider = ClaudeUsageProvider(
        credentialReader: ChainCredentialReader(result: .stale(reason: .tokenExpired)),
        cacheReader: ChainCacheReader(result: .fresh(data: Data("{}".utf8), usage: cached, asOf: cacheAsOf)),
        transport: ChainHTTPTransport(error: URLError(.notConnectedToInternet)),
        webSessionReader: ChainWebSessionReader(result: chainWebSession),
        webTransport: ChainWebTransport(error: ClaudeWebTransportError.network),
        now: { chainNow }
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    #expect(report.chain == [
        ProviderDataSourceStep(.claudeWebSession, .failed(.networkError)),
        ProviderDataSourceStep(.claudeOAuthAPI, .failed(.tokenExpired)),
        ProviderDataSourceStep(.claudeStatuslineCache, .used),
    ])
    #expect(report.source == .claudeStatuslineCache)
    #expect(report.state == .fresh(cached, asOf: cacheAsOf))
}

@Test
func claudeChainReportsEveryStepFailedWhenAllPathsFail() async {
    let previous = chainUsage(fiveHour: 55, weekly: 75)
    let provider = ClaudeUsageProvider(
        credentialReader: ChainCredentialReader(result: .stale(reason: .tokenExpired)),
        cacheReader: ChainCacheReader(result: .stale(last: nil, reason: .parseFailure, hint: "hint")),
        transport: ChainHTTPTransport(error: URLError(.notConnectedToInternet)),
        webSessionReader: ChainWebSessionReader(result: chainWebSession),
        webTransport: ChainWebTransport(error: ClaudeWebTransportError.parseFailure),
        now: { chainNow }
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.chain == [
        ProviderDataSourceStep(.claudeWebSession, .failed(.parseFailure)),
        ProviderDataSourceStep(.claudeOAuthAPI, .failed(.tokenExpired)),
        ProviderDataSourceStep(.claudeStatuslineCache, .failed(.parseFailure)),
    ])
    #expect(report.source == nil)
    #expect(report.state == .stale(last: previous, reason: .tokenExpired))
}

@Test
func claudeChainRecordsCredentialUnavailableWhenChromeHasNoClaudeCookie() async throws {
    let provider = ClaudeUsageProvider(
        credentialReader: ChainCredentialReader(result: .fresh(chainCredential())),
        cacheReader: ChainCacheReader(),
        transport: ChainHTTPTransport(response: (
            try chainFixtureData("claude-usage.json"),
            try chainHTTPResponse(statusCode: 200)
        )),
        webSessionReader: ChainWebSessionReader(result: nil),
        webTransport: ChainWebTransport(error: ClaudeWebTransportError.network),
        now: { chainNow }
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    #expect(report.chain.first == ProviderDataSourceStep(
        .claudeWebSession,
        .failed(.credentialUnavailable)
    ))
}

@Test
func claudeChainOmitsTheWebStepEntirelyWhenTheWebPathIsNotWired() async throws {
    let provider = ClaudeUsageProvider(
        credentialReader: ChainCredentialReader(result: .fresh(chainCredential())),
        cacheReader: ChainCacheReader(),
        transport: ChainHTTPTransport(response: (
            try chainFixtureData("claude-usage.json"),
            try chainHTTPResponse(statusCode: 200)
        )),
        now: { chainNow }
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    #expect(report.chain == [ProviderDataSourceStep(.claudeOAuthAPI, .used)])
}

// MARK: - Silent-fallback invariant

@Test
func claudeWebFailureReasonNeverLeaksIntoTheProviderStaleReason() async {
    // CLAUDE.md: every web-path failure falls back *silently*. Recording the
    // reason per step for the chain UI must not change what the provider
    // reports upward — the surfaced reason stays the OAuth path's.
    let previous = chainUsage(fiveHour: 55, weekly: 75)
    let provider = ClaudeUsageProvider(
        credentialReader: ChainCredentialReader(result: .stale(reason: .tokenExpired)),
        cacheReader: ChainCacheReader(result: .stale(last: nil, reason: .networkError, hint: "")),
        transport: ChainHTTPTransport(error: URLError(.notConnectedToInternet)),
        webSessionReader: ChainWebSessionReader(result: chainWebSession),
        webTransport: ChainWebTransport(error: ClaudeWebTransportError.sessionExpired),
        now: { chainNow }
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .tokenExpired))
    #expect(report.chain.first?.outcome == .failed(.sessionExpired))
}

@Test
func claudeStatuslineCacheFailureReasonNeverLeaksIntoTheProviderStaleReason() async {
    let previous = chainUsage(fiveHour: 55, weekly: 75)
    let provider = ClaudeUsageProvider(
        credentialReader: ChainCredentialReader(result: .stale(reason: .credentialUnavailable)),
        cacheReader: ChainCacheReader(result: .stale(last: nil, reason: .parseFailure, hint: "")),
        transport: ChainHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { chainNow }
    )

    let report = await provider.fetchReport(previous: previous, mode: .background)

    #expect(report.state == .stale(last: previous, reason: .credentialUnavailable))
    #expect(report.chain.last?.outcome == .failed(.parseFailure))
}

// MARK: - Single-step providers

@Test
func codexChainReportsItsSingleStepAsUsedOnSuccess() async throws {
    let provider = CodexUsageProvider(
        credentialReader: ChainCodexCredentialReader(result: .fresh(
            CodexCredential(
                accessToken: "token",
                accountID: nil,
                expiresAt: Date(timeIntervalSince1970: 1_783_154_084)
            )
        )),
        transport: ChainHTTPTransport(response: (
            try chainFixtureData("codex-usage.json"),
            try chainHTTPResponse(statusCode: 200)
        )),
        now: { chainNow }
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    #expect(report.chain == [ProviderDataSourceStep(.codexAPI, .used)])
    #expect(report.source == .codexAPI)
}

@Test
func codexChainReportsItsSingleStepFailureReason() async {
    let provider = CodexUsageProvider(
        credentialReader: ChainCodexCredentialReader(result: .stale(reason: .tokenExpired)),
        transport: ChainHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { chainNow }
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    #expect(report.chain == [ProviderDataSourceStep(.codexAPI, .failed(.tokenExpired))])
    #expect(report.source == nil)
}

@Test
func openCodeGoChainReportsItsSingleStepFailureReason() async {
    let provider = OpenCodeGoProvider(
        sessionReader: ChainOpenCodeSessionReader(session: nil),
        transport: ChainOpenCodeTransport(),
        workspaceOverride: { nil }
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    #expect(report.chain == [
        ProviderDataSourceStep(.openCodeGoChromeCookie, .failed(.credentialUnavailable)),
    ])
    #expect(report.source == nil)
}

@Test
func minimaxTokenPlanAPIChainStepPhraseRoutesPerSource() {
    // An `sk-…` API key doesn't expire on the wire — the server rejects it.
    // The chain step must reflect that, not the generic "Token expired" /
    // "Session expired" wording that fits the OAuth/cookie providers.
    #expect(
        ProviderDataSource.minimaxTokenPlanAPI.chainFailureSummary(for: .tokenExpired)
            == "Key rejected"
    )
    #expect(
        ProviderDataSource.minimaxTokenPlanAPI.chainFailureSummary(for: .sessionExpired)
            == "Key rejected"
    )
    // The other HTTPS API sources keep their generic wording.
    #expect(
        ProviderDataSource.codexAPI.chainFailureSummary(for: .tokenExpired)
            == "Token expired"
    )
    #expect(
        ProviderDataSource.openCodeGoChromeCookie.chainFailureSummary(for: .sessionExpired)
            == "Session expired"
    )
}

// MARK: - Statusline-cache step wording, driven by the real reader

// The statusline cache is a local file: no step of reading it involves the
// network, so no failure of it may be rendered as "Network error". These drive
// the production `ClaudeStatuslineCacheReader` end to end — reader reason in,
// rendered step text out — so the phrase table can't drift from the reasons the
// reader can actually produce.

private func claudeChainStepText(_ report: ProviderFetchReport) throws -> [String] {
    let model = ProviderStatusViewModel(
        states: [.claude: report.state],
        chains: [.claude: report.chain],
        now: chainNow
    )
    return try #require(model.rows.first { $0.provider == .claude }).chain.steps.map(\.stateText)
}

private func claudeProviderReadingCache(at cacheURL: URL) -> ClaudeUsageProvider {
    // Both earlier steps fail so the fetch reaches the cache: no web path wired,
    // and an expired OAuth credential that short-circuits before any request.
    ClaudeUsageProvider(
        credentialReader: ChainCredentialReader(result: .stale(reason: .tokenExpired)),
        cacheReader: ClaudeStatuslineCacheReader(cacheURL: cacheURL, maximumAge: 300),
        transport: ChainHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { chainNow }
    )
}

@Test
func claudeChainNamesAMissingStatuslineCacheInsteadOfBlamingTheNetwork() async throws {
    // The default configuration for anyone who has never run
    // `scripts/setup-statusline`: there is no cache file at all.
    let missingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("claude-status.json")

    let report = await claudeProviderReadingCache(at: missingURL)
        .fetchReport(previous: nil, mode: .background)

    #expect(try claudeChainStepText(report) == [
        "Standing by",
        "Token expired",
        "No cache file",
    ])
    // Silent fallback is unchanged: the cache's reason stays inside the chain.
    #expect(report.state == .stale(last: nil, reason: .tokenExpired))
}

@Test
func claudeChainNamesAnOutOfDateStatuslineCacheInsteadOfBlamingTheNetwork() async throws {
    // A wired statusline whose owner simply hasn't run Claude Code for a while:
    // the cache exists and parses, it is only older than the freshness bound.
    let cacheURL = try writeChainCacheFile(
        data: try chainFixtureData("claude-statusline.json"),
        modifiedAt: chainNow.addingTimeInterval(-301)
    )

    let report = await claudeProviderReadingCache(at: cacheURL)
        .fetchReport(previous: nil, mode: .background)

    #expect(try claudeChainStepText(report).last == "Cache out of date")
    // The cache's last-known usage is still surfaced under the OAuth reason.
    if case let .stale(last: last, reason: reason) = report.state {
        #expect(last?.fiveHour.percentRemaining == 62)
        #expect(reason == .tokenExpired)
    } else {
        Issue.record("expected a stale state, got \(report.state)")
    }
}

@Test
func claudeChainNamesAnUnreadableStatuslineCacheInsteadOfBlamingTheNetwork() async throws {
    let provider = ClaudeUsageProvider(
        credentialReader: ChainCredentialReader(result: .stale(reason: .tokenExpired)),
        cacheReader: ThrowingChainCacheReader(),
        transport: ChainHTTPTransport(error: URLError(.notConnectedToInternet)),
        now: { chainNow }
    )

    let report = await provider.fetchReport(previous: nil, mode: .background)

    #expect(try claudeChainStepText(report).last == "No cache file")
}

// MARK: - Fixtures and doubles

// 2026-01-01 12:00 UTC
private let chainNow = Date(timeIntervalSince1970: 1_767_268_800)
private let chainWebSession = ClaudeWebSession(cookieHeader: "sessionKey=x", organizationHint: "org")

private func chainUsage(fiveHour: Int, weekly: Int) -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: fiveHour, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: weekly, resetsAt: nil)
    )
}

private func chainCredential() -> ClaudeCredential {
    ClaudeCredential(accessToken: "access-token", expiresAt: Date(timeIntervalSince1970: 1_783_154_084))
}

private func chainHTTPResponse(statusCode: Int) throws -> HTTPURLResponse {
    let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
    return try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
}

private func chainFixtureData(_ name: String) throws -> Data {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: packageRoot.appendingPathComponent("Tests/Fixtures").appendingPathComponent(name))
}

private struct ChainCredentialReader: ClaudeCredentialReading {
    let result: ClaudeCredentialReadResult
    func read(mode _: CredentialAccessMode) throws -> ClaudeCredentialReadResult { result }
}

private struct ChainCodexCredentialReader: CodexCredentialReading {
    let result: CodexCredentialReadResult
    func read(mode _: CredentialAccessMode) throws -> CodexCredentialReadResult { result }
}

private struct ChainCacheReader: ClaudeStatuslineCacheReading {
    var result: ClaudeStatuslineCacheReadResult = .stale(last: nil, reason: .networkError, hint: "")
    func read(now _: Date) throws -> ClaudeStatuslineCacheReadResult { result }
}

private struct ThrowingChainCacheReader: ClaudeStatuslineCacheReading {
    func read(now _: Date) throws -> ClaudeStatuslineCacheReadResult {
        throw CocoaError(.fileReadUnknown)
    }
}

private func writeChainCacheFile(data: Data, modifiedAt: Date) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let fileURL = directory.appendingPathComponent("claude-status.json")
    try data.write(to: fileURL)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: fileURL.path)

    return fileURL
}

private struct ChainHTTPTransport: HTTPTransport {
    var response: (Data, HTTPURLResponse)?
    var error: (any Error)?

    init(response: (Data, HTTPURLResponse)) { self.response = response }
    init(error: any Error) { self.error = error }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let error { throw error }
        return response!
    }
}

private struct ChainWebSessionReader: ClaudeWebSessionReading {
    let result: ClaudeWebSession?
    func readSession(mode _: CredentialAccessMode) throws -> ClaudeWebSession? { result }
}

private struct ChainWebTransport: ClaudeWebTransporting {
    var response: ClaudeWebPageResponse?
    var error: (any Error)?

    init(response: ClaudeWebPageResponse) { self.response = response }
    init(error: any Error) { self.error = error }

    func fetchUsage(session _: ClaudeWebSession) async throws -> ClaudeWebPageResponse {
        if let error { throw error }
        return response!
    }
}

private struct ChainOpenCodeSessionReader: OpenCodeSessionReading {
    let session: OpenCodeSession?
    func readSession(mode _: CredentialAccessMode) throws -> OpenCodeSession? { session }
}

private struct ChainOpenCodeTransport: OpenCodeGoTransporting {
    func discoverWorkspaceIDs(session _: OpenCodeSession) async throws -> [String] { [] }
    func fetchUsagePage(workspaceID _: String, session _: OpenCodeSession) async throws -> OpenCodeGoPageResponse {
        throw UsageParsingError.parseFailure
    }
}
