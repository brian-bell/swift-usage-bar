import Foundation
import Testing
import UsageCore

@Test
func menuBarTitleFormatterUsesStableProviderOrderForFreshUsage() {
    let title = MenuBarTitleFormatter.format([
        .codex: .fresh(codexUsage, asOf: Date(timeIntervalSince1970: 20)),
        .claude: .fresh(claudeUsage, asOf: Date(timeIntervalSince1970: 10)),
    ])

    #expect(plainText(title) == "* 62/81  # 90")
}

@Test
func menuBarTitleFormatterShowsCodexWeeklyOnly() {
    let segments = MenuBarTitleFormatter.segments([
        .claude: .hidden,
        .codex: .fresh(codexUsage, asOf: Date(timeIntervalSince1970: 20)),
    ])

    #expect(segments == [
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
    ])
}

@Test
func menuBarTitleFormatterShowsUnavailableClaudeWindowAsPlaceholder() {
    let usage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 76, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: nil, resetsAt: nil)
    )

    let segments = MenuBarTitleFormatter.segments([
        .claude: .fresh(usage, asOf: Date(timeIntervalSince1970: 10)),
        .codex: .hidden,
    ])

    #expect(segments == [
        MenuBarTitleSegment(provider: .claude, value: "76/--", isStale: false),
    ])
}

@Test
func menuBarTitleFormatterShowsUnavailableCodexWeeklyAsPlaceholder() {
    let usage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: nil, resetsAt: nil)
    )

    let segments = MenuBarTitleFormatter.segments([
        .claude: .hidden,
        .codex: .fresh(usage, asOf: Date(timeIntervalSince1970: 20)),
    ])

    #expect(segments == [
        MenuBarTitleSegment(provider: .codex, value: "--", isStale: false),
    ])
}

@Test
func menuBarTitleFormatterExposesProviderSegmentsForIconRendering() {
    let segments = MenuBarTitleFormatter.segments([
        .codex: .fresh(codexUsage, asOf: Date(timeIntervalSince1970: 20)),
        .claude: .stale(last: claudeUsage, reason: .networkError),
    ])

    #expect(segments == [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: true),
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
    ])
}

@Test
func menuBarTitleFormatterOmitsHiddenProviders() {
    let title = MenuBarTitleFormatter.format([
        .claude: .hidden,
        .codex: .fresh(codexUsage, asOf: Date(timeIntervalSince1970: 20)),
    ])

    #expect(plainText(title) == "# 90")
}

@Test
func menuBarTitleFormatterMarksStaleProviderWithLastUsage() {
    let title = MenuBarTitleFormatter.format([
        .claude: .stale(last: claudeUsage, reason: .parseFailure),
        .codex: .hidden,
    ])

    #expect(plainText(title) == "* ~62/81")
}

@Test
func menuBarTitleFormatterShowsPlaceholderForStaleProviderWithoutLastUsage() {
    let title = MenuBarTitleFormatter.format([
        .claude: .stale(last: nil, reason: .parseFailure),
        .codex: .hidden,
    ])

    #expect(plainText(title) == "* --/--")
}

@Test
func menuBarTitleFormatterShowsCodexPlaceholderForStaleProviderWithoutLastUsage() {
    let title = MenuBarTitleFormatter.format([
        .claude: .hidden,
        .codex: .stale(last: nil, reason: .parseFailure),
    ])

    #expect(plainText(title) == "# --")
}

@Test
func menuBarTitleFormatterReturnsEmptyStringWhenAllProvidersAreHidden() {
    let title = MenuBarTitleFormatter.format([
        .claude: .hidden,
        .codex: .hidden,
    ])

    #expect(plainText(title).isEmpty)
}

@Test
func menuBarTitleFormatterShowsPlaceholdersWhenProvidersHaveNoDataYet() {
    let title = MenuBarTitleFormatter.format([:])

    #expect(plainText(title) == "* --/--  # --")
}

@Test
func menuBarTitleFormatterRendersFreshMiniMaxAsTwoWindowDisplay() {
    // MiniMax is two-window like Claude. A fresh state surfaces the segment
    // value through `remainingDisplay(for:)` with both `fiveHour` and
    // `weekly` windows joined by `/` — pin that shape, since omitting
    // `.miniMax` from `remainingDisplay(for:)` would silently fall back to
    // `"--/--"`.
    let segments = MenuBarTitleFormatter.segments([
        .claude: .hidden,
        .codex: .hidden,
        .miniMax: .fresh(miniMaxUsage, asOf: Date(timeIntervalSince1970: 30)),
    ])

    #expect(segments == [
        MenuBarTitleSegment(provider: .miniMax, value: "76/55", isStale: false),
    ])
}

@Test
func menuBarTitleFormatterRendersFreshMiniMaxAsMxSymbol() {
    // The `format` path joins `symbol` and the segment value, so this pins
    // the full menu-bar rendering for MiniMax end to end: the `Mx` symbol
    // (from `ProviderID.symbol`), the two-window value, and the absence of
    // a stale `~` prefix on fresh data.
    let title = MenuBarTitleFormatter.format([
        .claude: .hidden,
        .codex: .hidden,
        .miniMax: .fresh(miniMaxUsage, asOf: Date(timeIntervalSince1970: 30)),
    ])

    #expect(plainText(title) == "Mx 76/55")
}

@Test
func menuBarTitleFormatterEmitsFourSegmentsInProviderOrderWhenAllVisible() {
    // The first time all four providers can be visible simultaneously the
    // formatter must produce four segments in `ProviderID.allCases` order
    // (Claude, Codex, OpenCode Go, MiniMax) with each provider's own
    // display shape (two-window / weekly-only / three-window / two-window).
    // The image-partition algorithm is tested separately in
    // `MenuBarLabelImageTests`; this pins the formatter that feeds it.
    let openCodeGoUsage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 88, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 74, resetsAt: nil),
        monthly: UsageWindow(percentRemaining: 92, resetsAt: nil)
    )

    let segments = MenuBarTitleFormatter.segments([
        .claude: .fresh(claudeUsage, asOf: Date(timeIntervalSince1970: 10)),
        .codex: .fresh(codexUsage, asOf: Date(timeIntervalSince1970: 20)),
        .openCodeGo: .fresh(openCodeGoUsage, asOf: Date(timeIntervalSince1970: 30)),
        .miniMax: .fresh(miniMaxUsage, asOf: Date(timeIntervalSince1970: 40)),
    ])

    #expect(segments == [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: false),
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
        MenuBarTitleSegment(provider: .openCodeGo, value: "88/74/92", isStale: false),
        MenuBarTitleSegment(provider: .miniMax, value: "76/55", isStale: false),
    ])
}

private let claudeUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 62, resetsAt: nil),
    weekly: UsageWindow(percentRemaining: 81, resetsAt: nil)
)

private let codexUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
    weekly: UsageWindow(percentRemaining: 90, resetsAt: nil)
)

private let miniMaxUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 76, resetsAt: nil),
    weekly: UsageWindow(percentRemaining: 55, resetsAt: nil)
)

@Test
func menuBarTitleFormatterIsIdenticalWithOrWithoutCredits() {
    // The menu-bar title is the percent-remaining scale only; adding or
    // removing a credits value must not change the rendered string.
    // (See docs/PLAN-opencode-credits.md slice 1.)
    let reset = Date(timeIntervalSince1970: 100)
    let withCredits = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 88, resetsAt: reset),
        weekly: UsageWindow(percentRemaining: 74, resetsAt: reset),
        monthly: UsageWindow(percentRemaining: 92, resetsAt: reset),
        credits: CreditBalance(
            balanceUSD: 42.50,
            monthlyUsedUSD: 2.96,
            monthlyLimitUSD: 50
        )
    )
    let withoutCredits = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 88, resetsAt: reset),
        weekly: UsageWindow(percentRemaining: 74, resetsAt: reset),
        monthly: UsageWindow(percentRemaining: 92, resetsAt: reset)
    )

    let titleWith = MenuBarTitleFormatter.format([
        .openCodeGo: .fresh(withCredits, asOf: Date(timeIntervalSince1970: 1)),
    ])
    let titleWithout = MenuBarTitleFormatter.format([
        .openCodeGo: .fresh(withoutCredits, asOf: Date(timeIntervalSince1970: 1)),
    ])

    #expect(plainText(titleWith) == plainText(titleWithout))
}

private func plainText(_ attributedString: AttributedString) -> String {
    String(attributedString.characters)
}
