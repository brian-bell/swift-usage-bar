import Testing
import UsageCore

@testable import AIUsageBarApp

@Test
func accessibilityIDProviderTokensMatchCatalog() {
    #expect(AccessibilityID.providerToken(.claude) == "claude")
    #expect(AccessibilityID.providerToken(.codex) == "codex")
    #expect(AccessibilityID.providerToken(.openCodeGo) == "opencodeGo")
    #expect(AccessibilityID.providerToken(.openCodeCredits) == "opencodeCredits")
    #expect(AccessibilityID.providerToken(.miniMax) == "minimax")
    #expect(AccessibilityID.providerToken(.cursor) == "cursor")
}

@Test
func accessibilityIDCatalogUsesHierarchicalKebabCase() {
    #expect(AccessibilityID.menuBarLabel == "menubar.label")
    #expect(AccessibilityID.menuBarRefresh == "menubar.content.refresh")
    #expect(AccessibilityID.menuBarSettings == "menubar.content.settings")
    #expect(AccessibilityID.menuBarQuit == "menubar.content.quit")
    #expect(AccessibilityID.menuBarUpdated == "menubar.content.updated")
    #expect(AccessibilityID.menuBarProvider(.claude) == "menubar.content.provider.claude")
    #expect(AccessibilityID.menuBarProviderStale(.claude) == "menubar.content.provider.claude.stale")
    #expect(
        AccessibilityID.menuBarWindow(.claude, .fiveHour)
            == "menubar.content.provider.claude.window.fiveHour"
    )
    #expect(
        AccessibilityID.menuBarWindowPercent(.claude, .fiveHour)
            == "menubar.content.provider.claude.window.fiveHour.percent"
    )
    #expect(
        AccessibilityID.menuBarWindowCountdown(.claude, .fiveHour)
            == "menubar.content.provider.claude.window.fiveHour.countdown"
    )
    #expect(
        AccessibilityID.menuBarWindowBar(.codex, .weekly)
            == "menubar.content.provider.codex.window.weekly.bar"
    )
    #expect(
        AccessibilityID.menuBarWindow(.openCodeGo, .monthly)
            == "menubar.content.provider.opencodeGo.window.monthly"
    )
    #expect(
        AccessibilityID.menuBarWindow(.claude, .fable)
            == "menubar.content.provider.claude.window.fable"
    )
    #expect(
        AccessibilityID.menuBarProviderCredits(.openCodeCredits)
            == "menubar.content.provider.opencodeCredits.credits"
    )
    #expect(
        AccessibilityID.menuBarProviderCreditsAmount(.openCodeCredits)
            == "menubar.content.provider.opencodeCredits.credits.amount"
    )
    #expect(
        AccessibilityID.menuBarProviderCreditsBar(.openCodeCredits)
            == "menubar.content.provider.opencodeCredits.credits.bar"
    )
    #expect(
        AccessibilityID.menuBarProviderCreditsLimit(.openCodeCredits)
            == "menubar.content.provider.opencodeCredits.credits.limit"
    )
    // Empty menu-bar state uses the same identifier; value is "AI Usage".
    #expect(MenuBarLabelImage.accessibilityValue(for: []) == "AI Usage")
    #expect(AccessibilityID.settingsCancel == "settings.cancel")
    #expect(AccessibilityID.settingsOK == "settings.ok")
    #expect(AccessibilityID.settingsTab(.general) == "settings.tab.general")
    #expect(AccessibilityID.settingsTab(.providers) == "settings.tab.providers")
    #expect(AccessibilityID.settingsTab(.notifications) == "settings.tab.notifications")
    #expect(AccessibilityID.settingsPollInterval == "settings.general.pollInterval")
    #expect(AccessibilityID.settingsLaunchAtLogin == "settings.general.launchAtLogin")
    #expect(AccessibilityID.settingsLaunchAtLoginError == "settings.general.launchAtLoginError")
    #expect(AccessibilityID.settingsThreshold == "settings.notifications.threshold")
    #expect(
        AccessibilityID.settingsProviderToggle(.miniMax)
            == "settings.provider.minimax.toggle"
    )
    #expect(
        AccessibilityID.settingsProviderStatus(.codex)
            == "settings.provider.codex.status"
    )
    #expect(
        AccessibilityID.settingsProviderDisclosure(.claude)
            == "settings.provider.claude.disclosure"
    )
    #expect(
        AccessibilityID.settingsProviderCallout(.openCodeGo)
            == "settings.provider.opencodeGo.callout"
    )
    #expect(
        AccessibilityID.settingsProviderChain(.openCodeGo, step: 1)
            == "settings.provider.opencodeGo.chain.1"
    )
    #expect(
        AccessibilityID.settingsProviderWorkspace(.openCodeGo)
            == "settings.provider.opencodeGo.workspace"
    )
}
