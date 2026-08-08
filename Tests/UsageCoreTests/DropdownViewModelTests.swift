import Foundation
import Testing
import UsageCore

@Test
func dropdownRowsUseStableProviderOrderAndOmitHiddenProviders() throws {
    let model = DropdownViewModel(
        states: [
            .codex: .fresh(codexUsage, asOf: referenceNow),
            .claude: .hidden,
            .miniMax: .hidden,
        ],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(model.rows.map(\.provider) == [.codex])
    #expect(model.rows.map(\.providerName) == ["Codex"])
}

@Test
func dropdownRowsShowTwoWindowsForFreshMiniMax() throws {
    // Pin MiniMax's dropdown rendering shape: it identifies as "MiniMax",
    // exposes a 5h row (like Claude, unlike Codex's weekly-only), and does
    // not show a Monthly row (the row init special-cases `provider ==
    // .openCodeGo` for that). A regression in any of these branches would
    // silently drop or duplicate content.
    let model = DropdownViewModel(
        states: [.miniMax: .fresh(miniMaxUsage, asOf: referenceNow)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == .miniMax })
    #expect(row.providerName == "MiniMax")
    #expect(row.fiveHour != nil)
    #expect(row.monthly == nil)
}

@Test
func dropdownRowsExposeMiniMaxFiveHourAndWeeklyCountdowns() throws {
    // US2 end-to-end at the view-model layer: a fresh MiniMax surfaces
    // percent labels + countdowns for both windows through the same code
    // path Claude uses, with the `5h`/`Weekly` titles and weekday-form
    // countdowns the dropdown renders. No guidance/stale rows because the
    // state is fresh.
    let usage = ProviderUsage(
        fiveHour: UsageWindow(
            percentRemaining: 76,
            resetsAt: referenceNow.addingTimeInterval(90 * 60)
        ),
        weekly: UsageWindow(
            percentRemaining: 55,
            resetsAt: referenceNow.addingTimeInterval(3 * 24 * 60 * 60)
        )
    )

    let model = DropdownViewModel(
        states: [.miniMax: .fresh(usage, asOf: referenceNow)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == .miniMax })
    let fiveHour = try #require(row.fiveHour)
    #expect(fiveHour.title == "5h")
    #expect(fiveHour.percentLabel == "76% remaining")
    #expect(fiveHour.countdownLabel == "resets in 1h 30m")
    #expect(row.weekly?.title == "Weekly")
    #expect(row.weekly?.percentLabel == "55% remaining")
    // referenceNow is 2026-01-01 (Thursday); +3 days is Sunday.
    #expect(row.weekly?.countdownLabel == "resets Sun 12:00 PM")
    #expect(row.staleMessage == nil)
    #expect(row.updatedLabel == nil)
}

@Test
func dropdownRowsExposeClampedFractionsLabelsAndCountdowns() throws {
    let usage = ProviderUsage(
        fiveHour: UsageWindow(
            percentRemaining: 120,
            resetsAt: referenceNow.addingTimeInterval(90 * 60)
        ),
        weekly: UsageWindow(
            percentRemaining: -20,
            resetsAt: referenceNow.addingTimeInterval(3 * 24 * 60 * 60)
        )
    )

    let model = DropdownViewModel(
        states: [.claude: .fresh(usage, asOf: referenceNow)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first)
    let fiveHour = try #require(row.fiveHour)
    #expect(fiveHour.percentLabel == "120% remaining")
    #expect(fiveHour.barFraction == 1)
    #expect(fiveHour.countdownLabel == "resets in 1h 30m")
    #expect(row.weekly?.percentLabel == "-20% remaining")
    #expect(row.weekly?.barFraction == 0)
    // referenceNow (2026-01-01 12:00 UTC) is a Thursday; +3 days is Sunday.
    #expect(row.weekly?.countdownLabel == "resets Sun 12:00 PM")
}

@Test
func dropdownRowsOmitUnavailableFiveHourWindow() throws {
    let usage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 90, resetsAt: referenceNow.addingTimeInterval(6 * 24 * 60 * 60))
    )
    let model = DropdownViewModel(
        states: [.codex: .fresh(usage, asOf: referenceNow)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == .codex })
    #expect(!row.isStale)
    #expect(row.fiveHour == nil)
    #expect(row.weekly?.percentLabel == "90% remaining")
    // referenceNow (2026-01-01 12:00 UTC) is a Thursday; +6 days is Wednesday.
    #expect(row.weekly?.countdownLabel == "resets Wed 12:00 PM")
}

@Test
func dropdownRowsShowUnavailableClaudeWeeklyWithoutMarkingProviderStale() throws {
    let usage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 76, resetsAt: referenceNow.addingTimeInterval(60 * 60)),
        weekly: UsageWindow(percentRemaining: nil, resetsAt: nil)
    )
    let model = DropdownViewModel(
        states: [.claude: .fresh(usage, asOf: referenceNow)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == .claude })
    #expect(!row.isStale)
    let fiveHour = try #require(row.fiveHour)
    #expect(fiveHour.percentLabel == "76% remaining")
    #expect(row.weekly?.percentLabel == "--")
    #expect(row.weekly?.barFraction == 0)
    #expect(row.weekly?.countdownLabel == "reset unknown")
}

@Test
func dropdownRowsExposeFableWindowOnlyWhenPresent() throws {
    let withFable = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 62, resetsAt: referenceNow.addingTimeInterval(2 * 60 * 60)),
        weekly: UsageWindow(percentRemaining: 81, resetsAt: referenceNow.addingTimeInterval(5 * 24 * 60 * 60)),
        fable: UsageWindow(percentRemaining: 56, resetsAt: referenceNow.addingTimeInterval(90 * 60))
    )

    let model = DropdownViewModel(
        states: [
            .claude: .fresh(withFable, asOf: referenceNow),
            .codex: .fresh(codexUsage, asOf: referenceNow),
        ],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let claudeRow = try #require(model.rows.first { $0.provider == .claude })
    let fable = try #require(claudeRow.fable)
    #expect(fable.title == "Fable")
    #expect(fable.percentLabel == "56% remaining")
    #expect(fable.countdownLabel == "resets in 1h 30m")

    let codexRow = try #require(model.rows.first { $0.provider == .codex })
    #expect(codexRow.fable == nil)
}

@Test
func dropdownRowsExposeOpenCodeGoMonthlyWindow() throws {
    let usage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 88, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 74, resetsAt: nil),
        monthly: UsageWindow(percentRemaining: 92, resetsAt: nil)
    )
    let model = DropdownViewModel(
        states: [.openCodeGo: .fresh(usage, asOf: referenceNow)],
        now: referenceNow
    )

    let row = try #require(model.rows.first { $0.provider == .openCodeGo })
    #expect(row.providerName == "OpenCode Go")
    #expect(row.monthly?.title == "Monthly")
    #expect(row.monthly?.percentLabel == "92% remaining")
    #expect(row.fable == nil)
}

@Test
func dropdownRowsFlagStaleProvidersWhilePreservingLastKnownValues() throws {
    let model = DropdownViewModel(
        states: [.claude: .stale(last: claudeUsage, reason: .networkError)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first)
    #expect(row.isStale)
    #expect(row.staleMessage == "Stale: network error")
    let fiveHour = try #require(row.fiveHour)
    #expect(fiveHour.percentLabel == "62% remaining")
    #expect(row.weekly?.percentLabel == "81% remaining")
}

@Test
func dropdownRowsUsePlaceholdersForStaleProvidersWithoutData() throws {
    let model = DropdownViewModel(
        states: [.claude: .stale(last: nil, reason: .tokenExpired)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == .claude })
    #expect(row.isStale)
    #expect(row.staleMessage == "Stale: token expired")
    let fiveHour = try #require(row.fiveHour)
    #expect(fiveHour.percentLabel == "--")
    #expect(fiveHour.barFraction == 0)
    #expect(fiveHour.countdownLabel == "reset unknown")
    #expect(row.weekly?.percentLabel == "--")
}

@Test
func dropdownRowsOmitFiveHourPlaceholderForStaleCodexWithoutData() throws {
    let model = DropdownViewModel(
        states: [.codex: .stale(last: nil, reason: .tokenExpired)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == .codex })
    #expect(row.isStale)
    #expect(row.staleMessage == "Stale: token expired")
    #expect(row.fiveHour == nil)
    #expect(row.weekly?.percentLabel == "--")
}

@Test(arguments: [
    (ProviderID.claude, StaleReason.parseFailure, "Stale: parse failure"),
    (.claude, .networkError, "Stale: network error"),
    (.claude, .tokenExpired, "Stale: token expired"),
    (.claude, .credentialUnavailable, "Stale: credential unavailable"),
    (.claude, .sessionExpired, "Stale: claude.ai session expired; sign in again in Chrome"),
    (.claude, .workspaceSelectionRequired, "Stale: workspace selection required"),
    (.codex, .tokenExpired, "Stale: token expired"),
    (.codex, .sessionExpired, "Stale: Codex session expired; sign in again in the Codex app"),
    (.codex, .workspaceSelectionRequired, "Stale: workspace selection required"),
    (.openCodeGo, .tokenExpired, "Stale: token expired"),
    (.openCodeGo, .sessionExpired, "Stale: OpenCode session expired; sign in again in Chrome"),
    (.openCodeGo, .workspaceSelectionRequired, "Stale: select an OpenCode Go workspace in Settings"),
    (.miniMax, .tokenExpired, "Stale: MiniMax key rejected; re-authenticate in OpenCode"),
    (.miniMax, .sessionExpired, "Stale: MiniMax key rejected; re-authenticate in OpenCode"),
    (.miniMax, .workspaceSelectionRequired, "Stale: workspace selection required"),
])
func dropdownStaleMessageNamesTheFailingProvider(
    provider: ProviderID,
    reason: StaleReason,
    expectedMessage: String
) throws {
    let model = DropdownViewModel(
        states: [provider: .stale(last: nil, reason: reason)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == provider })
    #expect(row.staleMessage == expectedMessage)
}

@Test
func dropdownSummaryUsesMostRecentVisibleProviderUpdate() {
    let model = DropdownViewModel(
        states: [
            .claude: .fresh(claudeUsage, asOf: referenceNow),
            .codex: .fresh(codexUsage, asOf: referenceNow),
        ],
        lastUpdatedAt: [
            .claude: referenceNow.addingTimeInterval(-10 * 60),
            .codex: referenceNow.addingTimeInterval(-2 * 60),
        ],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(model.updatedLabel == "Updated 2m ago")
}

@Test
func dropdownSummaryIgnoresHiddenProviderUpdates() {
    let model = DropdownViewModel(
        states: [
            .claude: .hidden,
            .codex: .fresh(codexUsage, asOf: referenceNow),
        ],
        lastUpdatedAt: [
            .claude: referenceNow,
            .codex: referenceNow.addingTimeInterval(-3 * 60),
        ],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(model.updatedLabel == "Updated 3m ago")
}

@Test
func dropdownSummaryIsNilWhenAllProvidersAreHidden() {
    let model = DropdownViewModel(
        states: [
            .claude: .hidden,
            .codex: .hidden,
            .miniMax: .hidden,
        ],
        lastUpdatedAt: [
            .claude: referenceNow,
            .codex: referenceNow,
        ],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(model.rows.isEmpty)
    #expect(model.updatedLabel == nil)
}

@Test
func dropdownSummaryIsNilWhenVisibleProvidersHaveNoUpdateTimestamp() {
    let model = DropdownViewModel(
        states: [.claude: .fresh(claudeUsage, asOf: referenceNow)],
        lastUpdatedAt: [:],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(model.rows.map(\.provider) == [.claude, .codex])
    #expect(model.updatedLabel == nil)
}

@Test
func dropdownCreditsRowShowsMonthlyAllowanceRemainingWithBar() {
    // With both monthly fields present the row reads like the window rows:
    // remaining-of-allowance above a bar. Remaining is limit − used, and
    // the fraction is the same expression production uses so the compare
    // is exact without float literals.
    let row = DropdownCreditsRow(
        credits: CreditBalance(
            balanceUSD: 42.50,
            monthlyUsedUSD: 2.96,
            monthlyLimitUSD: 50
        ),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(row.title == "Credits")
    #expect(row.amountLabel == "$47.04 remaining")
    #expect(row.barFraction == (50.0 - 2.96) / 50.0)
    #expect(row.limitLabel == "$50 monthly limit")
}

@Test
func dropdownCreditsRowMatchesTheBillingFixture() throws {
    // Sanitized sentinels from opencode-go-usage-billing.html:
    // monthlyLimit:99, monthlyUsage:87654321 (10⁻⁸ dollars) →
    // 99 − 0.87654321 = 98.12345679 → "$98.12" under any rounding mode.
    let credits = try #require(
        try OpenCodeCreditsParser().parse(fixtureData("opencode-go-usage-billing.html"))
    )
    let row = DropdownCreditsRow(
        credits: credits,
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(row.amountLabel == "$98.12 remaining")
    #expect(row.barFraction == (99.0 - 87654321.0 / 100_000_000) / 99.0)
    #expect(row.limitLabel == "$99 monthly limit")
}

@Test
func dropdownCreditsRowFallsBackToBalanceWhenMonthlyFieldsAreNil() {
    // Without an allowance there is no fraction to chart: the row degrades
    // to the wallet balance alone — barFraction == nil suppresses the bar
    // (an empty bar would falsely read "0 remaining") and limitLabel ==
    // nil suppresses the right-side limit text. A zero balance still
    // renders as "$0.00": zero-but-billing-configured is a real state,
    // not the same as "no credits".
    let row = DropdownCreditsRow(
        credits: CreditBalance(
            balanceUSD: 0,
            monthlyUsedUSD: nil,
            monthlyLimitUSD: nil
        ),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(row.amountLabel == "$0.00")
    #expect(row.barFraction == nil)
    #expect(row.limitLabel == nil)
}

@Test
func dropdownCreditsRowFallsBackToBalanceWhenMonthlyUsedIsNil() {
    // "Remaining" is limit − used — without used, the limit alone cannot
    // produce it, and a lone right-side "$50 monthly limit" next to a
    // wallet balance would imply a comparison the row isn't making.
    let row = DropdownCreditsRow(
        credits: CreditBalance(
            balanceUSD: 12.30,
            monthlyUsedUSD: nil,
            monthlyLimitUSD: 50
        ),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(row.amountLabel == "$12.30")
    #expect(row.barFraction == nil)
    #expect(row.limitLabel == nil)
}

@Test
func dropdownCreditsRowFallsBackToBalanceWhenMonthlyLimitIsZero() {
    // A zero limit has no meaningful fraction (division aside, "remaining
    // of $0" is noise) — same balance-only degradation as a nil field.
    let row = DropdownCreditsRow(
        credits: CreditBalance(
            balanceUSD: 12.30,
            monthlyUsedUSD: 2.96,
            monthlyLimitUSD: 0
        ),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(row.amountLabel == "$12.30")
    #expect(row.barFraction == nil)
    #expect(row.limitLabel == nil)
}

@Test
func dropdownCreditsRowShowsFullAllowanceWhenNothingIsUsed() {
    // Zero used is a real state and must render as a full bar, not be
    // conflated with "no data". (The old zero-*balance* pin moved to the
    // both-fields-nil fallback test — the balance no longer renders on
    // the full-data path.)
    let row = DropdownCreditsRow(
        credits: CreditBalance(
            balanceUSD: 0,
            monthlyUsedUSD: 0,
            monthlyLimitUSD: 50
        ),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(row.amountLabel == "$50.00 remaining")
    #expect(row.barFraction == 1.0)
    #expect(row.limitLabel == "$50 monthly limit")
}

@Test
func dropdownCreditsRowKeepsLabelUnclampedWhenOverLimit() {
    // Same split the window rows pin: the label tells the truth about
    // overspend ("$-10.00 remaining") while the bar clamps to empty.
    let row = DropdownCreditsRow(
        credits: CreditBalance(
            balanceUSD: 5,
            monthlyUsedUSD: 60,
            monthlyLimitUSD: 50
        ),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(row.amountLabel == "$-10.00 remaining")
    #expect(row.barFraction == 0)
    #expect(row.limitLabel == "$50 monthly limit")
}

@Test
func dropdownCreditsRowRoundsBalanceToTwoDecimals() {
    // NumberFormatter with min=max=2 rounds halfUp. A future refactor that
    // swaps the formatter (e.g. for `String(format:)` or `formatted(_:)`)
    // could change the rounding rule — this test pins the spec on the
    // balance-fallback path.
    let row = DropdownCreditsRow(
        credits: CreditBalance(
            balanceUSD: 99.999,
            monthlyUsedUSD: nil,
            monthlyLimitUSD: nil
        ),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(row.amountLabel == "$100.00")
}

@Test
func dropdownCreditsRowUsesLocaleDecimalSeparator() {
    // Decimal style + "$" prefix keeps the dollar sign universal while
    // delegating the decimal separator to the locale. The original
    // currency-style formatter was rejected because it inserted a
    // non-breaking space; this pin locks in the locale path so a future
    // "simplification" can't silently regress it.
    let row = DropdownCreditsRow(
        credits: CreditBalance(
            balanceUSD: 42.50,
            monthlyUsedUSD: nil,
            monthlyLimitUSD: nil
        ),
        locale: Locale(identifier: "de_DE")
    )

    #expect(row.amountLabel == "$42,50")
}

@Test
func dropdownCreditsRowUsesLocaleDecimalSeparatorForRemaining() {
    // The remaining label goes through the same formatCurrency path as the
    // balance fallback — one locale pin per path.
    let row = DropdownCreditsRow(
        credits: CreditBalance(
            balanceUSD: 42.50,
            monthlyUsedUSD: 2.96,
            monthlyLimitUSD: 50
        ),
        locale: Locale(identifier: "de_DE")
    )

    #expect(row.amountLabel == "$47,04 remaining")
    // The limit side keeps raw Int interpolation (no locale separators) —
    // limits are small whole dollars, per the original caption decision.
    #expect(row.limitLabel == "$50 monthly limit")
}

private let creditsProviderUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
    weekly: UsageWindow(percentRemaining: nil, resetsAt: nil),
    credits: CreditBalance(
        balanceUSD: 42.50,
        monthlyUsedUSD: 2.96,
        monthlyLimitUSD: 50
    )
)

@Test
func dropdownCreditsProviderRowShowsOnlyTheCreditsRow() throws {
    // The credits provider still exposes no 5h/weekly/monthly rows. Its
    // bar charts monthly-allowance-remaining (limit − used, over limit) —
    // a dollar figure, not a rate-limit window — so credits keep their own
    // row type, own no WindowKey, and stay out of tone and threshold
    // notifications.
    let model = DropdownViewModel(
        states: [.openCodeCredits: .fresh(creditsProviderUsage, asOf: referenceNow)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == .openCodeCredits })
    #expect(row.providerName == "OpenCode Credits")
    #expect(row.fiveHour == nil)
    #expect(row.weekly == nil)
    #expect(row.monthly == nil)
    let credits = try #require(row.credits, "fresh credits usage should expose the credits row")
    #expect(credits.title == "Credits")
    #expect(credits.amountLabel == "$47.04 remaining")
    #expect(credits.barFraction == (50.0 - 2.96) / 50.0)
    #expect(credits.limitLabel == "$50 monthly limit")
}

@Test
func dropdownCreditsProviderRowPreservesCreditsWhenStaleWithLastUsage() throws {
    // Stale keeps the last-known credits inside the greyed row so the
    // user continues to see the dollar figure across a network blip —
    // matching the windows' "last-preserved" behavior.
    let model = DropdownViewModel(
        states: [.openCodeCredits: .stale(last: creditsProviderUsage, reason: .networkError)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == .openCodeCredits })
    #expect(row.isStale)
    let credits = try #require(row.credits, "stale(last: usage) preserves last-known credits")
    #expect(credits.amountLabel == "$47.04 remaining")
    #expect(credits.barFraction == (50.0 - 2.96) / 50.0)
}

@Test
func dropdownCreditsProviderRowShowsPlaceholderWhenStaleWithNothing() throws {
    let model = DropdownViewModel(
        states: [.openCodeCredits: .stale(last: nil, reason: .credentialUnavailable)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == .openCodeCredits })
    #expect(row.fiveHour == nil)
    #expect(row.weekly == nil)
    #expect(row.monthly == nil)
    let credits = try #require(row.credits, "the credits provider always shows its one row")
    #expect(credits.title == "Credits")
    #expect(credits.amountLabel == "--")
    #expect(credits.barFraction == 0, "placeholder renders an empty bar, matching the window rows")
    #expect(credits.limitLabel == nil, "no data means no limit to state on the right")
    #expect(row.staleMessage == "Stale: no credits balance found")
}

@Test
func dropdownProviderRowHasNilCreditsForOtherProviders() throws {
    // The row model must not fabricate a credits row for a usage that
    // carries none. (Parser-level ownership — Go never attaches credits —
    // is pinned in OpenCodeGoUsageParserTests, not here.)
    let goUsage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 88, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 74, resetsAt: nil),
        monthly: UsageWindow(percentRemaining: 92, resetsAt: nil)
    )
    let model = DropdownViewModel(
        states: [
            .claude: .fresh(claudeUsage, asOf: referenceNow),
            .codex: .fresh(codexUsage, asOf: referenceNow),
            .openCodeGo: .fresh(goUsage, asOf: referenceNow),
        ],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    for provider in [ProviderID.claude, .codex, .openCodeGo] {
        let row = try #require(model.rows.first { $0.provider == provider })
        #expect(row.credits == nil)
    }
}

@Test
func dropdownSkipsTheCreditsProviderUntilItHasReported() throws {
    // Default-hidden provider with no state yet: no row, no placeholder —
    // same contract as OpenCode Go and MiniMax.
    let model = DropdownViewModel(
        states: [.claude: .fresh(claudeUsage, asOf: referenceNow)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(!model.rows.contains { $0.provider == .openCodeCredits })
}

private let referenceNow = Date(timeIntervalSince1970: 1_767_268_800) // 2026-01-01 12:00 UTC

private let claudeUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 62, resetsAt: referenceNow.addingTimeInterval(2 * 60 * 60)),
    weekly: UsageWindow(percentRemaining: 81, resetsAt: referenceNow.addingTimeInterval(5 * 24 * 60 * 60))
)

private let codexUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
    weekly: UsageWindow(percentRemaining: 90, resetsAt: referenceNow.addingTimeInterval(6 * 24 * 60 * 60))
)

private let miniMaxUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 76, resetsAt: referenceNow.addingTimeInterval(2 * 60 * 60)),
    weekly: UsageWindow(percentRemaining: 55, resetsAt: referenceNow.addingTimeInterval(5 * 24 * 60 * 60))
)

private func fixtureData(_ name: String) throws -> Data {
    let testFile = URL(fileURLWithPath: #filePath)
    return try Data(contentsOf: testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name))
}

private func deterministicCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
