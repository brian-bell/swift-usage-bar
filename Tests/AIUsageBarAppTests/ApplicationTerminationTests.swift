import AppKit
import Testing

@testable import AIUsageBarApp

@Test
@MainActor
func repeatedTerminationRequestsRemainDeferredUntilCleanupFinishes() async {
    let application = RecordingTerminationApplication()
    let delegate = AIUsageBarAppDelegate()
    let cleanupGate = CleanupGate()
    delegate.beforeTermination = {
        await cleanupGate.wait()
    }

    let firstReply = delegate.applicationShouldTerminate(application)
    let repeatedReply = delegate.applicationShouldTerminate(application)

    #expect(firstReply == .terminateLater)
    #expect(repeatedReply == .terminateLater)
    #expect(application.terminationReplies.isEmpty)

    await cleanupGate.release()
    let terminationReply = await application.waitForTerminationReply()

    #expect(terminationReply)
    #expect(application.terminationReplies == [true])
}

@MainActor
private final class RecordingTerminationApplication: NSApplication {
    private(set) var terminationReplies: [Bool] = []
    private var replyContinuation: CheckedContinuation<Bool, Never>?

    override func reply(toApplicationShouldTerminate shouldTerminate: Bool) {
        terminationReplies.append(shouldTerminate)
        replyContinuation?.resume(returning: shouldTerminate)
        replyContinuation = nil
    }

    func waitForTerminationReply() async -> Bool {
        if let reply = terminationReplies.first {
            return reply
        }
        return await withCheckedContinuation { continuation in
            replyContinuation = continuation
        }
    }
}

private actor CleanupGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
