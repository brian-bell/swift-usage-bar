import Foundation
import Testing
import UsageCore

// AppState retains the last reported retrieval chain per provider, mirroring how
// it retains the last winning source.

private func stateUsage(fiveHour: Int, weekly: Int) -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: fiveHour, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: weekly, resetsAt: nil)
    )
}

@Test
func appStateRecordsTheChainReportedWithARefreshResult() async {
    let appState = await AppState()
    let chain: [ProviderDataSourceStep] = [
        ProviderDataSourceStep(.claudeWebSession, .failed(.sessionExpired)),
        ProviderDataSourceStep(.claudeOAuthAPI, .used),
    ]

    await appState.applyRefreshResult(
        provider: .claude,
        state: .fresh(stateUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 10_000)),
        completedAt: Date(timeIntervalSince1970: 10_000),
        source: .claudeOAuthAPI,
        chain: chain
    )

    #expect(await appState.chain(provider: .claude) == chain)
    #expect(await appState.chains == [.claude: chain])
}

@Test
func appStateKeepsTheLastChainWhenAProviderReportsNoneAtAll() async {
    let appState = await AppState()
    let chain = [ProviderDataSourceStep(.claudeWebSession, .used)]

    await appState.applyRefreshResult(
        provider: .claude,
        state: .fresh(stateUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 10_000)),
        completedAt: Date(timeIntervalSince1970: 10_000),
        source: .claudeWebSession,
        chain: chain
    )
    await appState.applyRefreshResult(
        provider: .claude,
        state: .stale(last: nil, reason: .networkError),
        completedAt: Date(timeIntervalSince1970: 10_120),
        source: nil,
        chain: []
    )

    #expect(await appState.chain(provider: .claude) == chain)
}

@Test
func appStateReplacesTheChainWhenAFailingRefreshReportsItsOwnSteps() async {
    // Unlike the winning source, a failure chain is itself the thing the UI must
    // show — each step's failure is the story on a stale provider.
    let appState = await AppState()
    let failed = [ProviderDataSourceStep(.openCodeGoChromeCookie, .failed(.sessionExpired))]

    await appState.applyRefreshResult(
        provider: .openCodeGo,
        state: .fresh(stateUsage(fiveHour: 88, weekly: 74), asOf: Date(timeIntervalSince1970: 10_000)),
        completedAt: Date(timeIntervalSince1970: 10_000),
        source: .openCodeGoChromeCookie,
        chain: [ProviderDataSourceStep(.openCodeGoChromeCookie, .used)]
    )
    await appState.applyRefreshResult(
        provider: .openCodeGo,
        state: .stale(last: nil, reason: .sessionExpired),
        completedAt: Date(timeIntervalSince1970: 10_120),
        chain: failed
    )

    #expect(await appState.chain(provider: .openCodeGo) == failed)
}

@Test
func appStateClearsTheChainWhenAProviderBecomesHidden() async {
    let appState = await AppState()

    await appState.applyRefreshResult(
        provider: .codex,
        state: .fresh(stateUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 11_000)),
        completedAt: Date(timeIntervalSince1970: 11_000),
        source: .codexAPI,
        chain: [ProviderDataSourceStep(.codexAPI, .used)]
    )
    await appState.applyRefreshResult(
        provider: .codex,
        state: .hidden,
        completedAt: Date(timeIntervalSince1970: 11_120)
    )

    #expect(await appState.chain(provider: .codex) == nil)
    #expect(await appState.chains.isEmpty)
}

@Test
func usagePollerPlumbsEachProvidersChainIntoAppState() async {
    let appState = await AppState()
    let chain: [ProviderDataSourceStep] = [
        ProviderDataSourceStep(.claudeWebSession, .failed(.credentialUnavailable)),
        ProviderDataSourceStep(.claudeOAuthAPI, .used),
    ]
    let claude = ChainReportingUsageProvider(
        report: ProviderFetchReport(
            state: .fresh(stateUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 8_900)),
            chain: chain
        )
    )
    let poller = UsagePoller(providers: [.claude: claude], appState: appState)

    await poller.start()
    await claude.waitForFetchCount(1)
    await poller.waitUntilIdle()
    await poller.stop()

    #expect(await appState.chain(provider: .claude) == chain)
    #expect(await appState.dataSource(provider: .claude) == .claudeOAuthAPI)
}

@Test
func usagePollerReadsNoSourcesForHiddenProviders() async {
    let appState = await AppState()
    await appState.setProvider(.openCodeGo, visible: false)
    let hidden = ChainReportingUsageProvider(
        report: ProviderFetchReport(
            state: .fresh(stateUsage(fiveHour: 88, weekly: 74), asOf: Date(timeIntervalSince1970: 8_900)),
            chain: [ProviderDataSourceStep(.openCodeGoChromeCookie, .used)]
        )
    )
    let visible = ChainReportingUsageProvider(
        report: ProviderFetchReport(
            state: .fresh(stateUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 8_900)),
            chain: [ProviderDataSourceStep(.codexAPI, .used)]
        )
    )
    let poller = UsagePoller(
        providers: [.openCodeGo: hidden, .codex: visible],
        appState: appState
    )

    await poller.start()
    await visible.waitForFetchCount(1)
    await poller.waitUntilIdle()
    await poller.stop()

    #expect(await hidden.currentFetchCount == 0)
    #expect(await appState.chain(provider: .openCodeGo) == nil)
}

private actor ChainReportingUsageProvider: UsageProvider {
    private let report: ProviderFetchReport
    private var fetchCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(report: ProviderFetchReport) {
        self.report = report
    }

    var currentFetchCount: Int { fetchCount }

    func fetch(previous _: ProviderUsage?, mode _: CredentialAccessMode) async -> ProviderState {
        report.state
    }

    func fetchReport(
        previous _: ProviderUsage?,
        mode _: CredentialAccessMode
    ) async -> ProviderFetchReport {
        fetchCount += 1
        resumeWaiters()
        return report
    }

    func waitForFetchCount(_ target: Int) async {
        if fetchCount >= target {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { fetchCount >= $0.0 }
        waiters.removeAll { fetchCount >= $0.0 }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }
}
