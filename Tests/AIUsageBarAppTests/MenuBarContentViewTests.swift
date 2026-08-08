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

    @Test
    func menuBarContentViewRendersOpenCodeCreditsRow() throws {
        // OpenCode Credits is hidden by default; the shell model respects
        // that via applyStoredProviderVisibility, so the credits row would
        // never render. Flip the visibility in the isolated SettingsStore
        // before building the model.
        let settingsStore = SettingsStore(defaults: isolatedDefaults())
        settingsStore.setProvider(.openCodeCredits, visible: true)

        let host = onMain {
            UITestHost.dropdown(
                MenuBarContentView(
                    model: shellModel(
                        appState: openCodeCreditsFreshState(),
                        settingsStore: settingsStore
                    )
                )
            )
        }
        defer { onMain { host.close() } }
        let ax = AXQuery(windowTitle: host.windowTitle)

        #expect(
            pollUntil { ax.exists(AccessibilityID.menuBarProviderCredits(.openCodeCredits)) },
            "Missing OpenCode Credits row. Tree:\n\(ax.dumpIdentifiers())"
        )
        // The credits provider renders no percent-window rows at all.
        #expect(!ax.exists(AccessibilityID.menuBarWindow(.openCodeCredits, .fiveHour)))
        #expect(!ax.exists(AccessibilityID.menuBarWindow(.openCodeCredits, .weekly)))
        #expect(!ax.exists(AccessibilityID.menuBarWindow(.openCodeCredits, .monthly)))
        // The amount label is the most failure-prone piece of the row —
        // it goes through NumberFormatter with the system locale. A bare
        // existence check on the AX id only proves the row is wired up;
        // confirming the formatted dollar value pins the formatter too.
        #expect(ax.firstValue(containing: "$42.50") != nil)
        #expect(ax.firstValue(containing: "$2.96 of $50 used this month") != nil)
        // Pin the per-text AX ids so a SwiftUI modifier refactor that drops
        // an identifier doesn't leave the values visible but break future
        // AX-based assertions.
        #expect(ax.exists("\(AccessibilityID.menuBarProviderCredits(.openCodeCredits)).amount"))
        #expect(ax.exists("\(AccessibilityID.menuBarProviderCredits(.openCodeCredits)).caption"))
    }
}
