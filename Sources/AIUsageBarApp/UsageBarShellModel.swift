import Foundation
import Observation
import UsageCore

protocol UsageControlling: Sendable {
    func start() async
    func stop() async
    func refreshNow() async
    func setPollingInterval(_ interval: TimeInterval) async
}

@MainActor
@Observable
final class UsageBarShellModel {
    let appState: AppState
    let settingsStore: SettingsStore
    private let usageController: any UsageControlling
    private let launchAtLoginManager: any LaunchAtLoginManaging
    private let now: @MainActor () -> Date

    private(set) var pollInterval: TimeInterval
    private(set) var thresholdPercent: Int
    private(set) var launchAtLoginEnabled: Bool
    private(set) var openCodeGoWorkspaceID: String?
    private var providerVisibility: [ProviderID: Bool]
    private var settingsOpener: (@MainActor () -> Void)?
    var launchAtLoginError: String?

    init(
        appState: AppState,
        settingsStore: SettingsStore,
        usageController: any UsageControlling,
        launchAtLoginManager: any LaunchAtLoginManaging,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.appState = appState
        self.settingsStore = settingsStore
        self.usageController = usageController
        self.launchAtLoginManager = launchAtLoginManager
        self.now = now
        self.pollInterval = settingsStore.pollInterval
        self.thresholdPercent = settingsStore.thresholdPercent
        self.launchAtLoginEnabled = launchAtLoginManager.status.isRegistered
        self.openCodeGoWorkspaceID = settingsStore.openCodeGoWorkspaceID
        self.providerVisibility = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { provider in
            (provider, settingsStore.isProviderVisible(provider))
        })
        applyStoredProviderVisibility()
        applyLaunchAtLoginStatus()
    }

    func start() async {
        await usageController.start()
    }

    func stop() async {
        await usageController.stop()
    }

    func refreshNow() async {
        await usageController.refreshNow()
    }

    /// Installs the action that opens the Settings window. The view layer wires this to
    /// the SwiftUI `openSettings` environment action once the scene is available.
    func setSettingsOpener(_ opener: @escaping @MainActor () -> Void) {
        settingsOpener = opener
    }

    /// User intent: bring up the Settings dialog. No-op until an opener is installed.
    func presentSettings() {
        settingsOpener?()
    }

    func setPollInterval(_ interval: TimeInterval) {
        pollInterval = interval
        settingsStore.pollInterval = interval
        Task {
            await usageController.setPollingInterval(interval)
        }
    }

    func isProviderVisible(_ provider: ProviderID) -> Bool {
        providerVisibility[provider] ?? true
    }

    func setProvider(_ provider: ProviderID, visible: Bool) {
        providerVisibility[provider] = visible
        settingsStore.setProvider(provider, visible: visible)
        appState.setProvider(provider, visible: visible)
    }

    func setThresholdPercent(_ thresholdPercent: Int) {
        self.thresholdPercent = thresholdPercent
        settingsStore.thresholdPercent = thresholdPercent
    }

    func setOpenCodeGoWorkspace(_ rawValue: String?) {
        let normalized = OpenCodeGoWorkspace.normalizedID(from: rawValue)
        openCodeGoWorkspaceID = normalized
        settingsStore.openCodeGoWorkspaceID = normalized
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try launchAtLoginManager.setEnabled(enabled)
            applyLaunchAtLoginStatus()
        } catch LaunchAtLoginError.requiresApproval {
            applyLaunchAtLoginStatus()
        } catch {
            launchAtLoginError = "Launch at login could not be updated."
        }
    }

    private func applyLaunchAtLoginStatus() {
        let status = launchAtLoginManager.status
        launchAtLoginEnabled = status.isRegistered
        settingsStore.launchAtLoginEnabled = status.isRegistered
        launchAtLoginError = status == .requiresApproval ? "Approve launch at login in System Settings." : nil
    }

    private func applyStoredProviderVisibility() {
        for (provider, visible) in providerVisibility where !visible {
            appState.setProvider(provider, visible: false)
        }
    }

    private func lastUpdatedDates() -> [ProviderID: Date] {
        Dictionary(uniqueKeysWithValues: ProviderID.allCases.compactMap { provider in
            guard let updatedAt = appState.lastUpdated(provider: provider) else {
                return nil
            }

            return (provider, updatedAt)
        })
    }
}

extension UsageBarShellModel {
    var menuBarSegments: [MenuBarTitleSegment] {
        MenuBarTitleFormatter.segments(appState.states)
    }

    var dropdownViewModel: DropdownViewModel {
        DropdownViewModel(
            states: appState.states,
            lastUpdatedAt: lastUpdatedDates(),
            now: now()
        )
    }
}

struct UsagePollerController: UsageControlling {
    let poller: UsagePoller

    func start() async {
        await poller.start()
    }

    func stop() async {
        await poller.stop()
    }

    func refreshNow() async {
        await poller.refreshNow()
    }

    func setPollingInterval(_ interval: TimeInterval) async {
        await poller.setPollingInterval(interval)
    }
}

extension UsageBarShellModel {
    static func live() -> UsageBarShellModel {
        let settingsStore = SettingsStore()
        let appState = AppState()
        let providers = liveProviders(settingsStore: settingsStore)
        let notifier = ThresholdNotifier(sender: UserNotificationSender())
        let poller = UsagePoller(
            providers: providers,
            appState: appState,
            interval: settingsStore.pollInterval,
            wakeEvents: { WorkspaceWakeEvents.stream() },
            thresholdNotifier: notifier,
            thresholdProvider: { settingsStore.thresholdPercent }
        )

        return UsageBarShellModel(
            appState: appState,
            settingsStore: settingsStore,
            usageController: UsagePollerController(poller: poller),
            launchAtLoginManager: SystemLaunchAtLoginManager()
        )
    }

    private static func liveProviders(settingsStore: SettingsStore) -> [ProviderID: any UsageProvider] {
        [
            .claude: ClaudeUsageProvider(
                credentialReader: ClaudeCredentialReader(
                    store: KeychainCredentialStore(),
                    fallbackStore: ClaudeCredentialsFileStore()
                ),
                cacheReader: ClaudeStatuslineCacheReader(
                    cacheURL: claudeStatuslineCacheURL(),
                    maximumAge: UsagePoller.defaultInterval * 3
                )
            ),
            .codex: CodexUsageProvider(
                credentialReader: CodexCredentialReader(store: KeychainCredentialStore())
            ),
            .openCodeGo: OpenCodeGoProvider(
                sessionReader: ChromeOpenCodeSessionReader(),
                transport: OpenCodeGoHTTPTransport(),
                workspaceOverride: { settingsStore.openCodeGoWorkspaceID }
            ),
        ]
    }

    private static func claudeStatuslineCacheURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["AI_USAGE_BAR_CLAUDE_STATUS_JSON"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let cacheRoot: URL
        if let xdgCacheHome = environment["XDG_CACHE_HOME"], !xdgCacheHome.isEmpty {
            cacheRoot = URL(fileURLWithPath: xdgCacheHome, isDirectory: true)
        } else {
            cacheRoot = homeDirectory.appendingPathComponent(".cache", isDirectory: true)
        }

        return cacheRoot
            .appendingPathComponent("ai-usage-bar", isDirectory: true)
            .appendingPathComponent("claude-status.json")
    }
}
