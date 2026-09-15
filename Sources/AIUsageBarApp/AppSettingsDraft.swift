import Foundation
import UsageCore

/// Editable snapshot of the app settings. The Settings dialog binds to a draft so that
/// edits are staged and only committed to `UsageBarShellModel` on OK (`apply`) — Cancel
/// simply discards the draft.
struct AppSettingsDraft: Equatable {
    var pollInterval: TimeInterval
    var providerVisibility: [ProviderID: Bool]
    var warningThresholds: [Int]
    var openCodeGoWorkspace: String
    var xaiTeamID: String
    var xaiManagementKey: String
    var launchAtLoginEnabled: Bool

    /// Neutral defaults used only until the live values are captured in `onAppear`.
    static let placeholder = AppSettingsDraft(
        pollInterval: 120,
        providerVisibility: Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.map { provider in
                (provider, !provider.isHiddenByDefault)
            }
        ),
        warningThresholds: WarningThresholds.defaultValue,
        openCodeGoWorkspace: "",
        xaiTeamID: "",
        xaiManagementKey: "",
        launchAtLoginEnabled: false
    )

    func visibility(for provider: ProviderID) -> Bool {
        providerVisibility[provider] ?? true
    }

    var canAddWarning: Bool {
        warningThresholds.count < WarningThresholds.maximumCount
    }

    /// The level a new row starts at: one step above the current highest
    /// warning (adding a warning usually means wanting an earlier heads-up),
    /// nudged down past any level already in use so rows never duplicate.
    /// With an empty list this lands back on the default 15.
    var suggestedWarningThreshold: Int {
        var candidate = min(
            (warningThresholds.max() ?? 0) + 15,
            WarningThresholds.validRange.upperBound
        )
        while warningThresholds.contains(candidate),
              candidate > WarningThresholds.validRange.lowerBound {
            candidate -= 1
        }
        return candidate
    }

    mutating func addWarning() {
        guard canAddWarning else {
            return
        }
        warningThresholds.append(suggestedWarningThreshold)
    }

    /// Stepper intent for one warning row. A row can never land on another
    /// row's level: a step onto a taken value keeps moving in the stepped
    /// direction until it finds a free one (a step blocked at the range edge
    /// is a no-op), so the list stays duplicate-free by construction rather
    /// than relying on silent cleanup on OK.
    mutating func updateWarning(at index: Int, to newValue: Int) {
        guard warningThresholds.indices.contains(index) else {
            return
        }
        let current = warningThresholds[index]
        guard newValue != current else {
            return
        }

        var candidate = newValue
        let others = warningThresholds.enumerated().compactMap { offset, element in
            offset == index ? nil : element
        }
        if others.contains(candidate) {
            let step = newValue > current ? 1 : -1
            repeat {
                candidate += step
            } while others.contains(candidate)
        }
        guard WarningThresholds.validRange.contains(candidate) else {
            return
        }
        warningThresholds[index] = candidate
    }

    mutating func removeWarning(at index: Int) {
        guard warningThresholds.indices.contains(index) else {
            return
        }
        warningThresholds.remove(at: index)
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
            warningThresholds: model.warningThresholds,
            openCodeGoWorkspace: model.openCodeGoWorkspaceID ?? "",
            xaiTeamID: model.xaiTeamID ?? "",
            xaiManagementKey: "",
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

        if model.warningThresholds != warningThresholds {
            model.setWarningThresholds(warningThresholds)
        }

        let normalizedWorkspace = OpenCodeGoWorkspace.normalizedID(from: openCodeGoWorkspace)
        if model.openCodeGoWorkspaceID != normalizedWorkspace {
            model.setOpenCodeGoWorkspace(openCodeGoWorkspace)
        }

        let normalizedTeamID = XAITeamID.normalizedID(from: xaiTeamID)
        if model.xaiTeamID != normalizedTeamID {
            model.setXAITeamID(xaiTeamID)
        }

        let trimmedKey = xaiManagementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            model.setXAIManagementKey(trimmedKey)
        }

        guard model.launchAtLoginEnabled != launchAtLoginEnabled else {
            return false
        }

        model.setLaunchAtLoginEnabled(launchAtLoginEnabled)
        return true
    }
}
