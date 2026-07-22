import Foundation
import UsageCore

/// Editable snapshot of the app settings. The Settings dialog binds to a draft so that
/// edits are staged and only committed to `UsageBarShellModel` on OK (`apply`) — Cancel
/// simply discards the draft.
struct AppSettingsDraft: Equatable {
    var pollInterval: TimeInterval
    var providerVisibility: [ProviderID: Bool]
    var thresholdPercent: Int
    var openCodeGoWorkspace: String
    var launchAtLoginEnabled: Bool

    /// Neutral defaults used only until the live values are captured in `onAppear`.
    static let placeholder = AppSettingsDraft(
        pollInterval: 120,
        providerVisibility: Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.map { ($0, $0 != .openCodeGo) }
        ),
        thresholdPercent: 20,
        openCodeGoWorkspace: "",
        launchAtLoginEnabled: false
    )

    func visibility(for provider: ProviderID) -> Bool {
        providerVisibility[provider] ?? true
    }
}

extension AppSettingsDraft {
    @MainActor
    static func capture(from model: UsageBarShellModel) -> AppSettingsDraft {
        AppSettingsDraft(
            pollInterval: model.pollInterval,
            providerVisibility: Dictionary(
                uniqueKeysWithValues: ProviderID.allCases.map { ($0, model.isProviderVisible($0)) }
            ),
            thresholdPercent: model.thresholdPercent,
            openCodeGoWorkspace: model.openCodeGoWorkspaceID ?? "",
            launchAtLoginEnabled: model.launchAtLoginEnabled
        )
    }

    /// Commit the draft to the model, invoking each intent only for values that actually
    /// changed so unchanged settings don't trigger side effects (poll reschedule, launch
    /// registration, notifications re-arm).
    ///
    /// Returns `true` when a launch-at-login change was attempted. That operation reports
    /// failure/approval only through `model.launchAtLoginError`, so the caller uses this to
    /// decide whether to keep the dialog open long enough for the message to be seen.
    @MainActor
    @discardableResult
    func apply(to model: UsageBarShellModel) -> Bool {
        if model.pollInterval != pollInterval {
            model.setPollInterval(pollInterval)
        }

        for provider in ProviderID.allCases {
            let visible = visibility(for: provider)
            if model.isProviderVisible(provider) != visible {
                model.setProvider(provider, visible: visible)
            }
        }

        if model.thresholdPercent != thresholdPercent {
            model.setThresholdPercent(thresholdPercent)
        }

        let normalizedWorkspace = OpenCodeGoWorkspace.normalizedID(from: openCodeGoWorkspace)
        if model.openCodeGoWorkspaceID != normalizedWorkspace {
            model.setOpenCodeGoWorkspace(openCodeGoWorkspace)
        }

        guard model.launchAtLoginEnabled != launchAtLoginEnabled else {
            return false
        }

        model.setLaunchAtLoginEnabled(launchAtLoginEnabled)
        return true
    }
}
