import Foundation
import Testing
import UsageCore

// The expandable per-provider retrieval chain rendered in Settings › Providers:
// numbered steps in fallback order, a recovery callout for stale providers, and
// the OpenCode Go workspace field that now lives inside that disclosure.

// 2026-01-01 12:00 UTC
private let chainNow = Date(timeIntervalSince1970: 1_767_268_800)

private let chainUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 88, resetsAt: chainNow.addingTimeInterval(3_600)),
    weekly: UsageWindow(percentRemaining: 74, resetsAt: chainNow.addingTimeInterval(86_400))
)

private func chainSection(
    for provider: ProviderID,
    states: [ProviderID: ProviderState] = [:],
    chains: [ProviderID: [ProviderDataSourceStep]] = [:],
    lastUpdatedAt: [ProviderID: Date] = [:],
    workspaceID: String? = nil
) throws -> ProviderChainSection {
    let model = ProviderStatusViewModel(
        states: states,
        chains: chains,
        lastUpdatedAt: lastUpdatedAt,
        workspaceID: workspaceID,
        now: chainNow
    )
    return try #require(model.rows.first { $0.provider == provider }).chain
}

// MARK: - Claude's three-step chain

@Test
func claudeChainListsAllThreeStepsInFallbackOrderWithTheWinnerMarkedUsed() throws {
    let section = try chainSection(
        for: .claude,
        states: [.claude: .fresh(chainUsage, asOf: chainNow)],
        chains: [.claude: [ProviderDataSourceStep(.claudeWebSession, .used)]],
        lastUpdatedAt: [.claude: chainNow.addingTimeInterval(-120)]
    )

    #expect(section.steps.map(\.number) == [1, 2, 3])
    #expect(section.steps.map(\.name) == [
        "claude.ai web session",
        "OAuth usage API",
        "Statusline cache",
    ])
    #expect(section.steps.map(\.stateText) == [
        "Used 2 min ago",
        "Standing by",
        "Standing by",
    ])
    #expect(section.steps.map(\.style) == [.used, .standingBy, .standingBy])
}

@Test
func claudeChainMarksAFailedFirstStepAndTheApiWinnerWithTheCacheStandingBy() throws {
    let section = try chainSection(
        for: .claude,
        states: [.claude: .fresh(chainUsage, asOf: chainNow)],
        chains: [.claude: [
            ProviderDataSourceStep(.claudeWebSession, .failed(.sessionExpired)),
            ProviderDataSourceStep(.claudeOAuthAPI, .used),
        ]],
        lastUpdatedAt: [.claude: chainNow.addingTimeInterval(-120)]
    )

    #expect(section.steps.map(\.stateText) == [
        "Session expired \u{00B7} 2 min ago",
        "Used 2 min ago",
        "Standing by",
    ])
    #expect(section.steps.map(\.style) == [.failed, .used, .standingBy])
}

@Test
func claudeChainRendersEveryStepAsStandingByBeforeTheFirstReport() throws {
    let section = try chainSection(for: .claude)

    #expect(section.steps.count == 3)
    #expect(section.steps.allSatisfy { $0.style == .standingBy })
    #expect(section.steps.allSatisfy { $0.stateText == "Standing by" })
}

@Test
func claudeChainCarriesTheOrderedFallbackCaption() throws {
    let section = try chainSection(for: .claude)

    #expect(section.caption == """
        Sources are tried in order each refresh; data comes from the first that succeeds. \
        All access is read-only.
        """)
}

@Test
func chainStepWithoutAKnownAgeOmitsTheAgeSuffix() throws {
    let section = try chainSection(
        for: .claude,
        states: [.claude: .stale(last: nil, reason: .tokenExpired)],
        chains: [.claude: [ProviderDataSourceStep(.claudeOAuthAPI, .failed(.tokenExpired))]]
    )

    #expect(section.steps[1].stateText == "Token expired")
}

// MARK: - Codex two-step chain and single-step OpenCode

@Test
func codexChainRendersTwoStepsWithDesktopFallbackStandingBy() throws {
    let section = try chainSection(
        for: .codex,
        states: [.codex: .fresh(chainUsage, asOf: chainNow)],
        chains: [.codex: [ProviderDataSourceStep(.codexAPI, .used)]],
        lastUpdatedAt: [.codex: chainNow.addingTimeInterval(-120)]
    )

    #expect(section.steps.count == 2)
    #expect(section.steps[0].number == 1)
    #expect(section.steps[0].name == "ChatGPT API \u{00B7} Local Codex credential")
    #expect(section.steps[0].stateText == "Used 2 min ago")
    #expect(section.steps[1].number == 2)
    #expect(section.steps[1].name == "Codex app-server \u{00B7} Desktop sign-in")
    #expect(section.steps[1].stateText == "Standing by")
    #expect(section.caption == """
        The signed Codex desktop helper is tried only when the local Codex credential is unavailable. \
        Both paths read the weekly limit only.
        """)
}

@Test
func openCodeGoChainRendersOneStepWithNoChainCaptionOfItsOwn() throws {
    let section = try chainSection(
        for: .openCodeGo,
        states: [.openCodeGo: .stale(last: chainUsage, reason: .sessionExpired)],
        chains: [.openCodeGo: [ProviderDataSourceStep(.openCodeGoChromeCookie, .failed(.sessionExpired))]],
        lastUpdatedAt: [.openCodeGo: chainNow.addingTimeInterval(-3_600)]
    )

    #expect(section.steps.count == 1)
    #expect(section.steps[0].name == "Chrome cookie \u{00B7} opencode.ai")
    #expect(section.steps[0].stateText == "Session expired \u{00B7} 1 h ago")
    #expect(section.steps[0].style == .failed)
    // OpenCode Go's caption belongs to the workspace field, not to the chain.
    #expect(section.caption == nil)
}

// MARK: - Step styling

@Test
func chainStepStylingMapsToDotEmphasisAndMuting() throws {
    let section = try chainSection(
        for: .claude,
        states: [.claude: .fresh(chainUsage, asOf: chainNow)],
        chains: [.claude: [
            ProviderDataSourceStep(.claudeWebSession, .failed(.networkError)),
            ProviderDataSourceStep(.claudeOAuthAPI, .used),
        ]],
        lastUpdatedAt: [.claude: chainNow]
    )

    let failed = section.steps[0]
    #expect(failed.indicator == .stale)
    #expect(failed.isEmphasized)
    #expect(!failed.isMuted)

    let used = section.steps[1]
    #expect(used.indicator == .live)
    #expect(used.isEmphasized)
    #expect(!used.isMuted)

    let standingBy = section.steps[2]
    #expect(standingBy.indicator == nil)
    #expect(!standingBy.isEmphasized)
    #expect(standingBy.isMuted)
}

// MARK: - Failure phrasing per step

@Test(arguments: [
    (ProviderDataSource.claudeWebSession, StaleReason.sessionExpired, "Session expired"),
    (.claudeWebSession, .credentialUnavailable, "No Chrome cookie"),
    (.claudeWebSession, .networkError, "Network error"),
    (.claudeWebSession, .parseFailure, "Unexpected response"),
    (.claudeWebSession, .tokenExpired, "Token expired"),
    (.claudeWebSession, .workspaceSelectionRequired, "Choose a workspace"),
    (.claudeOAuthAPI, .credentialUnavailable, "No credential found"),
    (.claudeOAuthAPI, .networkError, "Network error"),
    (.claudeOAuthAPI, .tokenExpired, "Token expired"),
    (.claudeStatuslineCache, .credentialUnavailable, "No cache file"),
    // The cache is a local file — no failure of it may blame the network.
    (.claudeStatuslineCache, .networkError, "Cache out of date"),
    (.claudeStatuslineCache, .parseFailure, "Unexpected response"),
    (.codexAPI, .credentialUnavailable, "No credential found"),
    (.codexAppServer, .credentialUnavailable, "Desktop sign-in unavailable"),
    (.codexAppServer, .networkError, "Desktop helper unavailable"),
    (.openCodeGoChromeCookie, .credentialUnavailable, "Usage unavailable"),
    (.openCodeGoChromeCookie, .workspaceSelectionRequired, "Choose a workspace"),
])
func chainStepPhrasesEveryFailureReasonPerSource(
    source: ProviderDataSource,
    reason: StaleReason,
    expected: String
) {
    #expect(source.chainFailureSummary(for: reason) == expected)
}

// MARK: - Recovery callouts

@Test
func staleOpenCodeGoDisclosureShowsTheVerbatimRecoveryCallout() throws {
    let section = try chainSection(
        for: .openCodeGo,
        states: [.openCodeGo: .stale(last: chainUsage, reason: .sessionExpired)],
        chains: [.openCodeGo: [ProviderDataSourceStep(.openCodeGoChromeCookie, .failed(.sessionExpired))]],
        lastUpdatedAt: [.openCodeGo: chainNow.addingTimeInterval(-3_600)]
    )

    #expect(section.recoveryCallout == """
        Showing last-known data. Sign in to opencode.ai in Chrome, then choose Refresh Now \
        from the menu bar.
        """)
}

@Test
func freshProviderShowsNoRecoveryCallout() throws {
    let section = try chainSection(
        for: .claude,
        states: [.claude: .fresh(chainUsage, asOf: chainNow)],
        chains: [.claude: [ProviderDataSourceStep(.claudeWebSession, .used)]],
        lastUpdatedAt: [.claude: chainNow]
    )

    #expect(section.recoveryCallout == nil)
}

@Test(arguments: [
    (
        ProviderID.claude,
        StaleReason.tokenExpired,
        "Showing last-known data. Run Claude Code once to refresh its OAuth token, then choose "
            + "Refresh Now from the menu bar."
    ),
    (
        .claude,
        .credentialUnavailable,
        "Showing last-known data. Sign in to Claude Code, then choose Refresh Now from the menu bar."
    ),
    (
        .claude,
        .sessionExpired,
        "Showing last-known data. Sign in to claude.ai in Chrome, then choose Refresh Now from "
            + "the menu bar."
    ),
    (
        .claude,
        .networkError,
        "Showing last-known data. Check your network connection, then choose Refresh Now from "
            + "the menu bar."
    ),
    (
        .claude,
        .parseFailure,
        "Showing last-known data. The service returned an unexpected response; this usually "
            + "clears on its own."
    ),
    (
        .codex,
        .tokenExpired,
        "Showing last-known data. Open Codex and refresh its local sign-in, then choose "
            + "Refresh Now from the menu bar."
    ),
    (
        .codex,
        .credentialUnavailable,
        "Showing last-known data. Sign in to the Codex desktop app or Codex CLI, then choose Refresh Now from the "
            + "menu bar."
    ),
    (
        .openCodeGo,
        .credentialUnavailable,
        "Showing last-known data. Check your opencode.ai sign-in and workspace access in Chrome, "
            + "then choose Refresh Now from the menu bar."
    ),
    (
        .openCodeGo,
        .workspaceSelectionRequired,
        "Showing last-known data. Several workspaces matched. Set a workspace ID below, then "
            + "choose Refresh Now from the menu bar."
    ),
])
func recoveryCalloutCopyIsProviderAndReasonSpecific(
    provider: ProviderID,
    reason: StaleReason,
    expected: String
) throws {
    let section = try chainSection(
        for: provider,
        states: [provider: .stale(last: chainUsage, reason: reason)],
        lastUpdatedAt: [provider: chainNow.addingTimeInterval(-600)]
    )

    #expect(section.recoveryCallout == expected)
}

// MARK: - Workspace field placement

@Test
func openCodeGoDisclosureOwnsTheWorkspaceFieldAndItsCaption() throws {
    let section = try chainSection(
        for: .openCodeGo,
        states: [.openCodeGo: .fresh(chainUsage, asOf: chainNow)],
        chains: [.openCodeGo: [ProviderDataSourceStep(.openCodeGoChromeCookie, .used)]],
        lastUpdatedAt: [.openCodeGo: chainNow]
    )

    #expect(section.showsWorkspaceField)
    #expect(section.workspaceFieldLabel == "Workspace")
    #expect(section.workspaceFieldPlaceholder == "Optional wrk_\u{2026} ID or URL")
    #expect(section.workspaceFieldAccessibilityLabel == "OpenCode workspace")
    #expect(section.workspaceCaption
        == "Currently auto-discovered. Set an ID to skip discovery. Shared with OpenCode Credits.")
}

@Test
func workspaceCaptionSaysDiscoveryIsSkippedOnceAnIDIsSet() throws {
    let section = try chainSection(
        for: .openCodeGo,
        states: [.openCodeGo: .fresh(chainUsage, asOf: chainNow)],
        workspaceID: "wrk_abc123"
    )

    #expect(section.workspaceCaption
        == "Using the workspace ID you set; discovery is skipped. Shared with OpenCode Credits.")
}

@Test
func onlyTheOpenCodeProvidersShowTheWorkspaceField() throws {
    for provider in [ProviderID.claude, .codex, .miniMax] {
        let section = try chainSection(for: provider)
        #expect(!section.showsWorkspaceField)
        #expect(section.workspaceCaption == nil)
    }
}

@Test
func openCodeCreditsDisclosureSharesTheWorkspaceFieldAndSaysSo() throws {
    // The one workspace setting names the same opencode.ai workspace for
    // both OpenCode providers; the credits disclosure must offer it too, or
    // enabling only Credits would strand the field inside a hidden Go
    // disclosure.
    let section = try chainSection(
        for: .openCodeCredits,
        states: [.openCodeCredits: .fresh(chainUsage, asOf: chainNow)],
        chains: [.openCodeCredits: [ProviderDataSourceStep(.openCodeCreditsChromeCookie, .used)]],
        lastUpdatedAt: [.openCodeCredits: chainNow]
    )

    #expect(section.showsWorkspaceField)
    #expect(section.workspaceCaption
        == "Currently auto-discovered. Set an ID to skip discovery. Shared with OpenCode Go.")
    #expect(section.steps.map(\.name) == ["Chrome cookie \u{00B7} opencode.ai"])
}

@Test
func openCodeCreditsStaleDisclosureExplainsTheMissingBalance() throws {
    // `.credentialUnavailable` covers both "no cookie" and "billing not
    // configured"; the callout must name both candidate causes.
    let section = try chainSection(
        for: .openCodeCredits,
        states: [.openCodeCredits: .stale(last: nil, reason: .credentialUnavailable)],
        chains: [.openCodeCredits: [
            ProviderDataSourceStep(.openCodeCreditsChromeCookie, .failed(.credentialUnavailable)),
        ]]
    )

    // No "Showing last-known data." prefix: billing-not-configured is a
    // durable state that usually has no last-known data behind it.
    #expect(section.recoveryCallout == "No credits balance found. "
        + "Check your opencode.ai sign-in in Chrome and that billing is configured on the "
        + "workspace, then choose Refresh Now from the menu bar.")
    #expect(section.steps.first?.stateText == "No credits balance")
}

// MARK: - Hidden providers

@Test
func hiddenProviderHasNoDisclosureContentAtAll() throws {
    let section = try chainSection(
        for: .openCodeGo,
        states: [.openCodeGo: .hidden],
        chains: [.openCodeGo: [ProviderDataSourceStep(.openCodeGoChromeCookie, .used)]],
        lastUpdatedAt: [.openCodeGo: chainNow]
    )

    #expect(section.isOff)
    #expect(section.steps.isEmpty)
    #expect(section.caption == nil)
    #expect(section.recoveryCallout == nil)
    #expect(!section.showsWorkspaceField)
}

// MARK: - Disclosure expansion

@Test
func staleProvidersAutoExpandOnOpenWhileFreshOnesStayCollapsed() {
    let model = ProviderStatusViewModel(
        states: [
            .claude: .fresh(chainUsage, asOf: chainNow),
            .codex: .stale(last: chainUsage, reason: .tokenExpired),
            .openCodeGo: .stale(last: nil, reason: .credentialUnavailable),
        ],
        now: chainNow
    )

    #expect(model.expandedProviders(remembering: []) == [.codex, .openCodeGo])
}

@Test
func expansionRemembersProvidersTheUserOpenedByHand() {
    let model = ProviderStatusViewModel(
        states: [
            .claude: .fresh(chainUsage, asOf: chainNow),
            .codex: .stale(last: chainUsage, reason: .tokenExpired),
        ],
        now: chainNow
    )

    #expect(model.expandedProviders(remembering: [.claude]) == [.claude, .codex])
}

@Test
func hiddenAndCheckingProvidersNeverAutoExpand() {
    let model = ProviderStatusViewModel(
        states: [.openCodeGo: .hidden],
        now: chainNow
    )

    #expect(model.expandedProviders(remembering: []).isEmpty)
}
