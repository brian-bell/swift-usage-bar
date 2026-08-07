import Testing
import UsageCore

@testable import AIUsageBarApp

/// Hosted SwiftUI + AX tests.
///
/// Bodies are deliberately **not** `@MainActor`: Swift Testing runs them on
/// the cooperative pool, and every AppKit/AX interaction hops through `onMain`
/// (see the threading rules on `UITestHost`). Convergence is awaited with
/// `pollUntil` from the background thread.
///
/// These tests are **reads-only**. Delivering synthetic input to SwiftUI
/// controls in-process — via `AXUIElementPerformAction`, HID-tap `CGEvent`, or
/// direct `NSEvent` posting — works in isolation but nondeterministically
/// kills the SwiftPM test runner's main-queue drain afterwards, silently
/// truncating the rest of the run (documented in
/// `docs/ui-test-harness-slice-1.md`). Interaction coverage therefore lives at
/// the model level (`UsageBarShellModelTests`, `AppSettingsDraftTests`) until
/// a process-isolated runner exists.
@Suite("Hosted UI", .serialized)
struct HostedUITests {
    @Test
    func menuBarContentViewShowsFreshProviderRowsAndFooter() throws {
        let host = onMain {
            UITestHost.dropdown(MenuBarContentView(model: shellModel(appState: freshState())))
        }
        defer { onMain { host.close() } }
        let ax = AXQuery(windowTitle: host.windowTitle)

        // The AX tree populates as the runner's main run loop turns, so the
        // first assertion polls until the hosted view is reachable.
        #expect(
            pollUntil { ax.exists(AccessibilityID.menuBarProvider(.claude)) },
            "Missing Claude provider row. Tree:\n\(ax.dumpIdentifiers())"
        )
        #expect(ax.exists(AccessibilityID.menuBarProvider(.codex)))
        #expect(ax.exists(AccessibilityID.menuBarWindow(.claude, .fiveHour)))
        #expect(ax.exists(AccessibilityID.menuBarWindow(.claude, .weekly)))
        #expect(ax.exists(AccessibilityID.menuBarWindow(.codex, .weekly)))
        // Codex is weekly-only: no 5-hour row.
        #expect(!ax.exists(AccessibilityID.menuBarWindow(.codex, .fiveHour)))
        #expect(ax.exists(AccessibilityID.menuBarRefresh))
        #expect(ax.exists(AccessibilityID.menuBarSettings))
        #expect(ax.exists(AccessibilityID.menuBarQuit))
        // Seeded last-updated caption rendered via the dropdown view model.
        #expect(ax.exists(AccessibilityID.menuBarUpdated))
    }
}
