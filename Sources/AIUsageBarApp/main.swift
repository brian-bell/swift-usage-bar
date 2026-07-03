import AppKit
import Foundation
import UsageCore

@main
struct AIUsageBarApp {
    static func main() {}
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
