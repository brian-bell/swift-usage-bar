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
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.pollInterval = 600
            let model = draftTestModel(
                settingsStore: settingsStore,
                launchAtLoginManager: DraftTestLaunchAtLoginManager(status: .enabled)
            )

            let draft = AppSettingsDraft.capture(from: model)

            #expect(draft.pollInterval == 600)
            #expect(draft.launchAtLoginEnabled)
        }
    }

    @Test(arguments: [TimeInterval(60), 120, 300, 600])
    @MainActor
    func applyCommitsEachSelectablePollInterval(_ interval: TimeInterval) {
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.pollInterval = 1
            let model = draftTestModel(settingsStore: settingsStore)

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
        withSettingsDefaults { defaults in
            let model = draftTestModel(settingsStore: SettingsStore(defaults: defaults))
            let changes = DraftChangeRecorder()

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
        withSettingsDefaults { defaults in
            let launchManager = DraftTestLaunchAtLoginManager()
            let model = draftTestModel(
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
        withSettingsDefaults { defaults in
            let launchManager = DraftTestLaunchAtLoginManager()
            let model = draftTestModel(
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
        withSettingsDefaults { defaults in
            let launchManager = DraftTestLaunchAtLoginManager(error: DraftTestLaunchError.failed)
            let model = draftTestModel(
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
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.setProvider(.claude, visible: false)
            settingsStore.setProvider(.codex, visible: true)
            settingsStore.setProvider(.openCodeGo, visible: true)
            let model = draftTestModel(settingsStore: settingsStore)

            let draft = AppSettingsDraft.capture(from: model)

            #expect(!draft.visibility(for: .claude))
            #expect(draft.visibility(for: .codex))
            #expect(draft.visibility(for: .openCodeGo))
        }
    }

    @Test(arguments: ProviderID.allCases)
    @MainActor
    func applyTogglesVisibilityForOneProviderWithoutDisturbingTheOthers(_ provider: ProviderID) {
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            for candidate in ProviderID.allCases {
                settingsStore.setProvider(candidate, visible: true)
            }
            let appState = AppState()
            let model = draftTestModel(appState: appState, settingsStore: settingsStore)

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
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.setProvider(.openCodeGo, visible: false)
            let model = draftTestModel(settingsStore: settingsStore)

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
        withSettingsDefaults { defaults in
            let model = draftTestModel(settingsStore: SettingsStore(defaults: defaults))

            #expect(AppSettingsDraft.capture(from: model).openCodeGoWorkspace.isEmpty)
        }
    }

    @Test
    @MainActor
    func captureRendersAStoredWorkspaceID() {
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.openCodeGoWorkspaceID = "wrk_01KSTORED0001"
            let model = draftTestModel(settingsStore: settingsStore)

            #expect(AppSettingsDraft.capture(from: model).openCodeGoWorkspace == "wrk_01KSTORED0001")
        }
    }

    @Test
    @MainActor
    func applyNormalizesABareWorkspaceID() {
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            let model = draftTestModel(settingsStore: settingsStore)

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
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            let model = draftTestModel(settingsStore: settingsStore)

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
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.openCodeGoWorkspaceID = "wrk_01KSTORED0001"
            let model = draftTestModel(settingsStore: settingsStore)

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
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.openCodeGoWorkspaceID = "wrk_01KSTORED0001"
            let model = draftTestModel(settingsStore: settingsStore)

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
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.openCodeGoWorkspaceID = "wrk_01KEXAMPLE123"
            let model = draftTestModel(settingsStore: settingsStore)
            let changes = DraftChangeRecorder()

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
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            settingsStore.thresholdPercent = 42
            let model = draftTestModel(settingsStore: settingsStore)

            #expect(AppSettingsDraft.capture(from: model).thresholdPercent == 42)
        }
    }

    @Test(arguments: [1, 20, 100])
    @MainActor
    func applyCommitsThresholdsAcrossTheStepperRange(_ threshold: Int) {
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            let model = draftTestModel(settingsStore: settingsStore)

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
        withSettingsDefaults { defaults in
            let model = draftTestModel(settingsStore: SettingsStore(defaults: defaults))
            let changes = DraftChangeRecorder()

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
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            let launchManager = DraftTestLaunchAtLoginManager()
            let model = draftTestModel(
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
        withSettingsDefaults { defaults in
            let settingsStore = SettingsStore(defaults: defaults)
            let model = draftTestModel(settingsStore: settingsStore)
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

// MARK: - Test support

private let draftTestNow = Date(timeIntervalSince1970: 1_767_268_800)

@MainActor
private func draftTestModel(
    appState: AppState = AppState(),
    settingsStore: SettingsStore,
    launchAtLoginManager: any LaunchAtLoginManaging = DraftTestLaunchAtLoginManager()
) -> UsageBarShellModel {
    UsageBarShellModel(
        appState: appState,
        settingsStore: settingsStore,
        usageController: DraftTestUsageController(),
        launchAtLoginManager: launchAtLoginManager,
        now: { draftTestNow }
    )
}

private struct DraftTestUsageController: UsageControlling {
    func start() async {}
    func stop() async {}
    func refreshNow() async {}
    func setPollingInterval(_ interval: TimeInterval) async {}
}

private final class DraftTestLaunchAtLoginManager: LaunchAtLoginManaging {
    private let error: (any Error)?
    var requests: [Bool] = []
    var status: LaunchAtLoginStatus

    init(status: LaunchAtLoginStatus = .disabled, error: (any Error)? = nil) {
        self.status = status
        self.error = error
    }

    func setEnabled(_ enabled: Bool) throws {
        if let error {
            throw error
        }

        requests.append(enabled)
        status = enabled ? .enabled : .disabled
    }
}

private enum DraftTestLaunchError: Error {
    case failed
}

private final class DraftChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCount
    }

    func record() {
        lock.lock()
        recordedCount += 1
        lock.unlock()
    }
}

private func withSettingsDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "AppSettingsDraftTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    body(defaults)
}
