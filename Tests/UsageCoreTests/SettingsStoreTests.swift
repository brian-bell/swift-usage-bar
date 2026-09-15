import Foundation
import Testing
import UsageCore

@Test
func settingsStoreReturnsDefaultsWhenNothingHasBeenSaved() {
    withIsolatedDefaults { defaults in
        let store = SettingsStore(defaults: defaults)

        #expect(store.pollInterval == UsagePoller.defaultInterval)
        #expect(store.isProviderVisible(.claude))
        #expect(store.isProviderVisible(.codex))
        #expect(!store.isProviderVisible(.openCodeGo))
        #expect(!store.isProviderVisible(.openCodeCredits))
        #expect(!store.isProviderVisible(.miniMax))
        #expect(!store.isProviderVisible(.cursor))
        #expect(!store.isProviderVisible(.kimi))
        #expect(!store.isProviderVisible(.xai))
        #expect(store.warningThresholds == [15])
        #expect(!store.launchAtLoginEnabled)
    }
}

@Test
func providerIDIsHiddenByDefaultReportsMembershipInTheSingleSourceOfTruth() {
    // The four sites that special-case a default-hidden provider
    // (MenuBarTitleFormatter, DropdownViewModel, SettingsStore,
    // AppSettingsDraft) all read from this membership. Pin it directly so
    // adding a fifth default-hidden provider — or un-hiding one — can't
    // drift between sites silently.
    #expect(ProviderID.defaultHiddenProviders == [.openCodeGo, .openCodeCredits, .miniMax, .cursor, .kimi, .xai])
    #expect(!ProviderID.claude.isHiddenByDefault)
    #expect(!ProviderID.codex.isHiddenByDefault)
    #expect(ProviderID.openCodeGo.isHiddenByDefault)
    #expect(ProviderID.openCodeCredits.isHiddenByDefault)
    #expect(ProviderID.miniMax.isHiddenByDefault)
    #expect(ProviderID.cursor.isHiddenByDefault)
    #expect(ProviderID.kimi.isHiddenByDefault)
    #expect(ProviderID.xai.isHiddenByDefault)
    #expect(ProviderID.kimi.reportsCreditsBalance)
    #expect(ProviderID.openCodeCredits.reportsCreditsBalance)
    #expect(ProviderID.xai.reportsCreditsBalance)
    #expect(!ProviderID.miniMax.reportsCreditsBalance)
}

@Test
func settingsStoreKeepsOpenCodeGoAndCreditsVisibilityIndependent() {
    // The two OpenCode providers read the same workspace but toggle
    // separately: flipping one must never move the other.
    withIsolatedDefaults { defaults in
        let store = SettingsStore(defaults: defaults)
        store.setProvider(.openCodeGo, visible: true)

        #expect(!SettingsStore(defaults: defaults).isProviderVisible(.openCodeCredits))

        store.setProvider(.openCodeCredits, visible: true)
        store.setProvider(.openCodeGo, visible: false)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.isProviderVisible(.openCodeCredits))
        #expect(!reloaded.isProviderVisible(.openCodeGo))
    }
}

@Test
func settingsStoreRoundTripsPollInterval() {
    withIsolatedDefaults { defaults in
        SettingsStore(defaults: defaults).pollInterval = 300

        #expect(SettingsStore(defaults: defaults).pollInterval == 300)
    }
}

@Test
func settingsStoreRoundTripsProviderVisibility() {
    withIsolatedDefaults { defaults in
        let store = SettingsStore(defaults: defaults)
        store.setProvider(.claude, visible: false)
        store.setProvider(.codex, visible: true)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(!reloaded.isProviderVisible(.claude))
        #expect(reloaded.isProviderVisible(.codex))
    }
}

@Test
func settingsStoreRoundTripsMiniMaxVisibility() {
    withIsolatedDefaults { defaults in
        let store = SettingsStore(defaults: defaults)
        store.setProvider(.miniMax, visible: true)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.isProviderVisible(.miniMax))
    }
}

@Test
func settingsStoreRoundTripsCursorVisibility() {
    withIsolatedDefaults { defaults in
        let store = SettingsStore(defaults: defaults)
        store.setProvider(.cursor, visible: true)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.isProviderVisible(.cursor))
    }
}

@Test
func openCodeGoWorkspaceNormalizerAcceptsIDsAndWorkspaceURLs() {
    let id = "wrk_01KEXAMPLE123"

    #expect(OpenCodeGoWorkspace.normalizedID(from: id) == id)
    #expect(OpenCodeGoWorkspace.normalizedID(
        from: "https://opencode.ai/workspace/\(id)/go"
    ) == id)
    #expect(OpenCodeGoWorkspace.normalizedID(from: "not a workspace") == nil)
    #expect(OpenCodeGoWorkspace.normalizedID(from: "   ") == nil)
}

@Test
func settingsStoreRoundTripsXAITeamID() {
    withIsolatedDefaults { defaults in
        let store = SettingsStore(defaults: defaults)
        store.xaiTeamID = "  65C1E471-205F-4566-9C5A-07198BCDF4CE  "

        #expect(SettingsStore(defaults: defaults).xaiTeamID == "65c1e471-205f-4566-9c5a-07198bcdf4ce")

        store.xaiTeamID = "not-a-uuid"
        #expect(SettingsStore(defaults: defaults).xaiTeamID == nil)
    }
}

@Test
func settingsStoreRoundTripsWarningThresholds() {
    withIsolatedDefaults { defaults in
        SettingsStore(defaults: defaults).warningThresholds = [30, 10]

        #expect(SettingsStore(defaults: defaults).warningThresholds == [30, 10])
    }
}

@Test
func settingsStoreRoundTripsAnEmptyWarningListSoAlertsCanBeTurnedOff() {
    // An empty list is a real value (alerts off), not "unset" — it must not
    // fall back to the default on the next read.
    withIsolatedDefaults { defaults in
        SettingsStore(defaults: defaults).warningThresholds = []

        #expect(SettingsStore(defaults: defaults).warningThresholds == [])
    }
}

@Test
func settingsStoreMigratesALegacySingleThresholdIntoTheWarningList() {
    withIsolatedDefaults { defaults in
        // The pre-multiple-warnings key, pinned as a literal so the on-disk
        // migration contract can't drift if the constant is ever renamed.
        defaults.set(35, forKey: "settings.thresholdPercent")

        #expect(SettingsStore(defaults: defaults).warningThresholds == [35])
    }
}

@Test
func settingsStoreIgnoresTheLegacyThresholdOnceWarningsHaveBeenSaved() {
    withIsolatedDefaults { defaults in
        defaults.set(35, forKey: "settings.thresholdPercent")
        SettingsStore(defaults: defaults).warningThresholds = [20, 5]

        #expect(SettingsStore(defaults: defaults).warningThresholds == [20, 5])
    }
}

@Test
func settingsStoreNormalizesWarningsIntoRangeWithoutDuplicatesAndCappedAtFive() {
    withIsolatedDefaults { defaults in
        SettingsStore(defaults: defaults).warningThresholds = [0, 101, 30, 30, 10, 20, 40, 50, 60]

        #expect(SettingsStore(defaults: defaults).warningThresholds == [1, 100, 30, 10, 20])
    }
}

@Test
func settingsStoreRoundTripsLaunchAtLoginFlag() {
    withIsolatedDefaults { defaults in
        SettingsStore(defaults: defaults).launchAtLoginEnabled = true

        #expect(SettingsStore(defaults: defaults).launchAtLoginEnabled)
    }
}

private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    body(defaults)
}
