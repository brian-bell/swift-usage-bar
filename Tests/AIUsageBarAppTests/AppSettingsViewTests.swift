import Testing
import UsageCore

@testable import AIUsageBarApp

/// Settings side of the hosted UI suite. Lives in the same `HostedUITests`
/// suite (via extension) so `.serialized` covers it: parallel hosted tests
/// racing on same-process AX and window creation crash the runner.
///
/// Reads-only, like the dropdown side (see the suite doc in
/// `MenuBarContentViewTests.swift`).
///
/// Two SwiftUI-on-macOS realities shape the assertions:
/// - Identifiers of controls *inside* a TabView pane are flattened to the
///   pane's identifier (`settings.tab.general`), so pane controls are matched
///   by label + role instead.
/// - The tab bar's AX radio group is not reliably published in the hosted
///   window, and synthetic clicks aren't runner-safe, so tab switching is not
///   covered here; tab titles/order stay unit-tested (`SettingsTabTests`) and
///   the per-provider status wiring at the model level
///   (`shellModelExposesProviderStatusRowsForTheSettingsProvidersTab`).
extension HostedUITests {
    @Test
    func appSettingsViewShowsGeneralPaneBoundToStoreAndFooter() throws {
        // Seed a non-default interval so a hard-coded/unbound picker cannot
        // pass by accident (default is 2 minutes / 120 s).
        let settingsStore = onMain {
            let store = SettingsStore(defaults: isolatedDefaults())
            store.pollInterval = 600
            return store
        }
        let host = onMain {
            UITestHost.settings(
                AppSettingsView(
                    model: shellModel(settingsStore: settingsStore)
                )
            )
        }
        defer { onMain { host.close() } }
        let ax = AXQuery(windowTitle: host.windowTitle)

        // General pane (initial tab): picker shows the seeded store value —
        // proving the control is bound through the staged draft to the store.
        let sawPicker = pollUntil {
            ax.snapshot(label: "Refresh every")?.role == "AXPopUpButton"
        }
        #expect(
            sawPicker,
            "Poll picker never published. Tree:\n\(ax.dumpIdentifiers())"
        )
        #expect(ax.snapshot(label: "Refresh every")?.value == "10 minutes")
        #expect(ax.snapshot(label: "Launch at login")?.role == "AXCheckBox")

        // Footer buttons live outside the panes and keep their identifiers.
        #expect(ax.exists(AccessibilityID.settingsCancel))
        #expect(ax.exists(AccessibilityID.settingsOK))
    }
}
