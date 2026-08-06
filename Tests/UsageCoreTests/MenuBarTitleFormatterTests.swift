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
func menuBarTitleFormatterRendersFreshMiniMaxAsTwoWindowMxLabel() {
    // MiniMax is two-window like Claude, default-hidden until polled, and
    // identifies itself with `Mx`. A fresh state surfaces all three at once:
    // the symbol, the abbreviation shape, and the absent-state rule that lets
    // it skip the placeholder row when hidden by its peers.
    let segments = MenuBarTitleFormatter.segments([
        .claude: .hidden,
        .codex: .hidden,
        .miniMax: .fresh(miniMaxUsage, asOf: Date(timeIntervalSince1970: 30)),
    ])

    #expect(segments == [
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

private func plainText(_ attributedString: AttributedString) -> String {
    String(attributedString.characters)
}
