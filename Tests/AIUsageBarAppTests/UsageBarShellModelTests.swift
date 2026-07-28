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

@Test
@MainActor
func openCodeGoWorkspaceEditIsStagedAndNormalizesOnlyOnApply() {
    withIsolatedDefaults { defaults in
        let settingsStore = SettingsStore(defaults: defaults)
        let model = shellModel(settingsStore: settingsStore)
        let id = "wrk_01KEXAMPLE123"

        var discardedDraft = AppSettingsDraft.capture(from: model)
        discardedDraft.openCodeGoWorkspace = "https://opencode.ai/workspace/\(id)/go"
        #expect(model.openCodeGoWorkspaceID == nil)
        #expect(settingsStore.openCodeGoWorkspaceID == nil)

        discardedDraft.apply(to: model)
        #expect(model.openCodeGoWorkspaceID == id)
        #expect(settingsStore.openCodeGoWorkspaceID == id)
    }
}

@Test
@MainActor
func shellModelExposesProviderStatusRowsForTheSettingsProvidersTab() throws {
    let appState = AppState(
        providerStates: [
            .claude: .fresh(claudeUsage, asOf: referenceNow),
            .codex: .stale(last: codexUsage, reason: .tokenExpired),
            .openCodeGo: .hidden,
        ],
        lastSuccessfulRefreshes: [
            .claude: referenceNow.addingTimeInterval(-120),
            .codex: referenceNow.addingTimeInterval(-3_600),
        ],
        lastDataSources: [.claude: .claudeWebSession, .codex: .codexAPI]
    )
    let model = shellModel(appState: appState)

    let rows = model.providerStatusViewModel.rows
    #expect(rows.map(\.provider) == ProviderID.allCases)
    #expect(try #require(rows.first { $0.provider == .claude }).text
        == "Live \u{00B7} claude.ai web session \u{00B7} updated 2 min ago")
    #expect(try #require(rows.first { $0.provider == .codex }).text
        == "Stale \u{00B7} Keychain token expired \u{00B7} last data 1 h ago")
    #expect(try #require(rows.first { $0.provider == .openCodeGo }).text == "Off")
}

@Test
@MainActor
func shellModelFeedsTheRetrievalChainsIntoTheProvidersTab() throws {
    let appState = AppState(
        providerStates: [.claude: .fresh(claudeUsage, asOf: referenceNow)],
        lastSuccessfulRefreshes: [.claude: referenceNow.addingTimeInterval(-120)],
        lastDataSources: [.claude: .claudeOAuthAPI],
        lastChains: [.claude: [
            ProviderDataSourceStep(.claudeWebSession, .failed(.sessionExpired)),
            ProviderDataSourceStep(.claudeOAuthAPI, .used),
        ]]
    )
    let model = shellModel(appState: appState)

    let chain = try #require(model.providerStatusViewModel.rows.first { $0.provider == .claude }).chain
    #expect(chain.steps.map(\.stateText) == [
        "Session expired \u{00B7} 2 min ago",
        "Used 2 min ago",
        "Standing by",
    ])
}

@Test
@MainActor
func shellModelFeedsTheStoredWorkspaceIDIntoTheOpenCodeGoDisclosure() throws {
    // The workspace field now lives inside OpenCode Go's disclosure, so its
    // caption has to know whether an ID has already been set.
    let defaults = try #require(UserDefaults(suiteName: "workspace-caption-\(UUID().uuidString)"))
    let settingsStore = SettingsStore(defaults: defaults)
    settingsStore.openCodeGoWorkspaceID = "wrk_abc123"
    settingsStore.setProvider(.openCodeGo, visible: true)
    let model = shellModel(
        appState: AppState(providerStates: [.openCodeGo: .fresh(claudeUsage, asOf: referenceNow)]),
        settingsStore: settingsStore
    )

    let chain = try #require(
        model.providerStatusViewModel.rows.first { $0.provider == .openCodeGo }
    ).chain
    #expect(chain.showsWorkspaceField)
    #expect(chain.workspaceCaption == "Using the workspace ID you set; discovery is skipped.")
}

@Test
@MainActor
func stagedVisibilityTurnsAProviderOffInTheProvidersTabBeforeOKIsPressed() throws {
    let appState = AppState(providerStates: [.claude: .fresh(claudeUsage, asOf: referenceNow)])
    let model = shellModel(appState: appState)

    let rows = model.providerStatusViewModel(stagedVisibility: [.claude: false]).rows
    let row = try #require(rows.first { $0.provider == .claude })
    #expect(row.stateLabel == "Off")
    #expect(row.chain.isOff)
    #expect(row.chain.steps.isEmpty)
}

@Test
@MainActor
func stagedVisibilityRevealsANewlyEnabledProvidersDisclosureBeforeItIsPolled() throws {
    // Enabling OpenCode Go and typing its workspace ID has to work in one visit,
    // and that field now lives inside the disclosure.
    let appState = AppState(providerStates: [.openCodeGo: .hidden])
    let model = shellModel(appState: appState)

    let rows = model.providerStatusViewModel(stagedVisibility: [.openCodeGo: true]).rows
    let row = try #require(rows.first { $0.provider == .openCodeGo })
    #expect(!row.chain.isOff)
    #expect(row.chain.showsWorkspaceField)
    #expect(row.chain.steps.map(\.stateText) == ["Standing by"])
}

@Test
@MainActor
func stagedVisibilityDoesNotResurrectTheChainRecordedBeforeAProviderWasTurnedOff() throws {
    // Turn a healthy provider off, then hours later turn it back on: nothing has
    // been fetched since, so the row reads `Checking…`. The disclosure below it
    // must agree — a retained green "Used 3 h ago" step would claim a source is
    // producing data right now, contradicting the line directly above it.
    try withIsolatedDefaults { defaults in
        let appState = AppState()
        let model = shellModel(appState: appState, settingsStore: SettingsStore(defaults: defaults))
        appState.applyRefreshResult(
            provider: .codex,
            state: .fresh(codexUsage, asOf: referenceNow.addingTimeInterval(-3 * 60 * 60)),
            completedAt: referenceNow.addingTimeInterval(-3 * 60 * 60),
            source: .codexAPI,
            chain: [ProviderDataSourceStep(.codexAPI, .used)]
        )

        model.setProvider(.codex, visible: false)

        let rows = model.providerStatusViewModel(stagedVisibility: [.codex: true]).rows
        let row = try #require(rows.first { $0.provider == .codex })
        #expect(row.indicator == .checking)
        #expect(row.stateLabel == "Checking\u{2026}")
        #expect(row.ageLabel == nil)
        #expect(row.text == "Checking\u{2026}")
        #expect(row.chain.steps.map(\.stateText) == ["Standing by", "Standing by"])
        #expect(row.chain.steps.map(\.indicator) == [nil, nil])
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

private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suiteName = "UsageBarShellModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    try body(defaults)
}
