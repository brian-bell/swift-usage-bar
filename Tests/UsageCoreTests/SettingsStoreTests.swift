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
        #expect(store.thresholdPercent == 20)
        #expect(!store.launchAtLoginEnabled)
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
