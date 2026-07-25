import Foundation
import Testing
import UsageCore

// 2026-01-01 12:00 UTC
private let statusNow = Date(timeIntervalSince1970: 1_767_268_800)

private let statusUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 88, resetsAt: statusNow.addingTimeInterval(3_600)),
    weekly: UsageWindow(percentRemaining: 74, resetsAt: statusNow.addingTimeInterval(86_400))
)

// MARK: - Source display names

@Test
func providerDataSourceExposesStatusLineDisplayNames() {
    #expect(ProviderDataSource.claudeWebSession.displayName == "claude.ai web session")
    #expect(ProviderDataSource.claudeOAuthAPI.displayName == "OAuth usage API")
    #expect(ProviderDataSource.claudeStatuslineCache.displayName == "Statusline cache")
    #expect(ProviderDataSource.codexAPI.displayName == "ChatGPT API (Keychain token)")
    #expect(ProviderDataSource.openCodeGoChromeCookie.displayName == "Chrome cookie")
}

@Test
func providerDataSourceExposesChainStepNamesForTheChainUI() {
    // Consumed by the per-step chain UI (slice #32); only `displayName` is
    // rendered by the one-line status in this slice.
    #expect(ProviderDataSource.claudeWebSession.chainStepName == "claude.ai web session")
    #expect(ProviderDataSource.claudeOAuthAPI.chainStepName == "OAuth usage API")
    #expect(ProviderDataSource.claudeStatuslineCache.chainStepName == "Statusline cache")
    #expect(ProviderDataSource.codexAPI.chainStepName == "ChatGPT API \u{00B7} Keychain token")
    #expect(ProviderDataSource.openCodeGoChromeCookie.chainStepName == "Chrome cookie \u{00B7} opencode.ai")
}

@Test
func providerDataSourceKnowsItsOwningProvider() {
    #expect(ProviderDataSource.claudeWebSession.provider == .claude)
    #expect(ProviderDataSource.claudeOAuthAPI.provider == .claude)
    #expect(ProviderDataSource.claudeStatuslineCache.provider == .claude)
    #expect(ProviderDataSource.codexAPI.provider == .codex)
    #expect(ProviderDataSource.openCodeGoChromeCookie.provider == .openCodeGo)
}

// MARK: - Status line rendering

@Test
func providerStatusRendersLiveClaudeWebSessionLine() throws {
    let model = ProviderStatusViewModel(
        states: [.claude: .fresh(statusUsage, asOf: statusNow)],
        dataSources: [.claude: .claudeWebSession],
        lastUpdatedAt: [.claude: statusNow.addingTimeInterval(-120)],
        now: statusNow
    )

    let row = try #require(model.rows.first { $0.provider == .claude })
    #expect(row.indicator == .live)
    #expect(row.stateLabel == "Live")
    #expect(row.methodLabel == "claude.ai web session")
    #expect(row.ageLabel == "updated 2 min ago")
    #expect(row.text == "Live \u{00B7} claude.ai web session \u{00B7} updated 2 min ago")
}

@Test
func providerStatusRendersLiveCodexLine() throws {
    let model = ProviderStatusViewModel(
        states: [.codex: .fresh(statusUsage, asOf: statusNow)],
        dataSources: [.codex: .codexAPI],
        lastUpdatedAt: [.codex: statusNow.addingTimeInterval(-120)],
        now: statusNow
    )

    let row = try #require(model.rows.first { $0.provider == .codex })
    #expect(row.text == "Live \u{00B7} ChatGPT API (Keychain token) \u{00B7} updated 2 min ago")
}

@Test
func providerStatusRendersStaleOpenCodeSessionExpiryWithAmberDot() throws {
    let model = ProviderStatusViewModel(
        states: [.openCodeGo: .stale(last: statusUsage, reason: .sessionExpired)],
        dataSources: [.openCodeGo: .openCodeGoChromeCookie],
        lastUpdatedAt: [.openCodeGo: statusNow.addingTimeInterval(-3_600)],
        now: statusNow
    )

    let row = try #require(model.rows.first { $0.provider == .openCodeGo })
    #expect(row.indicator == .stale)
    #expect(row.stateLabel == "Stale")
    #expect(row.methodLabel == "Chrome session expired")
    #expect(row.ageLabel == "last data 1 h ago")
    #expect(row.text == "Stale \u{00B7} Chrome session expired \u{00B7} last data 1 h ago")
}

@Test
func providerStatusRendersOffForHiddenProvider() throws {
    let model = ProviderStatusViewModel(
        states: [.openCodeGo: .hidden],
        dataSources: [.openCodeGo: .openCodeGoChromeCookie],
        lastUpdatedAt: [.openCodeGo: statusNow.addingTimeInterval(-3_600)],
        now: statusNow
    )

    let row = try #require(model.rows.first { $0.provider == .openCodeGo })
    #expect(row.indicator == .off)
    #expect(row.stateLabel == "Off")
    #expect(row.methodLabel == nil)
    #expect(row.ageLabel == nil)
    #expect(row.text == "Off")
}

@Test
func providerStatusCoversEveryProviderInStableOrder() {
    let model = ProviderStatusViewModel(states: [:], dataSources: [:], lastUpdatedAt: [:], now: statusNow)

    #expect(model.rows.map(\.provider) == ProviderID.allCases)
    #expect(model.rows.map(\.providerName) == ["Claude", "Codex", "OpenCode Go"])
    #expect(model.rows.map(\.id) == ProviderID.allCases)
}

@Test
func providerStatusReportsNoDataBeforeTheFirstRefresh() throws {
    let model = ProviderStatusViewModel(states: [:], dataSources: [:], lastUpdatedAt: [:], now: statusNow)

    let row = try #require(model.rows.first { $0.provider == .claude })
    // A provider the poller hasn't reported on yet has not *failed*: at launch the
    // first poll is simply still in flight, so it must not raise an amber alarm.
    #expect(row.indicator == .checking)
    #expect(row.text == "Checking\u{2026}")
    #expect(row.methodLabel == nil)
    #expect(row.ageLabel == nil)
}

@Test
func providerStatusOmitsMethodWhenNoSourceHasBeenReported() throws {
    let model = ProviderStatusViewModel(
        states: [.claude: .fresh(statusUsage, asOf: statusNow)],
        dataSources: [:],
        lastUpdatedAt: [.claude: statusNow.addingTimeInterval(-120)],
        now: statusNow
    )

    let row = try #require(model.rows.first { $0.provider == .claude })
    #expect(row.methodLabel == nil)
    #expect(row.text == "Live \u{00B7} updated 2 min ago")
}

@Test
func providerStatusOmitsAgeWhenNoSuccessfulRefreshIsRecorded() throws {
    let model = ProviderStatusViewModel(
        states: [.claude: .stale(last: nil, reason: .credentialUnavailable)],
        dataSources: [:],
        lastUpdatedAt: [:],
        now: statusNow
    )

    let row = try #require(model.rows.first { $0.provider == .claude })
    #expect(row.ageLabel == nil)
    #expect(row.text == "Stale \u{00B7} No Claude Code credential found")
}

@Test(arguments: [
    (0.0, "updated just now"),
    (59.0, "updated just now"),
    (60.0, "updated 1 min ago"),
    (3_540.0, "updated 59 min ago"),
    (3_600.0, "updated 1 h ago"),
    (82_800.0, "updated 23 h ago"),
    (86_400.0, "updated 1 d ago"),
    (259_200.0, "updated 3 d ago"),
])
func providerStatusFormatsAgeAcrossMinuteHourAndDayBoundaries(
    elapsed: TimeInterval,
    expected: String
) throws {
    let model = ProviderStatusViewModel(
        states: [.claude: .fresh(statusUsage, asOf: statusNow)],
        dataSources: [.claude: .claudeOAuthAPI],
        lastUpdatedAt: [.claude: statusNow.addingTimeInterval(-elapsed)],
        now: statusNow
    )

    let row = try #require(model.rows.first { $0.provider == .claude })
    #expect(row.ageLabel == expected)
}

@Test
func providerStatusClampsFutureRefreshTimestampsToJustNow() throws {
    let model = ProviderStatusViewModel(
        states: [.claude: .fresh(statusUsage, asOf: statusNow)],
        dataSources: [.claude: .claudeOAuthAPI],
        lastUpdatedAt: [.claude: statusNow.addingTimeInterval(30)],
        now: statusNow
    )

    let row = try #require(model.rows.first { $0.provider == .claude })
    #expect(row.ageLabel == "updated just now")
}

// MARK: - Stale reason phrasing

@Test(arguments: [
    (ProviderID.claude, StaleReason.parseFailure, "Unexpected response format"),
    (.claude, .networkError, "Network error"),
    (.claude, .tokenExpired, "OAuth token expired"),
    (.claude, .credentialUnavailable, "No Claude Code credential found"),
    (.claude, .sessionExpired, "claude.ai session expired"),
    (.claude, .workspaceSelectionRequired, "Workspace selection required"),
    (.codex, .parseFailure, "Unexpected response format"),
    (.codex, .networkError, "Network error"),
    (.codex, .tokenExpired, "Keychain token expired"),
    (.codex, .credentialUnavailable, "No Codex credential found"),
    (.codex, .sessionExpired, "Session expired"),
    (.codex, .workspaceSelectionRequired, "Workspace selection required"),
    (.openCodeGo, .parseFailure, "Unexpected response format"),
    (.openCodeGo, .networkError, "Network error"),
    (.openCodeGo, .tokenExpired, "Session token expired"),
    (.openCodeGo, .credentialUnavailable, "No opencode.ai cookie in Chrome"),
    (.openCodeGo, .sessionExpired, "Chrome session expired"),
    (.openCodeGo, .workspaceSelectionRequired, "Choose a workspace in Settings"),
])
func providerStatusMapsEveryStaleReasonToProviderSpecificPhrasing(
    provider: ProviderID,
    reason: StaleReason,
    expected: String
) throws {
    let model = ProviderStatusViewModel(
        states: [provider: .stale(last: statusUsage, reason: reason)],
        dataSources: [:],
        lastUpdatedAt: [:],
        now: statusNow
    )

    let row = try #require(model.rows.first { $0.provider == provider })
    #expect(row.methodLabel == expected)
}

@Test
func providerStatusPrefersFailureSummaryOverLastWinningSourceWhenStale() throws {
    // A provider that previously succeeded via a known source must still report
    // the failure in the method slot once it goes stale.
    let model = ProviderStatusViewModel(
        states: [.claude: .stale(last: statusUsage, reason: .tokenExpired)],
        dataSources: [.claude: .claudeOAuthAPI],
        lastUpdatedAt: [.claude: statusNow.addingTimeInterval(-600)],
        now: statusNow
    )

    let row = try #require(model.rows.first { $0.provider == .claude })
    #expect(row.text == "Stale \u{00B7} OAuth token expired \u{00B7} last data 10 min ago")
}
