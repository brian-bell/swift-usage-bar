import Foundation
import Testing
import UsageCore

@Test
func menuBarTitleFormatterUsesStableProviderOrderForFreshUsage() {
    let title = MenuBarTitleFormatter.format([
        .codex: .fresh(codexUsage, asOf: Date(timeIntervalSince1970: 20)),
        .claude: .fresh(claudeUsage, asOf: Date(timeIntervalSince1970: 10)),
    ])

    #expect(plainText(title) == "* 62/81  # 72/90")
}

@Test
func menuBarTitleFormatterOmitsHiddenProviders() {
    let title = MenuBarTitleFormatter.format([
        .claude: .hidden,
        .codex: .fresh(codexUsage, asOf: Date(timeIntervalSince1970: 20)),
    ])

    #expect(plainText(title) == "# 72/90")
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

    #expect(plainText(title) == "* --/--  # --/--")
}

private let claudeUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 62, resetsAt: nil),
    weekly: UsageWindow(percentRemaining: 81, resetsAt: nil)
)

private let codexUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 72, resetsAt: nil),
    weekly: UsageWindow(percentRemaining: 90, resetsAt: nil)
)

private func plainText(_ attributedString: AttributedString) -> String {
    String(attributedString.characters)
}
