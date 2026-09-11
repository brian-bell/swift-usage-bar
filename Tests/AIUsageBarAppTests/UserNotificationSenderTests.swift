import Foundation
import Testing
import UsageCore
import UserNotifications

@testable import AIUsageBarApp

@Test
func userNotificationSenderRechecksAuthorizationBeforeEachDelivery() async throws {
    let center = RecordingNotificationCenterClient(statuses: [.authorized, .denied])
    let sender = UserNotificationSender(center: center)
    let notification = usageThresholdNotification()

    try await sender.send(notification)

    do {
        try await sender.send(notification)
        Issue.record("Expected delivery to fail after authorization is revoked")
    } catch {}

    #expect(center.authorizationStatusCheckCount == 2)
    #expect(center.addedRequestCount() == 1)
}

@Test
func userNotificationSenderDistinguishesRequestsByWarningLevel() async throws {
    // Two warning levels firing for the same window in the same reset cycle
    // must not collapse into one request: UNUserNotificationCenter replaces a
    // pending request that shares an identifier.
    let center = RecordingNotificationCenterClient(statuses: [.authorized, .authorized])
    let sender = UserNotificationSender(center: center)
    let resetsAt = Date(timeIntervalSince1970: 1_783_008_000)

    try await sender.send(usageThresholdNotification(threshold: 30, resetsAt: resetsAt))
    try await sender.send(usageThresholdNotification(threshold: 10, resetsAt: resetsAt))

    let identifiers = center.addedRequestIdentifiers()
    #expect(identifiers == [
        "usage-threshold.claude.five-hour.30.1783008000",
        "usage-threshold.claude.five-hour.10.1783008000",
    ])
}

private final class RecordingNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [NotificationAuthorizationStatus]
    private var statusCheckCount = 0
    private var addedIdentifiers: [String] = []

    var authorizationStatusCheckCount: Int {
        lock.withLock {
            statusCheckCount
        }
    }

    init(statuses: [NotificationAuthorizationStatus]) {
        self.statuses = statuses
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        lock.withLock {
            statusCheckCount += 1
            guard !statuses.isEmpty else {
                return .denied
            }
            return statuses.removeFirst()
        }
    }

    func requestAuthorization() async throws -> Bool {
        true
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock {
            addedIdentifiers.append(request.identifier)
        }
    }

    func addedRequestCount() -> Int {
        lock.withLock {
            addedIdentifiers.count
        }
    }

    func addedRequestIdentifiers() -> [String] {
        lock.withLock {
            addedIdentifiers
        }
    }
}

private func usageThresholdNotification(
    threshold: Int = 20,
    resetsAt: Date? = Date(timeIntervalSince1970: 1_783_008_000)
) -> UsageThresholdNotification {
    UsageThresholdNotification(
        provider: .claude,
        window: .fiveHour,
        percentRemaining: 18,
        threshold: threshold,
        resetsAt: resetsAt
    )
}
