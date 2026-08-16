import UsageCore

/// Stable accessibility identifiers for hosted UI tests.
///
/// Hierarchical kebab-case strings only — never include dynamic percents or ages.
enum AccessibilityID {
    /// Window slot token for hierarchical ids — not the domain `UsageWindow` model.
    enum WindowKey: String, Sendable {
        case fiveHour
        case weekly
        case monthly
        case fable
    }

    /// Always present on the combined menu-bar label element. Empty state is
    /// detected via accessibility value `"AI Usage"`, not a separate identifier.
    static let menuBarLabel = "menubar.label"

    static let menuBarRefresh = "menubar.content.refresh"
    static let menuBarSettings = "menubar.content.settings"
    static let menuBarQuit = "menubar.content.quit"
    static let menuBarUpdated = "menubar.content.updated"

    static let settingsCancel = "settings.cancel"
    static let settingsOK = "settings.ok"
    static let settingsTabGeneral = "settings.tab.general"
    static let settingsTabProviders = "settings.tab.providers"
    static let settingsTabNotifications = "settings.tab.notifications"
    static let settingsPollInterval = "settings.general.pollInterval"
    static let settingsLaunchAtLogin = "settings.general.launchAtLogin"
    static let settingsLaunchAtLoginError = "settings.general.launchAtLoginError"
    static let settingsThreshold = "settings.notifications.threshold"

    static func providerToken(_ provider: ProviderID) -> String {
        switch provider {
        case .claude:
            return "claude"
        case .codex:
            return "codex"
        case .openCodeGo:
            return "opencodeGo"
        case .openCodeCredits:
            return "opencodeCredits"
        case .miniMax:
            return "minimax"
        case .cursor:
            return "cursor"
        }
    }

    static func menuBarProvider(_ provider: ProviderID) -> String {
        "menubar.content.provider.\(providerToken(provider))"
    }

    static func menuBarProviderStale(_ provider: ProviderID) -> String {
        "\(menuBarProvider(provider)).stale"
    }

    static func menuBarWindow(_ provider: ProviderID, _ window: WindowKey) -> String {
        "\(menuBarProvider(provider)).window.\(window.rawValue)"
    }

    static func menuBarWindowBar(_ provider: ProviderID, _ window: WindowKey) -> String {
        "\(menuBarWindow(provider, window)).bar"
    }

    static func menuBarWindowPercent(_ provider: ProviderID, _ window: WindowKey) -> String {
        "\(menuBarWindow(provider, window)).percent"
    }

    static func menuBarWindowCountdown(_ provider: ProviderID, _ window: WindowKey) -> String {
        "\(menuBarWindow(provider, window)).countdown"
    }

    /// Credits row (rendered under the OpenCode Credits provider). The
    /// window-kind enum sees no new case — credits are not a `UsageWindow`
    /// and have no kind, even though the row renders the same label-over-bar
    /// shape as the windows.
    static func menuBarProviderCredits(_ provider: ProviderID) -> String {
        "\(menuBarProvider(provider)).credits"
    }

    static func menuBarProviderCreditsAmount(_ provider: ProviderID) -> String {
        "\(menuBarProviderCredits(provider)).amount"
    }

    static func menuBarProviderCreditsBar(_ provider: ProviderID) -> String {
        "\(menuBarProviderCredits(provider)).bar"
    }

    static func menuBarProviderCreditsLimit(_ provider: ProviderID) -> String {
        "\(menuBarProviderCredits(provider)).limit"
    }

    static func settingsProviderToggle(_ provider: ProviderID) -> String {
        "settings.provider.\(providerToken(provider)).toggle"
    }

    static func settingsProviderStatus(_ provider: ProviderID) -> String {
        "settings.provider.\(providerToken(provider)).status"
    }

    static func settingsProviderDisclosure(_ provider: ProviderID) -> String {
        "settings.provider.\(providerToken(provider)).disclosure"
    }

    static func settingsProviderCallout(_ provider: ProviderID) -> String {
        "settings.provider.\(providerToken(provider)).callout"
    }

    static func settingsProviderWorkspace(_ provider: ProviderID) -> String {
        "settings.provider.\(providerToken(provider)).workspace"
    }

    /// 1-based step number matching the visible chain numbering.
    static func settingsProviderChain(_ provider: ProviderID, step: Int) -> String {
        "settings.provider.\(providerToken(provider)).chain.\(step)"
    }

    static func settingsTab(_ tab: SettingsTab) -> String {
        switch tab {
        case .general:
            return settingsTabGeneral
        case .providers:
            return settingsTabProviders
        case .notifications:
            return settingsTabNotifications
        }
    }
}
