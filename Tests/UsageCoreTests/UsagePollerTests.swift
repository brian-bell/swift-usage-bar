import Foundation
import Testing
import UsageCore

@Test
func usagePollerFetchesImmediatelyAndRepeatsOnDefaultInterval() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 1_000))
    let appState = await AppState()
    let claude = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 900))])
    let codex = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 901))])
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await codex.waitForFetchCount(1)
    await poller.waitUntilIdle()
    await clock.waitForSleepRegistrationCount(1)

    await clock.advance(by: 120)
    await claude.waitForFetchCount(2)
    await codex.waitForFetchCount(2)
    await poller.waitUntilIdle()

    await poller.stop()
}

@Test
func usagePollerUsesBackgroundModeForAutomaticPollsAndInteractiveForManualRefresh() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 1_000))
    let appState = await AppState()
    let provider = ModeRecordingUsageProvider(
        result: .fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 900))
    )
    let poller = UsagePoller(
        providers: [.claude: provider],
        appState: appState,
        clock: clock
    )

    await poller.start()
    await provider.waitForFetchCount(1)
    await poller.waitUntilIdle()
    #expect(await provider.recordedModes() == [.background])

    await poller.refreshNow()
    await provider.waitForFetchCount(2)
    await poller.waitUntilIdle()
    #expect(await provider.recordedModes() == [.background, .interactive])

    await clock.waitForSleepRegistrationCount(1)
    await clock.advance(by: 120)
    await provider.waitForFetchCount(3)
    await poller.waitUntilIdle()
    #expect(await provider.recordedModes() == [.background, .interactive, .background])

    await poller.stop()
}

@Test
func usagePollerReschedulesWhenIntervalChanges() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 2_000))
    let appState = await AppState()
    let claude = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 1_900))])
    let codex = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 1_901))])
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await poller.waitUntilIdle()
    await clock.waitForSleepRegistrationCount(1)
    await clock.advance(by: 30)
    await poller.setPollingInterval(10)
    await clock.waitForSleepRegistrationCount(2)
    await clock.advance(by: 9)
    await Task.yield()

    #expect(await claude.fetchCount == 1)

    await clock.advance(by: 1)
    await claude.waitForFetchCount(2)
    await poller.waitUntilIdle()
    await clock.waitForSleepRegistrationCount(3)
    await clock.advance(by: 80)
    await claude.waitForFetchCount(3)
    await poller.waitUntilIdle()
    await Task.yield()

    #expect(await claude.fetchCount == 3)

    await poller.stop()
}

@Test
func usagePollerClampsNonPositiveIntervalsToPositiveDelay() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 2_500))
    let appState = await AppState()
    let claude = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 2_400))])
    let codex = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 2_401))])
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock,
        interval: 0
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await poller.waitUntilIdle()
    await clock.waitForSleepRegistrationCount(1)
    await clock.advance(by: 0)
    await Task.yield()

    #expect(await claude.fetchCount == 1)

    await clock.advance(by: 1)
    await claude.waitForFetchCount(2)
    await poller.waitUntilIdle()
    await poller.setPollingInterval(-10)
    await clock.waitForSleepRegistrationCount(3)
    await clock.advance(by: 0)
    await Task.yield()

    #expect(await claude.fetchCount == 2)

    await clock.advance(by: 1)
    await claude.waitForFetchCount(3)
    await poller.waitUntilIdle()

    await poller.stop()
}

@Test
func usagePollerFetchesProvidersConcurrently() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 3_000))
    let appState = await AppState()
    let claude = BlockingUsageProvider(result: .fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 2_900)))
    let codex = BlockingUsageProvider(result: .fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 2_901)))
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock
    )

    await poller.start()
    await claude.waitUntilStarted()
    await codex.waitUntilStarted()

    #expect(await claude.isSuspendedInFetch)
    #expect(await codex.isSuspendedInFetch)

    await claude.release()
    await codex.release()
    await claude.waitUntilFinished()
    await codex.waitUntilFinished()
    await poller.waitUntilIdle()

    await poller.stop()
}

@Test
func usagePollerAppliesSuccessfulProviderWhenOtherProviderIsStale() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 4_000))
    let appState = await AppState()
    let freshUsage = sampleUsage(fiveHour: 72, weekly: 90)
    let claude = RecordingUsageProvider(results: [.stale(last: nil, reason: .networkError)])
    let codex = RecordingUsageProvider(results: [.fresh(freshUsage, asOf: Date(timeIntervalSince1970: 3_901))])
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await codex.waitForFetchCount(1)
    await poller.waitUntilIdle()

    #expect(await appState.providerState(for: .claude) == .stale(last: nil, reason: .networkError))
    #expect(await appState.providerState(for: .codex) == .fresh(freshUsage, asOf: Date(timeIntervalSince1970: 3_901)))

    await poller.stop()
}

@Test
func usagePollerSendsThresholdNotificationForFreshCrossing() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 4_200))
    let previousUsage = sampleUsage(fiveHour: 25, weekly: 81)
    let appState = await AppState(providerStates: [.claude: .fresh(previousUsage, asOf: Date(timeIntervalSince1970: 4_100))])
    let sender = RecordingThresholdNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let currentUsage = sampleUsage(fiveHour: 18, weekly: 81)
    let claude = RecordingUsageProvider(results: [.fresh(currentUsage, asOf: Date(timeIntervalSince1970: 4_150))])
    let poller = UsagePoller(
        providers: [.claude: claude],
        appState: appState,
        clock: clock,
        thresholdNotifier: notifier
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await poller.waitUntilIdle()

    #expect(await sender.sentNotifications() == [
        UsageThresholdNotification(
            provider: .claude,
            window: .fiveHour,
            percentRemaining: 18,
            threshold: 20,
            resetsAt: currentUsage.fiveHour.resetsAt
        ),
    ])

    await poller.stop()
}

@Test
func usagePollerUsesPreviousUsageCapturedBeforeFetchForNotificationCrossing() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 4_300))
    let previousUsage = sampleUsage(fiveHour: 25, weekly: 81)
    let appState = await AppState(providerStates: [.claude: .fresh(previousUsage, asOf: Date(timeIntervalSince1970: 4_200))])
    let sender = RecordingThresholdNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let currentUsage = sampleUsage(fiveHour: 18, weekly: 81)
    let claude = PreviousRecordingUsageProvider(result: .fresh(currentUsage, asOf: Date(timeIntervalSince1970: 4_250)))
    let poller = UsagePoller(
        providers: [.claude: claude],
        appState: appState,
        clock: clock,
        thresholdNotifier: notifier
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await poller.waitUntilIdle()

    #expect(await claude.previousUsages() == [previousUsage])
    #expect(await sender.sentNotifications().count == 1)

    await poller.stop()
}

@Test
func usagePollerDoesNotNotifyForStaleResults() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 4_400))
    let previousUsage = sampleUsage(fiveHour: 25, weekly: 81)
    let appState = await AppState(providerStates: [.claude: .fresh(previousUsage, asOf: Date(timeIntervalSince1970: 4_300))])
    let sender = RecordingThresholdNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let claude = RecordingUsageProvider(results: [.stale(last: sampleUsage(fiveHour: 18, weekly: 81), reason: .networkError)])
    let poller = UsagePoller(
        providers: [.claude: claude],
        appState: appState,
        clock: clock,
        thresholdNotifier: notifier
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await poller.waitUntilIdle()

    #expect(await sender.sentNotifications().isEmpty)

    await poller.stop()
}

@Test
func usagePollerReadsInjectedThresholdProviderDuringEvaluation() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 4_450))
    let previousUsage = sampleUsage(fiveHour: 35, weekly: 81)
    let appState = await AppState(providerStates: [.claude: .fresh(previousUsage, asOf: Date(timeIntervalSince1970: 4_350))])
    let sender = RecordingThresholdNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let currentUsage = sampleUsage(fiveHour: 25, weekly: 81)
    let claude = RecordingUsageProvider(results: [.fresh(currentUsage, asOf: Date(timeIntervalSince1970: 4_400))])
    let poller = UsagePoller(
        providers: [.claude: claude],
        appState: appState,
        clock: clock,
        thresholdNotifier: notifier,
        thresholdProvider: { 30 }
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await poller.waitUntilIdle()

    #expect(await sender.sentNotifications() == [
        UsageThresholdNotification(
            provider: .claude,
            window: .fiveHour,
            percentRemaining: 25,
            threshold: 30,
            resetsAt: currentUsage.fiveHour.resetsAt
        ),
    ])

    await poller.stop()
}

@Test
func usagePollerDoesNotEvaluateNotificationsForHiddenProviders() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 4_500))
    let appState = await AppState(providerStates: [.claude: .hidden])
    let sender = RecordingThresholdNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let claude = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 18, weekly: 81), asOf: Date(timeIntervalSince1970: 4_450))])
    let poller = UsagePoller(
        providers: [.claude: claude],
        appState: appState,
        clock: clock,
        thresholdNotifier: notifier
    )

    await poller.start()
    await poller.waitUntilIdle()

    #expect(await claude.fetchCount == 0)
    #expect(await sender.sentNotifications().isEmpty)

    await poller.stop()
}

@Test
func usagePollerDoesNotNotifyForDiscardedInFlightResults() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 4_600))
    let previousUsage = sampleUsage(fiveHour: 25, weekly: 81)
    let appState = await AppState(providerStates: [.claude: .fresh(previousUsage, asOf: Date(timeIntervalSince1970: 4_500))])
    let sender = RecordingThresholdNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let claude = BlockingUsageProvider(result: .fresh(sampleUsage(fiveHour: 18, weekly: 81), asOf: Date(timeIntervalSince1970: 4_550)))
    let poller = UsagePoller(
        providers: [.claude: claude],
        appState: appState,
        clock: clock,
        thresholdNotifier: notifier
    )

    await poller.start()
    await claude.waitUntilStarted()
    await poller.stop()
    await claude.release()
    await claude.waitUntilFinished()
    await Task.yield()

    #expect(await sender.sentNotifications().isEmpty)
}

@Test
func usagePollerDoesNotNotifyWhenStoppedDuringThresholdLookup() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 4_700))
    let previousUsage = sampleUsage(fiveHour: 25, weekly: 81)
    let appState = await AppState(providerStates: [.claude: .fresh(previousUsage, asOf: Date(timeIntervalSince1970: 4_600))])
    let sender = RecordingThresholdNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let thresholdProvider = SuspendingThresholdProvider(threshold: 20)
    let claude = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 18, weekly: 81), asOf: Date(timeIntervalSince1970: 4_650))])
    let poller = UsagePoller(
        providers: [.claude: claude],
        appState: appState,
        clock: clock,
        thresholdNotifier: notifier,
        thresholdProvider: {
            await thresholdProvider.threshold()
        }
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await thresholdProvider.waitForRequestCount(1)
    await poller.stop()
    await thresholdProvider.releaseAll()
    await poller.start()
    await claude.waitForFetchCount(2)
    await poller.waitUntilIdle()
    await poller.stop()

    #expect(await sender.sentNotifications().isEmpty)
}

@Test
func usagePollerAppliesOtherProviderResultsWhileThresholdLookupIsSuspended() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 4_800))
    let previousClaudeUsage = sampleUsage(fiveHour: 25, weekly: 81)
    let previousCodexUsage = sampleUsage(fiveHour: 70, weekly: 91)
    let currentClaudeUsage = sampleUsage(fiveHour: 18, weekly: 81)
    let currentCodexUsage = sampleUsage(fiveHour: 66, weekly: 91)
    let appState = await AppState(providerStates: [
        .claude: .fresh(previousClaudeUsage, asOf: Date(timeIntervalSince1970: 4_700)),
        .codex: .fresh(previousCodexUsage, asOf: Date(timeIntervalSince1970: 4_701)),
    ])
    let sender = RecordingThresholdNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let thresholdProvider = SuspendingThresholdProvider(threshold: 20)
    let claude = RecordingUsageProvider(results: [.fresh(currentClaudeUsage, asOf: Date(timeIntervalSince1970: 4_750))])
    let codex = BlockingUsageProvider(result: .fresh(currentCodexUsage, asOf: Date(timeIntervalSince1970: 4_751)))
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock,
        thresholdNotifier: notifier,
        thresholdProvider: {
            await thresholdProvider.threshold()
        }
    )

    await poller.start()
    await thresholdProvider.waitForRequestCount(1)
    await codex.release()
    await codex.waitUntilFinished()
    await waitForProviderState(
        appState,
        provider: .codex,
        state: .fresh(currentCodexUsage, asOf: Date(timeIntervalSince1970: 4_751))
    )

    #expect(await appState.providerState(for: .codex) == .fresh(currentCodexUsage, asOf: Date(timeIntervalSince1970: 4_751)))

    await thresholdProvider.releaseAll()
    await poller.waitUntilIdle()
    await poller.stop()
}

@Test
func usagePollerSkipsSupersededThresholdEvaluation() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 4_900))
    let previousUsage = sampleUsage(fiveHour: 25, weekly: 81)
    let crossingUsage = sampleUsage(fiveHour: 18, weekly: 81)
    let recoveredUsage = sampleUsage(fiveHour: 50, weekly: 81)
    let appState = await AppState(providerStates: [
        .claude: .fresh(previousUsage, asOf: Date(timeIntervalSince1970: 4_800)),
    ])
    let sender = RecordingThresholdNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let thresholdProvider = SuspendingThresholdProvider(threshold: 20)
    let claude = RecordingUsageProvider(results: [
        .fresh(crossingUsage, asOf: Date(timeIntervalSince1970: 4_850)),
        .fresh(recoveredUsage, asOf: Date(timeIntervalSince1970: 4_851)),
    ])
    let poller = UsagePoller(
        providers: [.claude: claude],
        appState: appState,
        clock: clock,
        thresholdNotifier: notifier,
        thresholdProvider: {
            await thresholdProvider.threshold()
        }
    )

    await poller.start()
    await thresholdProvider.waitForRequestCount(1)
    await poller.refreshNow()
    await claude.waitForFetchCount(2)
    await thresholdProvider.waitForRequestCount(2)
    await thresholdProvider.releaseAll()
    await poller.waitUntilIdle()

    #expect(await sender.sentNotifications().isEmpty)

    await poller.stop()
}

@Test
func usagePollerSendsWhenSupersededThresholdEvaluationIsStillBelowThreshold() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 4_950))
    let previousUsage = sampleUsage(fiveHour: 25, weekly: 81)
    let crossingUsage = sampleUsage(fiveHour: 18, weekly: 81)
    let stillBelowUsage = sampleUsage(fiveHour: 17, weekly: 81)
    let appState = await AppState(providerStates: [
        .claude: .fresh(previousUsage, asOf: Date(timeIntervalSince1970: 4_900)),
    ])
    let sender = RecordingThresholdNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let thresholdProvider = SuspendingThresholdProvider(threshold: 20)
    let claude = RecordingUsageProvider(results: [
        .fresh(crossingUsage, asOf: Date(timeIntervalSince1970: 4_901)),
        .fresh(stillBelowUsage, asOf: Date(timeIntervalSince1970: 4_902)),
    ])
    let poller = UsagePoller(
        providers: [.claude: claude],
        appState: appState,
        clock: clock,
        thresholdNotifier: notifier,
        thresholdProvider: {
            await thresholdProvider.threshold()
        }
    )

    await poller.start()
    await thresholdProvider.waitForRequestCount(1)
    await poller.refreshNow()
    await claude.waitForFetchCount(2)
    await thresholdProvider.waitForRequestCount(2)
    await thresholdProvider.releaseAll()
    await poller.waitUntilIdle()

    #expect(await sender.sentNotifications() == [
        UsageThresholdNotification(
            provider: .claude,
            window: .fiveHour,
            percentRemaining: 17,
            threshold: 20,
            resetsAt: stillBelowUsage.fiveHour.resetsAt
        ),
    ])

    await poller.stop()
}

@Test
func usagePollerSendsWhenSupersededByStaleRefreshPreservingLastUsage() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 4_975))
    let previousUsage = sampleUsage(fiveHour: 25, weekly: 81)
    let crossingUsage = sampleUsage(fiveHour: 18, weekly: 81)
    let appState = await AppState(providerStates: [
        .claude: .fresh(previousUsage, asOf: Date(timeIntervalSince1970: 4_950)),
    ])
    let sender = RecordingThresholdNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let thresholdProvider = SuspendingThresholdProvider(threshold: 20)
    let claude = RecordingUsageProvider(results: [
        .fresh(crossingUsage, asOf: Date(timeIntervalSince1970: 4_951)),
        .stale(last: nil, reason: .networkError),
    ])
    let poller = UsagePoller(
        providers: [.claude: claude],
        appState: appState,
        clock: clock,
        thresholdNotifier: notifier,
        thresholdProvider: {
            await thresholdProvider.threshold()
        }
    )

    await poller.start()
    await thresholdProvider.waitForRequestCount(1)
    await poller.refreshNow()
    await claude.waitForFetchCount(2)
    await thresholdProvider.releaseAll()
    await poller.waitUntilIdle()

    #expect(await sender.sentNotifications() == [
        UsageThresholdNotification(
            provider: .claude,
            window: .fiveHour,
            percentRemaining: 18,
            threshold: 20,
            resetsAt: crossingUsage.fiveHour.resetsAt
        ),
    ])

    await poller.stop()
}

@Test
func usagePollerStopPreventsLaterTimerFetches() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 5_000))
    let appState = await AppState()
    let claude = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 4_900))])
    let codex = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 4_901))])
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await poller.waitUntilIdle()
    await clock.waitForSleepRegistrationCount(1)
    await poller.stop()
    await clock.advance(by: 120)
    await Task.yield()

    #expect(await claude.fetchCount == 1)
    #expect(await codex.fetchCount == 1)
}

@Test
func usagePollerStopPreventsInFlightResultsFromUpdatingState() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 5_500))
    let appState = await AppState()
    let claudeUsage = sampleUsage(fiveHour: 62, weekly: 81)
    let codex = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 5_401))])
    let claude = BlockingUsageProvider(result: .fresh(claudeUsage, asOf: Date(timeIntervalSince1970: 5_400)))
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock
    )

    await poller.start()
    await claude.waitUntilStarted()
    await poller.stop()
    await claude.release()
    await claude.waitUntilFinished()
    await Task.yield()

    #expect(await appState.providerState(for: .claude) == nil)
    #expect(await appState.lastUpdated(provider: .claude) == nil)
}

@Test
func usagePollerStopBeforeFetchPreventsProviderWorkAndAttemptMetadata() async {
    let clock = SuspendingNowClock(now: Date(timeIntervalSince1970: 5_650))
    let appState = await AppState()
    let claude = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 5_600))])
    let codex = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 5_601))])
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock
    )

    await poller.start()
    await clock.waitForNowRequestCount(2)
    await poller.stop()
    await clock.releaseAll()
    await Task.yield()

    #expect(await claude.fetchCount == 0)
    #expect(await codex.fetchCount == 0)
    #expect(await appState.lastAttemptedRefresh(provider: .claude) == nil)
    #expect(await appState.lastAttemptedRefresh(provider: .codex) == nil)
}

@Test
func appStatePreservesHiddenProviderWhenRefreshResultArrives() async {
    let appState = await AppState(providerStates: [.claude: .hidden])
    let usage = sampleUsage(fiveHour: 62, weekly: 81)

    await appState.applyRefreshResult(
        provider: .claude,
        state: .fresh(usage, asOf: Date(timeIntervalSince1970: 5_801)),
        completedAt: Date(timeIntervalSince1970: 5_900)
    )

    #expect(await appState.providerState(for: .claude) == .hidden)
    #expect(await appState.lastUpdated(provider: .claude) == nil)
}

@Test
func appStateRestoresPreviousProviderStateAfterHideShow() async {
    let usage = sampleUsage(fiveHour: 62, weekly: 81)
    let state = ProviderState.fresh(usage, asOf: Date(timeIntervalSince1970: 5_800))
    let appState = await AppState(providerStates: [.claude: state])

    await appState.setProvider(.claude, visible: false)

    #expect(await appState.providerState(for: .claude) == .hidden)
    #expect(await appState.previousUsage(provider: .claude) == usage)

    await appState.setProvider(.claude, visible: true)

    #expect(await appState.providerState(for: .claude) == state)
    #expect(await appState.previousUsage(provider: .claude) == usage)
}

@Test
func appStateUsesPreservedUsageForStaleFallbackAfterHideShow() async {
    let usage = sampleUsage(fiveHour: 62, weekly: 81)
    let appState = await AppState(providerStates: [
        .claude: .fresh(usage, asOf: Date(timeIntervalSince1970: 5_800)),
    ])

    await appState.setProvider(.claude, visible: false)
    await appState.setProvider(.claude, visible: true)
    await appState.applyRefreshResult(
        provider: .claude,
        state: .stale(last: nil, reason: .networkError),
        completedAt: Date(timeIntervalSince1970: 5_900)
    )

    #expect(await appState.providerState(for: .claude) == .stale(last: usage, reason: .networkError))
}

@Test
func appStateApplyHiddenResultMarksProviderHiddenForFutureRefreshes() async {
    let usage = sampleUsage(fiveHour: 62, weekly: 81)
    let appState = await AppState(providerStates: [
        .claude: .fresh(usage, asOf: Date(timeIntervalSince1970: 5_800)),
    ])

    await appState.applyRefreshResult(
        provider: .claude,
        state: .hidden,
        completedAt: Date(timeIntervalSince1970: 5_900)
    )
    await appState.applyRefreshResult(
        provider: .claude,
        state: .fresh(usage, asOf: Date(timeIntervalSince1970: 5_901)),
        completedAt: Date(timeIntervalSince1970: 5_901)
    )

    #expect(await appState.isHidden(provider: .claude))
    #expect(await appState.providerState(for: .claude) == .hidden)
    #expect(await appState.previousUsage(provider: .claude) == nil)
}

@Test
func appStateSkipsGuardedRefreshResultWhenGenerationIsStale() async {
    let appState = await AppState()
    let usage = sampleUsage(fiveHour: 62, weekly: 81)

    await appState.recordRefreshAttemptAndApplyResult(
        provider: .claude,
        attemptedAt: Date(timeIntervalSince1970: 5_925),
        state: .fresh(usage, asOf: Date(timeIntervalSince1970: 5_901)),
        completedAt: Date(timeIntervalSince1970: 5_950),
        shouldApply: { false }
    )

    #expect(await appState.providerState(for: .claude) == nil)
    #expect(await appState.lastAttemptedRefresh(provider: .claude) == nil)
    #expect(await appState.lastUpdated(provider: .claude) == nil)
}

@Test
func usagePollerSkipsHiddenProviders() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 5_950))
    let appState = await AppState(providerStates: [.claude: .hidden])
    let codexUsage = sampleUsage(fiveHour: 72, weekly: 90)
    let claude = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 5_900))])
    let codex = RecordingUsageProvider(results: [.fresh(codexUsage, asOf: Date(timeIntervalSince1970: 5_901))])
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock
    )

    await poller.start()
    await codex.waitForFetchCount(1)
    await poller.waitUntilIdle()

    #expect(await claude.fetchCount == 0)
    #expect(await appState.providerState(for: .claude) == .hidden)
    #expect(await appState.lastAttemptedRefresh(provider: .claude) == nil)
    #expect(await appState.providerState(for: .codex) == .fresh(codexUsage, asOf: Date(timeIntervalSince1970: 5_901)))

    await poller.stop()
}

@Test
func stalePollChainDoesNotMarkRestartedPollerIdle() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 5_750))
    let appState = await AppState()
    let claude = BlockingUsageProvider(result: .fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 5_700)))
    let codex = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 5_701))])
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock
    )

    await poller.start()
    await claude.waitForStartCount(1)
    await poller.stop()

    await poller.start()
    await claude.waitForStartCount(2)
    await claude.release()
    await claude.waitForFinishCount(1)
    await Task.yield()

    await poller.refreshNow()
    await Task.yield()

    #expect(await claude.startCount == 2)

    await claude.release()
    await claude.waitForFinishCount(2)
    await claude.waitForStartCount(3)
    await claude.release()
    await claude.waitForFinishCount(3)
    await poller.waitUntilIdle()
    await poller.stop()
}

@Test
func refreshNowFetchesImmediatelyAndResetsTimerPhase() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 6_000))
    let appState = await AppState()
    let claude = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 5_900))])
    let codex = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 5_901))])
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await poller.waitUntilIdle()
    await clock.waitForSleepRegistrationCount(1)
    await clock.advance(by: 30)
    await poller.refreshNow()
    await claude.waitForFetchCount(2)
    await poller.waitUntilIdle()
    await clock.waitForSleepRegistrationCount(2)
    await clock.advance(by: 119)
    await Task.yield()

    #expect(await claude.fetchCount == 2)

    await clock.advance(by: 1)
    await claude.waitForFetchCount(3)
    await poller.waitUntilIdle()

    await poller.stop()
}

@Test
func appStateLastUpdatedUsesSuccessfulRefreshCompletionTime() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 7_000))
    let appState = await AppState()
    let claudeUsage = sampleUsage(fiveHour: 62, weekly: 81)
    let claude = RecordingUsageProvider(results: [
        .fresh(claudeUsage, asOf: Date(timeIntervalSince1970: 6_900)),
        .stale(last: nil, reason: .networkError),
    ])
    let codex = RecordingUsageProvider(results: [
        .stale(last: nil, reason: .networkError),
        .fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 6_901)),
    ])
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await poller.waitUntilIdle()
    await clock.waitForSleepRegistrationCount(1)

    #expect(await appState.lastUpdated(provider: .claude) == Date(timeIntervalSince1970: 7_000))
    #expect(await appState.lastUpdated(provider: .codex) == nil)
    #expect(await appState.lastAttemptedRefresh(provider: .claude) == Date(timeIntervalSince1970: 7_000))

    await clock.advance(by: 20)
    await poller.refreshNow()
    await claude.waitForFetchCount(2)
    await codex.waitForFetchCount(2)
    await poller.waitUntilIdle()

    #expect(await appState.lastUpdated(provider: .claude) == Date(timeIntervalSince1970: 7_000))
    #expect(await appState.lastUpdated(provider: .codex) == Date(timeIntervalSince1970: 7_020))
    #expect(await appState.lastAttemptedRefresh(provider: .claude) == Date(timeIntervalSince1970: 7_020))
    #expect(await appState.providerState(for: .claude) == .stale(last: claudeUsage, reason: .networkError))

    await poller.stop()
}

@Test
func wakeEventTriggersImmediatePollAndResetsTimer() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 8_000))
    let appState = await AppState()
    let claude = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 7_900))])
    let codex = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 7_901))])
    let wakeEvents = WakeEventProbe()
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock,
        wakeEvents: { wakeEvents.stream }
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await poller.waitUntilIdle()
    await clock.waitForSleepRegistrationCount(1)
    await clock.advance(by: 30)
    wakeEvents.send()
    await claude.waitForFetchCount(2)
    await poller.waitUntilIdle()
    await clock.waitForSleepRegistrationCount(2)
    await clock.advance(by: 119)
    await Task.yield()

    #expect(await claude.fetchCount == 2)

    await clock.advance(by: 1)
    await claude.waitForFetchCount(3)
    await poller.waitUntilIdle()

    await poller.stop()
}

@Test
func wakeEventsRemainActiveAfterRestart() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 8_500))
    let appState = await AppState()
    let claude = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 8_400))])
    let codex = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 8_401))])
    let wakeEvents = RestartableWakeEventProbe()
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock,
        wakeEvents: wakeEvents.stream
    )

    await poller.start()
    await claude.waitForFetchCount(1)
    await poller.waitUntilIdle()
    await poller.stop()

    await poller.start()
    await claude.waitForFetchCount(2)
    await poller.waitUntilIdle()
    wakeEvents.send()
    await claude.waitForFetchCount(3)
    await poller.waitUntilIdle()

    await poller.stop()
}

@Test
func overlappingManualAndWakeRefreshesCoalesceIntoOneFollowUpPoll() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 9_000))
    let appState = await AppState()
    let claude = BlockingUsageProvider(result: .fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 8_900)))
    let codex = RecordingUsageProvider(results: [.fresh(sampleUsage(fiveHour: 72, weekly: 90), asOf: Date(timeIntervalSince1970: 8_901))])
    let wakeEvents = WakeEventProbe()
    let poller = UsagePoller(
        providers: [.claude: claude, .codex: codex],
        appState: appState,
        clock: clock,
        wakeEvents: { wakeEvents.stream }
    )

    await poller.start()
    await claude.waitUntilStarted()
    await poller.refreshNow()
    wakeEvents.send()
    await claude.release()
    await claude.waitUntilFinished()
    await claude.waitForStartCount(2)
    await claude.release()
    await claude.waitForFinishCount(2)
    await poller.waitUntilIdle()

    #expect(await claude.startCount == 2)

    await poller.stop()
}

@Test
func stopDiscardsQueuedInteractiveModeSoCoalescedPollsAfterRestartStayBackground() async {
    let clock = ManualUsageClock(now: Date(timeIntervalSince1970: 9_500))
    let appState = await AppState()
    let claude = BlockingUsageProvider(result: .fresh(sampleUsage(fiveHour: 62, weekly: 81), asOf: Date(timeIntervalSince1970: 9_400)))
    let wakeEvents = RestartableWakeEventProbe()
    let poller = UsagePoller(
        providers: [.claude: claude],
        appState: appState,
        clock: clock,
        wakeEvents: wakeEvents.stream
    )

    // A manual refresh coalesces onto the in-flight first poll, queueing an
    // interactive follow-up; stop() must discard that queued mode along with
    // the pending poll it belonged to.
    await poller.start()
    await claude.waitUntilStarted()
    await poller.refreshNow()
    await poller.stop()
    await claude.release()
    await claude.waitUntilFinished()

    // After a restart, a wake event coalescing onto the in-flight poll is
    // automatic and must not inherit the discarded interactive mode.
    await poller.start()
    await claude.waitForStartCount(2)
    wakeEvents.send()
    await claude.release()
    await claude.waitForFinishCount(2)
    await claude.waitForStartCount(3)
    await claude.release()
    await claude.waitForFinishCount(3)
    await poller.waitUntilIdle()

    #expect(await claude.recordedModes() == [.background, .background, .background])

    await poller.stop()
}

private actor ManualUsageClock: UsageClock {
    private var current: Date
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleepRegistrationCount = 0
    private var sleepWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(now: Date) {
        self.current = now
    }

    var now: Date {
        get async { current }
    }

    func sleep(for duration: TimeInterval) async throws {
        let deadline = current.addingTimeInterval(duration)
        if deadline <= current {
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                sleepRegistrationCount += 1
                resumeSleepWaiters()
            }
        } onCancel: {
            Task { await self.cancelSleep(id) }
        }
    }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
        resumeReadySleepers()
    }

    func waitForSleepRegistrationCount(_ count: Int) async {
        if sleepRegistrationCount >= count {
            return
        }

        await withCheckedContinuation { continuation in
            sleepWaiters.append((count, continuation))
        }
    }

    private func cancelSleep(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func resumeReadySleepers() {
        let ready = sleepers.filter { $0.value.deadline <= current }.map(\.key)
        for id in ready {
            sleepers.removeValue(forKey: id)?.continuation.resume()
        }
    }

    private func resumeSleepWaiters() {
        let ready = sleepWaiters.filter { sleepRegistrationCount >= $0.0 }
        sleepWaiters.removeAll { sleepRegistrationCount >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }

    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }
}

private actor SuspendingNowClock: UsageClock {
    private let current: Date
    private var requestCount = 0
    private var released = false
    private var nowContinuations: [CheckedContinuation<Date, Never>] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(now: Date) {
        self.current = now
    }

    var now: Date {
        get async {
            requestCount += 1
            resumeRequestWaiters()
            if released {
                return current
            }

            return await withCheckedContinuation { continuation in
                nowContinuations.append(continuation)
            }
        }
    }

    func sleep(for _: TimeInterval) async throws {}

    func waitForNowRequestCount(_ count: Int) async {
        if requestCount >= count {
            return
        }

        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func releaseAll() {
        released = true
        let continuations = nowContinuations
        nowContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: current)
        }
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { requestCount >= $0.0 }
        requestWaiters.removeAll { requestCount >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

private actor RecordingUsageProvider: UsageProvider {
    private var results: [ProviderState]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var fetchCount = 0

    init(results: [ProviderState]) {
        self.results = results
    }

    func fetch(previous _: ProviderUsage?, mode _: CredentialAccessMode) async -> ProviderState {
        fetchCount += 1
        resumeWaiters()
        if results.count > 1 {
            return results.removeFirst()
        }

        return results[0]
    }

    func waitForFetchCount(_ count: Int) async {
        if fetchCount >= count {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { fetchCount >= $0.0 }
        waiters.removeAll { fetchCount >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

private actor ModeRecordingUsageProvider: UsageProvider {
    private let result: ProviderState
    private var modes: [CredentialAccessMode] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(result: ProviderState) {
        self.result = result
    }

    func fetch(previous _: ProviderUsage?, mode: CredentialAccessMode) async -> ProviderState {
        modes.append(mode)
        resumeWaiters()
        return result
    }

    func recordedModes() -> [CredentialAccessMode] {
        modes
    }

    func waitForFetchCount(_ count: Int) async {
        if modes.count >= count {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { modes.count >= $0.0 }
        waiters.removeAll { modes.count >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

private actor PreviousRecordingUsageProvider: UsageProvider {
    private let result: ProviderState
    private var previousValues: [ProviderUsage?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(result: ProviderState) {
        self.result = result
    }

    func fetch(previous: ProviderUsage?, mode _: CredentialAccessMode) async -> ProviderState {
        previousValues.append(previous)
        resumeWaiters()
        return result
    }

    func previousUsages() -> [ProviderUsage?] {
        previousValues
    }

    func waitForFetchCount(_ count: Int) async {
        if previousValues.count >= count {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { previousValues.count >= $0.0 }
        waiters.removeAll { previousValues.count >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

private actor RecordingThresholdNotificationSender: NotificationSending {
    private var notifications: [UsageThresholdNotification] = []

    func send(_ notification: UsageThresholdNotification) async {
        notifications.append(notification)
    }

    func sentNotifications() -> [UsageThresholdNotification] {
        notifications
    }
}

private actor SuspendingThresholdProvider {
    private let resolvedThreshold: Int
    private var requestCount = 0
    private var released = false
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var thresholdContinuations: [CheckedContinuation<Int, Never>] = []

    init(threshold: Int) {
        self.resolvedThreshold = threshold
    }

    func threshold() async -> Int {
        requestCount += 1
        resumeRequestWaiters()
        if released {
            return resolvedThreshold
        }

        return await withCheckedContinuation { continuation in
            thresholdContinuations.append(continuation)
        }
    }

    func waitForRequestCount(_ count: Int) async {
        if requestCount >= count {
            return
        }

        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func releaseAll() {
        released = true
        let continuations = thresholdContinuations
        thresholdContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: resolvedThreshold)
        }
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { requestCount >= $0.0 }
        requestWaiters.removeAll { requestCount >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

private actor BlockingUsageProvider: UsageProvider {
    private let result: ProviderState
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var finishWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var modes: [CredentialAccessMode] = []
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var isSuspendedInFetch = false

    init(result: ProviderState) {
        self.result = result
    }

    func fetch(previous _: ProviderUsage?, mode: CredentialAccessMode) async -> ProviderState {
        modes.append(mode)
        startCount += 1
        isSuspendedInFetch = true
        resumeStartWaiters()
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
        isSuspendedInFetch = !releaseContinuations.isEmpty
        finishCount += 1
        resumeFinishWaiters()

        return result
    }

    func recordedModes() -> [CredentialAccessMode] {
        modes
    }

    func release() {
        guard !releaseContinuations.isEmpty else {
            return
        }

        let continuation = releaseContinuations.removeFirst()
        isSuspendedInFetch = !releaseContinuations.isEmpty
        continuation.resume()
    }

    func waitUntilStarted() async {
        await waitForStartCount(1)
    }

    func waitUntilFinished() async {
        await waitForFinishCount(1)
    }

    func waitForStartCount(_ count: Int) async {
        if startCount >= count {
            return
        }

        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func waitForFinishCount(_ count: Int) async {
        if finishCount >= count {
            return
        }

        await withCheckedContinuation { continuation in
            finishWaiters.append((count, continuation))
        }
    }

    private func resumeStartWaiters() {
        let ready = startWaiters.filter { startCount >= $0.0 }
        startWaiters.removeAll { startCount >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }

    private func resumeFinishWaiters() {
        let ready = finishWaiters.filter { finishCount >= $0.0 }
        finishWaiters.removeAll { finishCount >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

private final class WakeEventProbe: @unchecked Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        var continuation: AsyncStream<Void>.Continuation?
        self.stream = AsyncStream<Void> { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation!
    }

    func send() {
        continuation.yield(())
    }
}

private final class RestartableWakeEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?
    private var streamID = 0

    func stream() -> AsyncStream<Void> {
        let id = lock.withLock {
            streamID += 1
            return streamID
        }

        return AsyncStream { continuation in
            self.lock.withLock {
                self.continuation = continuation
            }
            continuation.onTermination = { _ in
                self.lock.withLock {
                    if self.streamID == id {
                        self.continuation = nil
                    }
                }
            }
        }
    }

    func send() {
        lock.withLock {
            continuation
        }?.yield(())
    }
}

private func sampleUsage(fiveHour: Int, weekly: Int) -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(
            percentRemaining: fiveHour,
            resetsAt: Date(timeIntervalSince1970: 1_783_008_000)
        ),
        weekly: UsageWindow(
            percentRemaining: weekly,
            resetsAt: Date(timeIntervalSince1970: 1_783_555_200)
        )
    )
}

private func waitForProviderState(
    _ appState: AppState,
    provider: ProviderID,
    state expectedState: ProviderState
) async {
    for _ in 0..<100 {
        if await appState.providerState(for: provider) == expectedState {
            return
        }

        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}
