import Foundation
import Observation
import Testing
import UsageCore

@testable import AIUsageBarApp

/// The Settings window is split across tabs (General / Providers / Notifications), but every
/// control on every tab is still staged in one `AppSettingsDraft` and committed by the shared
/// OK button. These suites pin the capture/apply contract for each tab's settings.
@Suite("Settings draft — General tab")
struct AppSettingsDraftGeneralTabTests {
    @Test
    @MainActor
    func captureReadsPollIntervalAndLaunchAtLogin() {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.pollInterval = 600
            let model = shellModel(
                settingsStore: settingsStore,
                launchAtLoginManager: RecordingLaunchAtLoginManager(status: .enabled)
            )

            let draft = AppSettingsDraft.capture(from: model)

            #expect(draft.pollInterval == 600)
            #expect(draft.launchAtLoginEnabled)
        }
    }

    @Test(arguments: [TimeInterval(60), 120, 300, 600])
    @MainActor
    func applyCommitsEachSelectablePollInterval(_ interval: TimeInterval) {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.pollInterval = 1
            let model = shellModel(settingsStore: settingsStore)

            var draft = AppSettingsDraft.capture(from: model)
            draft.pollInterval = interval
            draft.apply(to: model)

            #expect(model.pollInterval == interval)
            #expect(settingsStore.pollInterval == interval)
        }
    }

    @Test
    @MainActor
    func applyLeavesUnchangedPollIntervalUntouched() {
        withIsolatedDefaults { defaults in
            let model = shellModel(settingsStore: SettingsStore(defaults: defaults))
            let changes = ObservationChangeRecorder()

            let draft = AppSettingsDraft.capture(from: model)
            withObservationTracking {
                _ = model.pollInterval
            } onChange: {
                changes.record()
            }
            draft.apply(to: model)

            #expect(changes.count == 0)
        }
    }

    @Test
    @MainActor
    func applyReturnsTrueWhenLaunchAtLoginChangedSoTheDialogStaysOpen() {
        withIsolatedDefaults { defaults in
            let launchManager = RecordingLaunchAtLoginManager()
            let model = shellModel(
                settingsStore: SettingsStore(defaults: defaults),
                launchAtLoginManager: launchManager
            )

            var draft = AppSettingsDraft.capture(from: model)
            draft.launchAtLoginEnabled = true

            #expect(draft.apply(to: model))
            #expect(launchManager.requests == [true])
        }
    }

    @Test
    @MainActor
    func applyReturnsFalseWhenLaunchAtLoginIsUnchanged() {
        withIsolatedDefaults { defaults in
            let launchManager = RecordingLaunchAtLoginManager()
            let model = shellModel(
                settingsStore: SettingsStore(defaults: defaults),
                launchAtLoginManager: launchManager
            )

            var draft = AppSettingsDraft.capture(from: model)
            draft.thresholdPercent += 1

            #expect(!draft.apply(to: model))
            #expect(launchManager.requests.isEmpty)
        }
    }

    @Test
    @MainActor
    func failedLaunchAtLoginChangeSurfacesErrorAndRecaptureResyncsTheToggle() {
        withIsolatedDefaults { defaults in
            let launchManager = RecordingLaunchAtLoginManager(error: LaunchAtLoginTestError.failed)
            let model = shellModel(
                settingsStore: SettingsStore(defaults: defaults),
                launchAtLoginManager: launchManager
            )

            var draft = AppSettingsDraft.capture(from: model)
            draft.launchAtLoginEnabled = true
            let attemptedLaunchChange = draft.apply(to: model)

            // The view keeps the dialog open on exactly this combination, then re-captures.
            #expect(attemptedLaunchChange)
            #expect(model.launchAtLoginError == "Launch at login could not be updated.")

            draft = .capture(from: model)
            #expect(!draft.launchAtLoginEnabled)
        }
    }
}

@Suite("Settings draft — Providers tab")
struct AppSettingsDraftProvidersTabTests {
    @Test
    @MainActor
    func captureReadsEveryProviderVisibility() {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.setProvider(.claude, visible: false)
            settingsStore.setProvider(.codex, visible: true)
            settingsStore.setProvider(.openCodeGo, visible: true)
            let model = shellModel(settingsStore: settingsStore)

            let draft = AppSettingsDraft.capture(from: model)

            #expect(!draft.visibility(for: .claude))
            #expect(draft.visibility(for: .codex))
            #expect(draft.visibility(for: .openCodeGo))
        }
    }

    @Test(arguments: ProviderID.allCases)
    @MainActor
    func applyTogglesVisibilityForOneProviderWithoutDisturbingTheOthers(_ provider: ProviderID) {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            for candidate in ProviderID.allCases {
                settingsStore.setProvider(candidate, visible: true)
            }
            let appState = AppState()
            let model = shellModel(appState: appState, settingsStore: settingsStore)

            var draft = AppSettingsDraft.capture(from: model)
            draft.providerVisibility[provider] = false
            draft.apply(to: model)

            #expect(!model.isProviderVisible(provider))
            #expect(!settingsStore.isProviderVisible(provider))
            #expect(appState.providerState(for: provider) == .hidden)
            for other in ProviderID.allCases where other != provider {
                #expect(model.isProviderVisible(other))
                #expect(settingsStore.isProviderVisible(other))
            }
        }
    }

    @Test
    @MainActor
    func applyRestoresAHiddenProvider() {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.setProvider(.openCodeGo, visible: false)
            let model = shellModel(settingsStore: settingsStore)

            var draft = AppSettingsDraft.capture(from: model)
            draft.providerVisibility[.openCodeGo] = true
            draft.apply(to: model)

            #expect(model.isProviderVisible(.openCodeGo))
            #expect(settingsStore.isProviderVisible(.openCodeGo))
        }
    }

    @Test
    @MainActor
    func visibilityDefaultsToVisibleForAnUnrecordedProvider() {
        var draft = AppSettingsDraft.placeholder
        draft.providerVisibility.removeValue(forKey: .codex)

        #expect(draft.visibility(for: .codex))
    }

    @Test
    @MainActor
    func placeholderHidesOpenCodeGoAndMiniMax() {
        #expect(AppSettingsDraft.placeholder.visibility(for: .claude))
        #expect(AppSettingsDraft.placeholder.visibility(for: .codex))
        #expect(!AppSettingsDraft.placeholder.visibility(for: .openCodeGo))
        #expect(!AppSettingsDraft.placeholder.visibility(for: .miniMax))
    }

    @Test
    @MainActor
    func captureRendersAnUnsetWorkspaceAsAnEmptyField() {
        withIsolatedDefaults { defaults in
            let model = shellModel(settingsStore: SettingsStore(defaults: defaults))

            #expect(AppSettingsDraft.capture(from: model).openCodeGoWorkspace.isEmpty)
        }
    }

    @Test
    @MainActor
    func captureRendersAStoredWorkspaceID() {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.openCodeGoWorkspaceID = "wrk_01KSTORED0001"
            let model = shellModel(settingsStore: settingsStore)

            #expect(AppSettingsDraft.capture(from: model).openCodeGoWorkspace == "wrk_01KSTORED0001")
        }
    }

    @Test
    @MainActor
    func applyNormalizesABareWorkspaceID() {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            let model = shellModel(settingsStore: settingsStore)

            var draft = AppSettingsDraft.capture(from: model)
            draft.openCodeGoWorkspace = "  wrk_01KEXAMPLE123  "
            draft.apply(to: model)

            #expect(model.openCodeGoWorkspaceID == "wrk_01KEXAMPLE123")
            #expect(settingsStore.openCodeGoWorkspaceID == "wrk_01KEXAMPLE123")
        }
    }

    @Test
    @MainActor
    func applyNormalizesAFullWorkspaceURL() {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            let model = shellModel(settingsStore: settingsStore)

            var draft = AppSettingsDraft.capture(from: model)
            draft.openCodeGoWorkspace = "https://opencode.ai/workspace/wrk_01KEXAMPLE123/go"
            draft.apply(to: model)

            #expect(model.openCodeGoWorkspaceID == "wrk_01KEXAMPLE123")
            #expect(settingsStore.openCodeGoWorkspaceID == "wrk_01KEXAMPLE123")
        }
    }

    @Test
    @MainActor
    func applyClearsTheWorkspaceWhenTheFieldIsEmptied() {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.openCodeGoWorkspaceID = "wrk_01KSTORED0001"
            let model = shellModel(settingsStore: settingsStore)

            var draft = AppSettingsDraft.capture(from: model)
            draft.openCodeGoWorkspace = ""
            draft.apply(to: model)

            #expect(model.openCodeGoWorkspaceID == nil)
            #expect(settingsStore.openCodeGoWorkspaceID == nil)
        }
    }

    @Test
    @MainActor
    func applyClearsTheWorkspaceWhenTheFieldIsUnusable() {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.openCodeGoWorkspaceID = "wrk_01KSTORED0001"
            let model = shellModel(settingsStore: settingsStore)

            var draft = AppSettingsDraft.capture(from: model)
            draft.openCodeGoWorkspace = "not-a-workspace"
            draft.apply(to: model)

            #expect(model.openCodeGoWorkspaceID == nil)
            #expect(settingsStore.openCodeGoWorkspaceID == nil)
        }
    }

    @Test
    @MainActor
    func applyLeavesAnEquivalentWorkspaceEditUntouched() {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.openCodeGoWorkspaceID = "wrk_01KEXAMPLE123"
            let model = shellModel(settingsStore: settingsStore)
            let changes = ObservationChangeRecorder()

            var draft = AppSettingsDraft.capture(from: model)
            // Same workspace, expressed as a URL: normalization makes this a no-op.
            draft.openCodeGoWorkspace = "https://opencode.ai/workspace/wrk_01KEXAMPLE123/go"
            withObservationTracking {
                _ = model.openCodeGoWorkspaceID
            } onChange: {
                changes.record()
            }
            draft.apply(to: model)

            #expect(changes.count == 0)
            #expect(model.openCodeGoWorkspaceID == "wrk_01KEXAMPLE123")
        }
    }
}

@Suite("Settings draft — Notifications tab")
struct AppSettingsDraftNotificationsTabTests {
    @Test
    @MainActor
    func captureReadsTheThresholdPercent() {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.thresholdPercent = 42
            let model = shellModel(settingsStore: settingsStore)

            #expect(AppSettingsDraft.capture(from: model).thresholdPercent == 42)
        }
    }

    @Test(arguments: [1, 20, 100])
    @MainActor
    func applyCommitsThresholdsAcrossTheStepperRange(_ threshold: Int) {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            let model = shellModel(settingsStore: settingsStore)

            var draft = AppSettingsDraft.capture(from: model)
            draft.thresholdPercent = threshold
            draft.apply(to: model)

            #expect(model.thresholdPercent == threshold)
            #expect(settingsStore.thresholdPercent == threshold)
        }
    }

    @Test
    @MainActor
    func applyLeavesAnUnchangedThresholdUntouched() {
        withIsolatedDefaults { defaults in
            let model = shellModel(settingsStore: SettingsStore(defaults: defaults))
            let changes = ObservationChangeRecorder()

            let draft = AppSettingsDraft.capture(from: model)
            withObservationTracking {
                _ = model.thresholdPercent
            } onChange: {
                changes.record()
            }
            draft.apply(to: model)

            #expect(changes.count == 0)
        }
    }
}

@Suite("Settings draft — all tabs together")
struct AppSettingsDraftAllTabsTests {
    @Test
    @MainActor
    func oneApplyCommitsEditsMadeOnEveryTab() {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            let launchManager = RecordingLaunchAtLoginManager()
            let model = shellModel(
                settingsStore: settingsStore,
                launchAtLoginManager: launchManager
            )

            var draft = AppSettingsDraft.capture(from: model)
            draft.pollInterval = 300                                    // General
            draft.launchAtLoginEnabled = true                           // General
            draft.providerVisibility[.openCodeGo] = true                // Providers
            draft.openCodeGoWorkspace = "wrk_01KEXAMPLE123"             // Providers
            draft.thresholdPercent = 15                                 // Notifications
            draft.apply(to: model)

            #expect(model.pollInterval == 300)
            #expect(model.launchAtLoginEnabled)
            #expect(model.isProviderVisible(.openCodeGo))
            #expect(model.openCodeGoWorkspaceID == "wrk_01KEXAMPLE123")
            #expect(model.thresholdPercent == 15)
        }
    }

    @Test
    @MainActor
    func discardingTheDraftLeavesEveryTabsSettingsUnchanged() {
        withIsolatedDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            let model = shellModel(settingsStore: settingsStore)
            let captured = AppSettingsDraft.capture(from: model)

            var draft = captured
            draft.pollInterval = 600
            draft.thresholdPercent = 5
            draft.providerVisibility[.claude] = false
            draft.openCodeGoWorkspace = "wrk_01KEXAMPLE123"
            draft.launchAtLoginEnabled = true
            // Cancel: never applied.

            #expect(AppSettingsDraft.capture(from: model) == captured)
        }
    }
}
