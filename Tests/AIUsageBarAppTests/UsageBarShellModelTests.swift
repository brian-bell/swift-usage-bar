import Foundation
import Observation
import Testing
import UsageCore

@testable import AIUsageBarApp

@Test
@MainActor
func shellModelMenuBarSegmentsUseCoreFormatter() {
    let appState = AppState(providerStates: [
        .codex: .fresh(codexUsage, asOf: referenceNow),
        .claude: .fresh(claudeUsage, asOf: referenceNow),
    ])
    let model = shellModel(appState: appState)

    #expect(model.menuBarSegments == [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: false),
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
    ])
}

@Test
@MainActor
func shellModelMenuBarSegmentsAreEmptyWhenAllProvidersAreHidden() {
    let appState = AppState(providerStates: [
        .claude: .hidden,
        .codex: .hidden,
    ])
    let model = shellModel(appState: appState)

    // MenuBarLabelView renders the "AI Usage" fallback for empty segments.
    #expect(model.menuBarSegments.isEmpty)
}

@Test
@MainActor
func shellModelRefreshIntentCallsUsageController() async {
    let usageController = RecordingUsageController()
    let model = shellModel(usageController: usageController)

    await model.refreshNow()

    #expect(await usageController.refreshCallCount() == 1)
}

@Test
@MainActor
func shellModelPresentSettingsInvokesInstalledOpener() {
    let model = shellModel()
    var openCount = 0
    model.setSettingsOpener { openCount += 1 }

    model.presentSettings()

    #expect(openCount == 1)
}

@Test
@MainActor
func shellModelPresentSettingsIsNoOpWithoutOpener() {
    let model = shellModel()

    // Should not trap when no opener has been installed yet.
    model.presentSettings()
}

@Test
@MainActor
func shellModelProviderVisibilityUpdatesSettingsAndAppStateOnlyForThatProvider() {
    withIsolatedDefaults { defaults in
        let appState = AppState(providerStates: [
            .claude: .fresh(claudeUsage, asOf: referenceNow),
            .codex: .fresh(codexUsage, asOf: referenceNow),
        ])
        let settingsStore = SettingsStore(defaults: defaults)
        let model = shellModel(appState: appState, settingsStore: settingsStore)

        model.setProvider(.claude, visible: false)

        #expect(!settingsStore.isProviderVisible(.claude))
        #expect(settingsStore.isProviderVisible(.codex))
        #expect(appState.providerState(for: .claude) == .hidden)
        #expect(appState.providerState(for: .codex) == .fresh(codexUsage, asOf: referenceNow))
    }
}

@Test
@MainActor
func shellModelProviderVisibilityReflectsStoredSettingsAtInit() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.setProvider(.codex, visible: false)

        let model = shellModel(settingsStore: settingsStore)

        #expect(!model.isProviderVisible(.codex))
        #expect(model.isProviderVisible(.claude))
    }
}

@Test
@MainActor
func shellModelProviderVisibilityBindingPublishesObservationChange() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let model = shellModel(settingsStore: settingsStore)
        let observedChanges = ObservationChangeRecorder()

        withObservationTracking {
            _ = model.isProviderVisible(.codex)
        } onChange: {
            observedChanges.record()
        }

        model.setProvider(.codex, visible: false)

        #expect(observedChanges.count == 1)
        #expect(!model.isProviderVisible(.codex))
        #expect(!settingsStore.isProviderVisible(.codex))
    }
}

@Test
@MainActor
func shellModelPollIntervalBindingPublishesObservationChange() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let model = shellModel(settingsStore: settingsStore)
        let observedChanges = ObservationChangeRecorder()

        withObservationTracking {
            _ = model.pollInterval
        } onChange: {
            observedChanges.record()
        }

        model.setPollInterval(300)

        #expect(observedChanges.count == 1)
        #expect(model.pollInterval == 300)
        #expect(settingsStore.pollInterval == 300)
    }
}

@Test
@MainActor
func shellModelThresholdBindingPublishesObservationChange() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let model = shellModel(settingsStore: settingsStore)
        let observedChanges = ObservationChangeRecorder()

        withObservationTracking {
            _ = model.thresholdPercent
        } onChange: {
            observedChanges.record()
        }

        model.setThresholdPercent(35)

        #expect(observedChanges.count == 1)
        #expect(model.thresholdPercent == 35)
        #expect(settingsStore.thresholdPercent == 35)
    }
}

@Test
@MainActor
func shellModelLaunchAtLoginBindingPublishesObservationChange() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let launchManager = RecordingLaunchAtLoginManager()
        let model = shellModel(settingsStore: settingsStore, launchAtLoginManager: launchManager)
        let observedChanges = ObservationChangeRecorder()

        withObservationTracking {
            _ = model.launchAtLoginEnabled
        } onChange: {
            observedChanges.record()
        }

        model.setLaunchAtLoginEnabled(true)

        #expect(observedChanges.count == 1)
        #expect(model.launchAtLoginEnabled)
        #expect(settingsStore.launchAtLoginEnabled)
    }
}

@Test
@MainActor
func shellModelLaunchAtLoginIntentPersistsSuccessfulEnableAndDisable() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let launchManager = RecordingLaunchAtLoginManager()
        let model = shellModel(settingsStore: settingsStore, launchAtLoginManager: launchManager)

        model.setLaunchAtLoginEnabled(true)
        model.setLaunchAtLoginEnabled(false)

        #expect(launchManager.requests == [true, false])
        #expect(!settingsStore.launchAtLoginEnabled)
        #expect(model.launchAtLoginError == nil)
    }
}

@Test
@MainActor
func shellModelLaunchAtLoginIntentPersistsEffectiveManagerState() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let launchManager = RecordingLaunchAtLoginManager(statusAfterSet: .disabled)
        let model = shellModel(settingsStore: settingsStore, launchAtLoginManager: launchManager)

        model.setLaunchAtLoginEnabled(true)

        #expect(launchManager.requests == [true])
        #expect(!model.launchAtLoginEnabled)
        #expect(!settingsStore.launchAtLoginEnabled)
        #expect(model.launchAtLoginError == nil)
    }
}

@Test
@MainActor
func shellModelLaunchAtLoginPromptTracksApprovalRequiredState() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let launchManager = RecordingLaunchAtLoginManager(status: .requiresApproval)
        let model = shellModel(settingsStore: settingsStore, launchAtLoginManager: launchManager)

        #expect(model.launchAtLoginEnabled)
        #expect(settingsStore.launchAtLoginEnabled)
        #expect(model.launchAtLoginError == "Approve launch at login in System Settings.")
    }
}

@Test
@MainActor
func shellModelLaunchAtLoginCanDisableApprovalRequiredRegistration() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let launchManager = RecordingLaunchAtLoginManager(status: .requiresApproval)
        let model = shellModel(settingsStore: settingsStore, launchAtLoginManager: launchManager)

        model.setLaunchAtLoginEnabled(false)

        #expect(launchManager.requests == [false])
        #expect(!model.launchAtLoginEnabled)
        #expect(!settingsStore.launchAtLoginEnabled)
        #expect(model.launchAtLoginError == nil)
    }
}

@Test
@MainActor
func shellModelLaunchAtLoginShowsApprovalPromptInsteadOfRetryingRegister() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let launchManager = RecordingLaunchAtLoginManager(status: .requiresApproval)
        let model = shellModel(settingsStore: settingsStore, launchAtLoginManager: launchManager)

        model.setLaunchAtLoginEnabled(true)

        #expect(launchManager.requests.isEmpty)
        #expect(model.launchAtLoginEnabled)
        #expect(settingsStore.launchAtLoginEnabled)
        #expect(model.launchAtLoginError == "Approve launch at login in System Settings.")
    }
}

@Test
@MainActor
func shellModelLaunchAtLoginIntentReportsFailureWithoutPersistingPreference() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let launchManager = RecordingLaunchAtLoginManager(error: LaunchAtLoginTestError.failed)
        let model = shellModel(settingsStore: settingsStore, launchAtLoginManager: launchManager)

        model.setLaunchAtLoginEnabled(true)

        #expect(!settingsStore.launchAtLoginEnabled)
        #expect(model.launchAtLoginError == "Launch at login could not be updated.")
    }
}

@Test
@MainActor
func settingsDraftCapturesCurrentModelValues() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.pollInterval = 300
        settingsStore.thresholdPercent = 35
        settingsStore.setProvider(.codex, visible: false)
        let launchManager = RecordingLaunchAtLoginManager(status: .enabled)
        let model = shellModel(settingsStore: settingsStore, launchAtLoginManager: launchManager)

        let draft = AppSettingsDraft.capture(from: model)

        #expect(draft.pollInterval == 300)
        #expect(draft.thresholdPercent == 35)
        #expect(draft.visibility(for: .claude))
        #expect(!draft.visibility(for: .codex))
        #expect(draft.launchAtLoginEnabled)
    }
}

@Test
@MainActor
func settingsDraftApplyPersistsChangedValues() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let appState = AppState(providerStates: [
            .claude: .fresh(claudeUsage, asOf: referenceNow),
            .codex: .fresh(codexUsage, asOf: referenceNow),
        ])
        let model = shellModel(appState: appState, settingsStore: settingsStore)

        var draft = AppSettingsDraft.capture(from: model)
        draft.pollInterval = 600
        draft.thresholdPercent = 10
        draft.providerVisibility[.codex] = false
        draft.apply(to: model)

        #expect(model.pollInterval == 600)
        #expect(settingsStore.pollInterval == 600)
        #expect(model.thresholdPercent == 10)
        #expect(settingsStore.thresholdPercent == 10)
        #expect(!model.isProviderVisible(.codex))
        #expect(appState.providerState(for: .codex) == .hidden)
        #expect(model.isProviderVisible(.claude))
    }
}

@Test
@MainActor
func settingsDraftApplyDoesNotTouchUnchangedLaunchAtLogin() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let launchManager = RecordingLaunchAtLoginManager()
        let model = shellModel(settingsStore: settingsStore, launchAtLoginManager: launchManager)

        var draft = AppSettingsDraft.capture(from: model)
        draft.thresholdPercent += 5
        let attemptedLaunchChange = draft.apply(to: model)

        #expect(launchManager.requests.isEmpty)
        #expect(!attemptedLaunchChange)
    }
}

@Test
@MainActor
func settingsDraftApplyTogglesLaunchAtLoginWhenChanged() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let launchManager = RecordingLaunchAtLoginManager()
        let model = shellModel(settingsStore: settingsStore, launchAtLoginManager: launchManager)

        var draft = AppSettingsDraft.capture(from: model)
        draft.launchAtLoginEnabled = true
        let attemptedLaunchChange = draft.apply(to: model)

        #expect(attemptedLaunchChange)
        #expect(launchManager.requests == [true])
        #expect(model.launchAtLoginEnabled)
        #expect(settingsStore.launchAtLoginEnabled)
    }
}

@Test
@MainActor
func settingsDraftDiscardLeavesModelUnchanged() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let appState = AppState(providerStates: [
            .claude: .fresh(claudeUsage, asOf: referenceNow),
        ])
        let model = shellModel(appState: appState, settingsStore: settingsStore)

        var draft = AppSettingsDraft.capture(from: model)
        draft.pollInterval = 600
        draft.providerVisibility[.claude] = false
        // No apply(): Cancel discards the edits.

        #expect(model.pollInterval != 600)
        #expect(model.isProviderVisible(.claude))
        #expect(appState.providerState(for: .claude) == .fresh(claudeUsage, asOf: referenceNow))
    }
}

private let referenceNow = Date(timeIntervalSince1970: 1_767_268_800)

private let claudeUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 62, resetsAt: referenceNow.addingTimeInterval(2 * 60 * 60)),
    weekly: UsageWindow(percentRemaining: 81, resetsAt: referenceNow.addingTimeInterval(5 * 24 * 60 * 60))
)

private let codexUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
    weekly: UsageWindow(percentRemaining: 90, resetsAt: referenceNow.addingTimeInterval(6 * 24 * 60 * 60))
)

@MainActor
private func shellModel(
    appState: AppState = AppState(),
    settingsStore: SettingsStore = SettingsStore(defaults: .standard),
    usageController: any UsageControlling = RecordingUsageController(),
    launchAtLoginManager: any LaunchAtLoginManaging = RecordingLaunchAtLoginManager()
) -> UsageBarShellModel {
    UsageBarShellModel(
        appState: appState,
        settingsStore: settingsStore,
        usageController: usageController,
        launchAtLoginManager: launchAtLoginManager,
        now: { referenceNow }
    )
}

private actor RecordingUsageController: UsageControlling {
    private var refreshCalls = 0
    private var intervals: [TimeInterval] = []

    func start() async {}

    func stop() async {}

    func refreshNow() async {
        refreshCalls += 1
    }

    func setPollingInterval(_ interval: TimeInterval) async {
        intervals.append(interval)
    }

    func refreshCallCount() -> Int {
        refreshCalls
    }
}

private final class RecordingLaunchAtLoginManager: LaunchAtLoginManaging {
    private let error: (any Error)?
    private let statusAfterSet: LaunchAtLoginStatus?
    var requests: [Bool] = []
    var status: LaunchAtLoginStatus

    init(
        status: LaunchAtLoginStatus = .disabled,
        error: (any Error)? = nil,
        statusAfterSet: LaunchAtLoginStatus? = nil
    ) {
        self.status = status
        self.error = error
        self.statusAfterSet = statusAfterSet
    }

    func setEnabled(_ enabled: Bool) throws {
        if status == .requiresApproval, enabled {
            throw LaunchAtLoginError.requiresApproval
        }

        if let error {
            throw error
        }

        requests.append(enabled)
        if let statusAfterSet {
            status = statusAfterSet
        } else {
            status = enabled ? .enabled : .disabled
        }
    }
}

private enum LaunchAtLoginTestError: Error {
    case failed
}

private final class ObservationChangeRecorder: @unchecked Sendable {
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

private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "UsageBarShellModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    body(defaults)
}
