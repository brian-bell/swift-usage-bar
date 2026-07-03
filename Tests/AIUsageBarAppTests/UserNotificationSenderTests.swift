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

private final class RecordingNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [NotificationAuthorizationStatus]
    private var statusCheckCount = 0
    private var addedRequestIdentifiers: [String] = []

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
            addedRequestIdentifiers.append(request.identifier)
        }
    }

    func addedRequestCount() -> Int {
        lock.withLock {
            addedRequestIdentifiers.count
        }
    }
}

private func usageThresholdNotification() -> UsageThresholdNotification {
    UsageThresholdNotification(
        provider: .claude,
        window: .fiveHour,
        percentRemaining: 18,
        threshold: 20,
        resetsAt: Date(timeIntervalSince1970: 1_783_008_000)
    )
}
