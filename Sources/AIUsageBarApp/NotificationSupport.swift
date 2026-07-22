import AppKit
import Foundation
import UsageCore
import UserNotifications

final class UserNotificationSender: NotificationSending, @unchecked Sendable {
    private let center: any NotificationCenterClient
    private let authorizationLock = NSLock()
    private var authorizationTask: Task<Bool, any Error>?

    init(center: any NotificationCenterClient = SystemNotificationCenterClient()) {
        self.center = center
    }

    func send(_ notification: UsageThresholdNotification) async throws {
        try await verifyAuthorization()

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

    private func verifyAuthorization() async throws {
        switch await center.authorizationStatus() {
        case .authorized:
            return
        case .denied:
            throw NotificationDeliveryError.authorizationDenied
        case .notDetermined:
            let granted = try await requestAuthorization()
            guard granted else {
                throw NotificationDeliveryError.authorizationDenied
            }
        }
    }

    private func requestAuthorization() async throws -> Bool {
        let task: Task<Bool, any Error> = authorizationLock.withLock {
            if let authorizationTask {
                return authorizationTask
            }

            let task = Task { [center] in
                try await center.requestAuthorization()
            }
            authorizationTask = task
            return task
        }

        do {
            let granted = try await task.value
            authorizationLock.withLock {
                authorizationTask = nil
            }
            return granted
        } catch {
            authorizationLock.withLock {
                authorizationTask = nil
            }
            throw error
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

protocol NotificationCenterClient: Sendable {
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

enum NotificationAuthorizationStatus: Sendable {
    case authorized
    case denied
    case notDetermined
}

final class SystemNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    private let injectedCenter: UNUserNotificationCenter?

    init(center: UNUserNotificationCenter? = nil) {
        self.injectedCenter = center
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    private var center: UNUserNotificationCenter {
        injectedCenter ?? .current()
    }
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
        case .openCodeGo:
            return "opencode-go"
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
        case .monthly:
            return "monthly"
        }
    }
}
