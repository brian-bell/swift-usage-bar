import Foundation
import Testing
import UsageCore

@testable import AIUsageBarApp

@Test
@MainActor
func shellModelMenuBarTitleUsesCoreFormatter() {
    let appState = AppState(providerStates: [
        .codex: .fresh(codexUsage, asOf: referenceNow),
        .claude: .fresh(claudeUsage, asOf: referenceNow),
    ])
    let model = shellModel(appState: appState)

    #expect(String(model.menuBarTitle.characters) == "* 62/81  # 72/90")
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

private let referenceNow = Date(timeIntervalSince1970: 1_767_268_800)

private let claudeUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 62, resetsAt: referenceNow.addingTimeInterval(2 * 60 * 60)),
    weekly: UsageWindow(percentRemaining: 81, resetsAt: referenceNow.addingTimeInterval(5 * 24 * 60 * 60))
)

private let codexUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 72, resetsAt: referenceNow.addingTimeInterval(3 * 60 * 60)),
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
    var requests: [Bool] = []
    var isEnabled = false

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func setEnabled(_ enabled: Bool) throws {
        if let error {
            throw error
        }

        requests.append(enabled)
        isEnabled = enabled
    }
}

private enum LaunchAtLoginTestError: Error {
    case failed
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
