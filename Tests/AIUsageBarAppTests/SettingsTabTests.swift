import Testing

@testable import AIUsageBarApp

/// The tab list is the only decidable part of the tabbed Settings window: which tabs exist,
/// in what order, how they are titled, and which one is selected when the window opens.
@Suite("Settings tabs")
struct SettingsTabTests {
    @Test
    func tabsAreOrderedGeneralProvidersNotifications() {
        #expect(SettingsTab.allCases == [.general, .providers, .notifications])
    }

    @Test
    func tabTitlesMatchTheSettingsWindowLabels() {
        #expect(SettingsTab.general.title == "General")
        #expect(SettingsTab.providers.title == "Providers")
        #expect(SettingsTab.notifications.title == "Notifications")
    }

    @Test
    func everyTabHasADistinctNonEmptySymbol() {
        let symbols = SettingsTab.allCases.map(\.systemImage)

        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(symbols).count == SettingsTab.allCases.count)
    }

    @Test
    func windowOpensOnTheGeneralTab() {
        #expect(SettingsTab.initial == .general)
    }
}
