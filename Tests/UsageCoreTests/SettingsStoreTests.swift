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
        #expect(store.thresholdPercent == 20)
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
    #expect(ProviderID.defaultHiddenProviders == [.openCodeGo, .openCodeCredits, .miniMax])
    #expect(!ProviderID.claude.isHiddenByDefault)
    #expect(!ProviderID.codex.isHiddenByDefault)
    #expect(ProviderID.openCodeGo.isHiddenByDefault)
    #expect(ProviderID.openCodeCredits.isHiddenByDefault)
    #expect(ProviderID.miniMax.isHiddenByDefault)
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
func settingsStoreRoundTripsThresholdPercent() {
    withIsolatedDefaults { defaults in
        SettingsStore(defaults: defaults).thresholdPercent = 35

        #expect(SettingsStore(defaults: defaults).thresholdPercent == 35)
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
