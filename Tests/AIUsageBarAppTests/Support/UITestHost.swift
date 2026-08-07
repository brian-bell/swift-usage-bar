import AppKit
import SwiftUI

/// Hosts a SwiftUI root view in a real NSWindow so the accessibility tree is
/// published for same-process AX queries.
///
/// Threading model: hosted UI tests run **off** the main actor (Swift Testing
/// schedules them on the cooperative pool) and reach AppKit through
/// `onMain { }` hops. Two hard rules, both verified by crashes during slice 1:
///
/// 1. **No nested run loops inside a `@MainActor` test body or main-queue
///    block.** A nested `RunLoop.run` on the main thread executes pending
///    main-queue blocks — including the ones Swift Testing uses to schedule
///    the next test — which truncates the run after the first test.
/// 2. **Every AX attribute read AND action must execute on the main thread.**
///    SwiftUI answers AX requests by evaluating view state, and asserts the
///    main queue (`dispatch_assert_queue_fail` in `ProvidersSettingsPane.body`
///    when a Toggle's AX value was read off-main).
///
/// Between `onMain` hops the test thread simply polls, so the runner's own
/// main-drain keeps pumping the run loop and SwiftUI/AX updates converge.
@MainActor
final class UITestHost: @unchecked Sendable {
    static let dropdownWidth: CGFloat = 320
    static let settingsWidth: CGFloat = 500
    static let dropdownHeight: CGFloat = 600
    static let settingsHeight: CGFloat = 720

    private static var didFinishLaunching = false
    /// Monotonic token so every host window gets a unique AX title; AXQuery
    /// refuses to fall back to unrelated windows.
    private static var nextWindowToken = 0

    let hostingView: NSHostingView<AnyView>
    let windowTitle: String
    private var window: NSWindow?

    static func dropdown<Content: View>(_ root: Content) -> UITestHost {
        UITestHost(root: root, size: NSSize(width: dropdownWidth, height: dropdownHeight))
    }

    static func settings<Content: View>(_ root: Content) -> UITestHost {
        UITestHost(root: root, size: NSSize(width: settingsWidth, height: settingsHeight))
    }

    init<Content: View>(root: Content, size: NSSize) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if !Self.didFinishLaunching {
            // Without a finished-launching NSApplication, the process has no AX
            // application element and every attribute read returns NotImplemented.
            app.finishLaunching()
            Self.didFinishLaunching = true
        }

        Self.nextWindowToken += 1
        let windowTitle = "AIUsageBarUITestHost-\(Self.nextWindowToken)"
        self.windowTitle = windowTitle

        let hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.frame = NSRect(origin: .zero, size: size)
        self.hostingView = hostingView

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = windowTitle
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        self.window = window

        hostingView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        // SwiftUI sizes the window to the *initial* tab's ideal height (264pt
        // for General), clipping the taller Providers pane out of the AX tree.
        // Force the full requested size so every tab's content publishes.
        window.setContentSize(size)
        window.layoutIfNeeded()
    }

    func close() {
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
    }
}

/// `@unchecked Sendable` box for returning a MainActor-bound value from a
/// `DispatchQueue.main.sync` hop: the value is produced on main and handed
/// back to the blocked caller untouched.
private struct MainResultBox: @unchecked Sendable {
    var value: Any?
}

/// Runs `body` synchronously on the main thread from a background test body.
///
/// The closure must be self-contained main-thread work (create a host, walk
/// AX, read model state) — it must not run a nested run loop (see the rules
/// on `UITestHost`).
func onMain<T>(_ body: @MainActor () -> T) -> T {
    // Type-erase to Any *inside* the MainActor region so the non-Sendable T
    // itself never crosses the isolation boundary.
    let box: MainResultBox
    if Thread.isMainThread {
        box = MainActor.assumeIsolated { MainResultBox(value: body() as Any) }
    } else {
        box = DispatchQueue.main.sync {
            MainActor.assumeIsolated { MainResultBox(value: body() as Any) }
        }
    }
    // The cast cannot fail: `value` was just assigned `body()`'s result.
    // swiftlint:disable:next force_cast
    return box.value as! T
}
