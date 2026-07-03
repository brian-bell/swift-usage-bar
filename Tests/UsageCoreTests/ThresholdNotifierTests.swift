import Foundation
import Testing
import UsageCore

@Test
func usageThresholdNotificationHasDeterministicDisplayText() {
    let notification = UsageThresholdNotification(
        provider: .claude,
        window: .fiveHour,
        percentRemaining: 18,
        threshold: 20,
        resetsAt: Date(timeIntervalSince1970: 1_783_008_000)
    )

    #expect(notification.title == "Claude five-hour usage below 20%")
    #expect(notification.body == "18% remaining before this window resets.")
}

@Test
func thresholdNotifierSendsWhenWindowCrossesBelowThreshold() async {
    let sender = RecordingNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let fiveHourReset = Date(timeIntervalSince1970: 1_783_008_000)
    let weeklyReset = Date(timeIntervalSince1970: 1_783_555_200)
    let previous = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 25, resetsAt: fiveHourReset),
        weekly: UsageWindow(percentRemaining: 80, resetsAt: weeklyReset)
    )
    let current = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 18, resetsAt: fiveHourReset),
        weekly: UsageWindow(percentRemaining: 80, resetsAt: weeklyReset)
    )

    await notifier.evaluate(
        previous: previous,
        current: current,
        provider: .claude,
        threshold: 20
    )

    #expect(await sender.sentNotifications() == [
        UsageThresholdNotification(
            provider: .claude,
            window: .fiveHour,
            percentRemaining: 18,
            threshold: 20,
            resetsAt: fiveHourReset
        ),
    ])
}

@Test
func thresholdNotifierDeduplicatesSameProviderWindowResetCycle() async {
    let sender = RecordingNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let reset = Date(timeIntervalSince1970: 1_783_008_000)
    let weeklyReset = Date(timeIntervalSince1970: 1_783_555_200)

    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: reset, weekly: 80, weeklyReset: weeklyReset),
        current: usage(fiveHour: 18, fiveHourReset: reset, weekly: 80, weeklyReset: weeklyReset),
        provider: .claude,
        threshold: 20
    )
    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: reset, weekly: 80, weeklyReset: weeklyReset),
        current: usage(fiveHour: 15, fiveHourReset: reset, weekly: 80, weeklyReset: weeklyReset),
        provider: .claude,
        threshold: 20
    )

    #expect(await sender.sentNotifications().count == 1)
}

@Test
func thresholdNotifierDoesNotRearmAfterRisingAboveThresholdInSameCycle() async {
    let sender = RecordingNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let reset = Date(timeIntervalSince1970: 1_783_008_000)

    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: reset, weekly: 80),
        current: usage(fiveHour: 18, fiveHourReset: reset, weekly: 80),
        provider: .claude,
        threshold: 20
    )
    await notifier.evaluate(
        previous: usage(fiveHour: 18, fiveHourReset: reset, weekly: 80),
        current: usage(fiveHour: 24, fiveHourReset: reset, weekly: 80),
        provider: .claude,
        threshold: 20
    )
    await notifier.evaluate(
        previous: usage(fiveHour: 24, fiveHourReset: reset, weekly: 80),
        current: usage(fiveHour: 17, fiveHourReset: reset, weekly: 80),
        provider: .claude,
        threshold: 20
    )

    #expect(await sender.sentNotifications() == [
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 18, threshold: 20, resetsAt: reset),
    ])
}

@Test
func thresholdNotifierUsesInclusivePreviousAndExclusiveCurrentThresholdBoundary() async {
    let sender = RecordingNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let fiveHourReset = Date(timeIntervalSince1970: 1_783_008_000)
    let weeklyReset = Date(timeIntervalSince1970: 1_783_555_200)

    await notifier.evaluate(
        previous: usage(fiveHour: 20, fiveHourReset: fiveHourReset, weekly: 25, weeklyReset: weeklyReset),
        current: usage(fiveHour: 19, fiveHourReset: fiveHourReset, weekly: 20, weeklyReset: weeklyReset),
        provider: .claude,
        threshold: 20
    )

    #expect(await sender.sentNotifications() == [
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 19, threshold: 20, resetsAt: fiveHourReset),
    ])
}

@Test
func thresholdNotifierTracksProvidersAndWindowsIndependently() async {
    let sender = RecordingNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let fiveHourReset = Date(timeIntervalSince1970: 1_783_008_000)
    let weeklyReset = Date(timeIntervalSince1970: 1_783_555_200)

    for provider in [ProviderID.claude, .codex] {
        await notifier.evaluate(
            previous: usage(fiveHour: 25, fiveHourReset: fiveHourReset, weekly: 25, weeklyReset: weeklyReset),
            current: usage(fiveHour: 18, fiveHourReset: fiveHourReset, weekly: 17, weeklyReset: weeklyReset),
            provider: provider,
            threshold: 20
        )
    }

    #expect(await sender.sentNotifications() == [
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 18, threshold: 20, resetsAt: fiveHourReset),
        thresholdNotification(provider: .claude, window: .weekly, percentRemaining: 17, threshold: 20, resetsAt: weeklyReset),
        thresholdNotification(provider: .codex, window: .fiveHour, percentRemaining: 18, threshold: 20, resetsAt: fiveHourReset),
        thresholdNotification(provider: .codex, window: .weekly, percentRemaining: 17, threshold: 20, resetsAt: weeklyReset),
    ])
}

@Test
func thresholdNotifierRearmsOnlyWindowWhoseResetCycleChanges() async {
    let sender = RecordingNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let firstFiveHourReset = Date(timeIntervalSince1970: 1_783_008_000)
    let secondFiveHourReset = Date(timeIntervalSince1970: 1_783_026_000)
    let weeklyReset = Date(timeIntervalSince1970: 1_783_555_200)

    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: firstFiveHourReset, weekly: 25, weeklyReset: weeklyReset),
        current: usage(fiveHour: 18, fiveHourReset: firstFiveHourReset, weekly: 17, weeklyReset: weeklyReset),
        provider: .claude,
        threshold: 20
    )
    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: firstFiveHourReset, weekly: 25, weeklyReset: weeklyReset),
        current: usage(fiveHour: 18, fiveHourReset: secondFiveHourReset, weekly: 17, weeklyReset: weeklyReset),
        provider: .claude,
        threshold: 20
    )

    #expect(await sender.sentNotifications() == [
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 18, threshold: 20, resetsAt: firstFiveHourReset),
        thresholdNotification(provider: .claude, window: .weekly, percentRemaining: 17, threshold: 20, resetsAt: weeklyReset),
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 18, threshold: 20, resetsAt: secondFiveHourReset),
    ])
}

@Test
func thresholdNotifierSendsForNewResetCycleAlreadyBelowThreshold() async {
    let sender = RecordingNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let firstReset = Date(timeIntervalSince1970: 1_783_008_000)
    let secondReset = Date(timeIntervalSince1970: 1_783_026_000)

    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: firstReset, weekly: 80),
        current: usage(fiveHour: 18, fiveHourReset: firstReset, weekly: 80),
        provider: .claude,
        threshold: 20
    )
    await notifier.evaluate(
        previous: usage(fiveHour: 18, fiveHourReset: firstReset, weekly: 80),
        current: usage(fiveHour: 16, fiveHourReset: secondReset, weekly: 80),
        provider: .claude,
        threshold: 20
    )

    #expect(await sender.sentNotifications() == [
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 18, threshold: 20, resetsAt: firstReset),
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 16, threshold: 20, resetsAt: secondReset),
    ])
}

@Test
func thresholdNotifierTreatsNilAndChangedKnownResetCyclesAsDistinct() async {
    let sender = RecordingNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let knownReset = Date(timeIntervalSince1970: 1_783_008_000)
    let earlierReset = Date(timeIntervalSince1970: 1_782_990_000)

    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: nil, weekly: 80),
        current: usage(fiveHour: 18, fiveHourReset: nil, weekly: 80),
        provider: .claude,
        threshold: 20
    )
    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: nil, weekly: 80),
        current: usage(fiveHour: 17, fiveHourReset: nil, weekly: 80),
        provider: .claude,
        threshold: 20
    )
    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: nil, weekly: 80),
        current: usage(fiveHour: 16, fiveHourReset: knownReset, weekly: 80),
        provider: .claude,
        threshold: 20
    )
    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: knownReset, weekly: 80),
        current: usage(fiveHour: 15, fiveHourReset: earlierReset, weekly: 80),
        provider: .claude,
        threshold: 20
    )

    #expect(await sender.sentNotifications() == [
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 18, threshold: 20, resetsAt: nil),
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 16, threshold: 20, resetsAt: knownReset),
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 15, threshold: 20, resetsAt: earlierReset),
    ])
}

@Test
func thresholdNotifierDoesNotNotifyWithoutPreviousUsage() async {
    let sender = RecordingNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)

    await notifier.evaluate(
        previous: nil,
        current: usage(fiveHour: 18, weekly: 17),
        provider: .claude,
        threshold: 20
    )

    #expect(await sender.sentNotifications().isEmpty)
}

@Test
func thresholdNotifierDoesNotDoubleSendConcurrentCrossingForSameCycle() async {
    let sender = SuspendingNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let reset = Date(timeIntervalSince1970: 1_783_008_000)

    let firstEvaluation = Task {
        await notifier.evaluate(
            previous: usage(fiveHour: 25, fiveHourReset: reset, weekly: 80),
            current: usage(fiveHour: 18, fiveHourReset: reset, weekly: 80),
            provider: .claude,
            threshold: 20
        )
    }
    await sender.waitForSendCount(1)

    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: reset, weekly: 80),
        current: usage(fiveHour: 17, fiveHourReset: reset, weekly: 80),
        provider: .claude,
        threshold: 20
    )

    #expect(await sender.sendCount == 1)
    await sender.releaseAll()
    await firstEvaluation.value
}

@Test
func thresholdNotifierUsesLatestThresholdWithoutSynthesizingCrossings() async {
    let sender = RecordingNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let reset = Date(timeIntervalSince1970: 1_783_008_000)
    let otherReset = Date(timeIntervalSince1970: 1_783_555_200)

    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: reset, weekly: 35, weeklyReset: otherReset),
        current: usage(fiveHour: 18, fiveHourReset: reset, weekly: 25, weeklyReset: otherReset),
        provider: .claude,
        threshold: 20
    )
    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: reset, weekly: 25, weeklyReset: otherReset),
        current: usage(fiveHour: 17, fiveHourReset: reset, weekly: 24, weeklyReset: otherReset),
        provider: .claude,
        threshold: 30
    )

    #expect(await sender.sentNotifications() == [
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 18, threshold: 20, resetsAt: reset),
    ])
}

@Test
func thresholdNotifierAllowsRealCrossingAfterThresholdChanges() async {
    let sender = RecordingNotificationSender()
    let notifier = ThresholdNotifier(sender: sender)
    let reset = Date(timeIntervalSince1970: 1_783_008_000)

    await notifier.evaluate(
        previous: usage(fiveHour: 25, fiveHourReset: reset, weekly: 80),
        current: usage(fiveHour: 18, fiveHourReset: reset, weekly: 80),
        provider: .claude,
        threshold: 20
    )
    await notifier.evaluate(
        previous: usage(fiveHour: 35, fiveHourReset: reset, weekly: 80),
        current: usage(fiveHour: 25, fiveHourReset: reset, weekly: 80),
        provider: .claude,
        threshold: 30
    )

    #expect(await sender.sentNotifications() == [
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 18, threshold: 20, resetsAt: reset),
        thresholdNotification(provider: .claude, window: .fiveHour, percentRemaining: 25, threshold: 30, resetsAt: reset),
    ])
}

private actor RecordingNotificationSender: NotificationSending {
    private var notifications: [UsageThresholdNotification] = []

    func send(_ notification: UsageThresholdNotification) async {
        notifications.append(notification)
    }

    func sentNotifications() -> [UsageThresholdNotification] {
        notifications
    }
}

private actor SuspendingNotificationSender: NotificationSending {
    private var sendWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var sendCount = 0

    func send(_: UsageThresholdNotification) async {
        sendCount += 1
        resumeSendWaiters()
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitForSendCount(_ count: Int) async {
        if sendCount >= count {
            return
        }

        await withCheckedContinuation { continuation in
            sendWaiters.append((count, continuation))
        }
    }

    func releaseAll() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func resumeSendWaiters() {
        let ready = sendWaiters.filter { sendCount >= $0.0 }
        sendWaiters.removeAll { sendCount >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

private func thresholdNotification(
    provider: ProviderID,
    window: UsageWindowKind,
    percentRemaining: Int,
    threshold: Int,
    resetsAt: Date?
) -> UsageThresholdNotification {
    UsageThresholdNotification(
        provider: provider,
        window: window,
        percentRemaining: percentRemaining,
        threshold: threshold,
        resetsAt: resetsAt
    )
}

private func usage(
    fiveHour: Int,
    fiveHourReset: Date? = Date(timeIntervalSince1970: 1_783_008_000),
    weekly: Int,
    weeklyReset: Date? = Date(timeIntervalSince1970: 1_783_555_200)
) -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: fiveHour, resetsAt: fiveHourReset),
        weekly: UsageWindow(percentRemaining: weekly, resetsAt: weeklyReset)
    )
}
