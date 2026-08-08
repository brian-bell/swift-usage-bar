import Foundation
import UsageCore

@testable import AIUsageBarApp

let uiTestNow = Date(timeIntervalSince1970: 1_767_268_800)

/// Legacy alias used by existing shell-model tests.
let referenceNow = uiTestNow

let uiTestClaudeUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 62, resetsAt: uiTestNow.addingTimeInterval(2 * 60 * 60)),
    weekly: UsageWindow(percentRemaining: 81, resetsAt: uiTestNow.addingTimeInterval(5 * 24 * 60 * 60))
)

let uiTestCodexUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
    weekly: UsageWindow(percentRemaining: 90, resetsAt: uiTestNow.addingTimeInterval(6 * 24 * 60 * 60))
)

let uiTestOpenCodeGoUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 88, resetsAt: uiTestNow.addingTimeInterval(3 * 60 * 60)),
    weekly: UsageWindow(percentRemaining: 74, resetsAt: uiTestNow.addingTimeInterval(4 * 24 * 60 * 60)),
    monthly: UsageWindow(percentRemaining: 92, resetsAt: uiTestNow.addingTimeInterval(20 * 24 * 60 * 60)),
    credits: CreditBalance(
        balanceUSD: 42.50,
        monthlyUsedUSD: 2.96,
        monthlyLimitUSD: 50
    )
)

let uiTestMiniMaxUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 76, resetsAt: uiTestNow.addingTimeInterval(2 * 60 * 60)),
    weekly: UsageWindow(percentRemaining: 55, resetsAt: uiTestNow.addingTimeInterval(5 * 24 * 60 * 60))
)

/// Legacy aliases used by existing shell-model tests.
let claudeUsage = uiTestClaudeUsage
let codexUsage = uiTestCodexUsage

func isolatedDefaults(suiteName: String = UUID().uuidString) -> UserDefaults {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suiteName = "UITestFixtures.\(UUID().uuidString)"
    let defaults = isolatedDefaults(suiteName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    try body(defaults)
}

@MainActor
func appState(_ states: [ProviderID: ProviderState]) -> AppState {
    AppState(providerStates: states)
}

@MainActor
func freshState(
    claude: ProviderUsage = uiTestClaudeUsage,
    codex: ProviderUsage = uiTestCodexUsage,
    asOf: Date = uiTestNow
) -> AppState {
    appState([
        .claude: .fresh(claude, asOf: asOf),
        .codex: .fresh(codex, asOf: asOf),
    ])
}

/// Claude + Codex live with ages suitable for "updated 2 min ago" status lines.
@MainActor
func liveProvidersState(
    asOf: Date = uiTestNow,
    lastSuccess: Date = uiTestNow.addingTimeInterval(-120)
) -> AppState {
    AppState(
        providerStates: [
            .claude: .fresh(uiTestClaudeUsage, asOf: asOf),
            .codex: .fresh(uiTestCodexUsage, asOf: asOf),
            .openCodeGo: .hidden,
            .miniMax: .hidden,
        ],
        lastSuccessfulRefreshes: [
            .claude: lastSuccess,
            .codex: lastSuccess,
        ],
        lastDataSources: [
            .claude: .claudeWebSession,
            .codex: .codexAPI,
        ]
    )
}

/// OpenCode Go visible and fresh (with credits), for the OpenCode-Go-only
/// hosted UI tests. Claude/Codex stay hidden so the rows don't drown the
/// credits row in noise.
@MainActor
func openCodeGoFreshState(
    asOf: Date = uiTestNow,
    lastSuccess: Date = uiTestNow.addingTimeInterval(-120)
) -> AppState {
    AppState(
        providerStates: [
            .openCodeGo: .fresh(uiTestOpenCodeGoUsage, asOf: asOf),
        ],
        lastSuccessfulRefreshes: [
            .openCodeGo: lastSuccess,
        ],
        lastDataSources: [
            .openCodeGo: .openCodeGoChromeCookie,
        ]
    )
}

/// Bounded poll for hosted UI tests. Runs on the test's background thread and
/// simply re-checks `condition` with a short sleep between attempts — the
/// hosted view's main run loop stays free, so SwiftUI state and AX updates
/// converge on their own. This is poll-until, not sleep-then-assert: tests
/// still fail immediately when the condition never holds.
func pollUntil(
    timeout: TimeInterval = 5,
    interval: TimeInterval = 0.01,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        Thread.sleep(forTimeInterval: interval)
    }
    return condition()
}

@MainActor
func staleState(
    provider: ProviderID,
    last: ProviderUsage?,
    reason: StaleReason,
    others: [ProviderID: ProviderState] = [:]
) -> AppState {
    var states = others
    states[provider] = .stale(last: last, reason: reason)
    return appState(states)
}

@MainActor
func shellModel(
    appState: AppState = AppState(),
    settingsStore: SettingsStore = SettingsStore(defaults: isolatedDefaults()),
    usageController: any UsageControlling = RecordingUsageController(),
    launchAtLoginManager: any LaunchAtLoginManaging = RecordingLaunchAtLoginManager(),
    now: @MainActor @escaping () -> Date = { uiTestNow }
) -> UsageBarShellModel {
    UsageBarShellModel(
        appState: appState,
        settingsStore: settingsStore,
        usageController: usageController,
        launchAtLoginManager: launchAtLoginManager,
        now: now
    )
}

actor RecordingUsageController: UsageControlling {
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

    func recordedIntervals() -> [TimeInterval] {
        intervals
    }
}

final class RecordingLaunchAtLoginManager: LaunchAtLoginManaging {
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

enum LaunchAtLoginTestError: Error {
    case failed
}

final class ObservationChangeRecorder: @unchecked Sendable {
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
