import AppKit
import Foundation
import UsageCore
import UserNotifications

@main
struct AIUsageBarApp {
    static func main() {}
}

final class UserNotificationSender: NotificationSending, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private let authorizationLock = NSLock()
    private var isAuthorized = false
    private var authorizationTask: Task<Bool, any Error>?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func send(_ notification: UsageThresholdNotification) async throws {
        try await requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: Self.identifier(for: notification),
            content: content,
            trigger: nil
        )

        try await center.add(request)
    }

    private func requestAuthorizationIfNeeded() async throws {
        let task: Task<Bool, any Error>? = authorizationLock.withLock {
            if isAuthorized {
                return nil
            }

            if let authorizationTask {
                return Optional(authorizationTask)
            }

            let task = Task { [center] in
                try await center.requestAuthorization(options: [.alert, .sound])
            }
            authorizationTask = task
            return Optional(task)
        }

        guard let task else {
            return
        }

        let granted: Bool
        do {
            granted = try await task.value
        } catch {
            authorizationLock.withLock {
                authorizationTask = nil
            }
            throw error
        }

        authorizationLock.withLock {
            authorizationTask = nil
            isAuthorized = granted
        }

        guard granted else {
            throw NotificationDeliveryError.authorizationDenied
        }
    }

    private static func identifier(for notification: UsageThresholdNotification) -> String {
        let resetComponent = notification.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return [
            "usage-threshold",
            notification.provider.identifierComponent,
            notification.window.identifierComponent,
            resetComponent,
        ].joined(separator: ".")
    }
}

private enum NotificationDeliveryError: Error {
    case authorizationDenied
}

enum WorkspaceWakeEvents {
    static func stream(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = NotificationObserverToken(notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield(())
            })

            continuation.onTermination = { _ in
                notificationCenter.removeObserver(observer.value)
            }
        }
    }
}

private final class NotificationObserverToken: @unchecked Sendable {
    let value: any NSObjectProtocol

    init(_ value: any NSObjectProtocol) {
        self.value = value
    }
}

private extension ProviderID {
    var identifierComponent: String {
        switch self {
        case .claude:
            return "claude"
        case .codex:
            return "codex"
        }
    }
}

private extension UsageWindowKind {
    var identifierComponent: String {
        switch self {
        case .fiveHour:
            return "five-hour"
        case .weekly:
            return "weekly"
        }
    }
}
