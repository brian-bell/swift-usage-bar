import Foundation

public enum OpenCodeGoWorkspace {
    public static func normalizedID(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.range(of: #"^wrk_[A-Za-z0-9]+$"#, options: .regularExpression) != nil {
            return value
        }

        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "opencode.ai"
        else { return nil }
        let components = url.pathComponents
        guard let workspaceIndex = components.firstIndex(of: "workspace"),
              components.indices.contains(workspaceIndex + 1)
        else { return nil }
        let candidate = components[workspaceIndex + 1]
        return candidate.range(of: #"^wrk_[A-Za-z0-9]+$"#, options: .regularExpression) != nil
            ? candidate
            : nil
    }
}

/// Validation rules for the user's warning list, shared by the store (which
/// normalizes on the way in and out) and the Settings draft (which gates the
/// Add button). Keeping them here means the range, dedupe, and cap hold no
/// matter which layer a value passes through.
public enum WarningThresholds {
    public static let maximumCount = 5
    public static let defaultValue = [15]
    public static let validRange = 1...100

    public static func normalized(_ values: [Int]) -> [Int] {
        var seen: Set<Int> = []
        var result: [Int] = []
        for value in values {
            let clamped = min(validRange.upperBound, max(validRange.lowerBound, value))
            guard seen.insert(clamped).inserted else {
                continue
            }
            result.append(clamped)
            guard result.count < maximumCount else {
                break
            }
        }
        return result
    }
}

public final class SettingsStore: @unchecked Sendable {
    private enum Defaults {
        static let pollInterval = UsagePoller.defaultInterval
        static let warningThresholds = WarningThresholds.defaultValue
        static let launchAtLoginEnabled = false
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var pollInterval: TimeInterval {
        get {
            guard defaults.object(forKey: Keys.pollInterval) != nil else {
                return Defaults.pollInterval
            }

            return defaults.double(forKey: Keys.pollInterval)
        }
        set {
            defaults.set(newValue, forKey: Keys.pollInterval)
        }
    }

    /// Percent-remaining levels that each arm one alert per usage window per
    /// reset cycle. Empty means alerts are off — a stored empty array is a
    /// real value, not "unset", so it never falls back to the default.
    public var warningThresholds: [Int] {
        get {
            if let stored = defaults.array(forKey: Keys.warningThresholds) as? [Int] {
                return WarningThresholds.normalized(stored)
            }

            // Read-time migration: a pre-multiple-warnings install has only the
            // scalar threshold; it becomes the single warning. The legacy key
            // is left in place and simply goes unread once warnings are saved.
            if defaults.object(forKey: Keys.legacyThresholdPercent) != nil {
                return WarningThresholds.normalized(
                    [defaults.integer(forKey: Keys.legacyThresholdPercent)]
                )
            }

            return Defaults.warningThresholds
        }
        set {
            defaults.set(WarningThresholds.normalized(newValue), forKey: Keys.warningThresholds)
        }
    }

    public var launchAtLoginEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.launchAtLoginEnabled) != nil else {
                return Defaults.launchAtLoginEnabled
            }

            return defaults.bool(forKey: Keys.launchAtLoginEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLoginEnabled)
        }
    }

    public var openCodeGoWorkspaceID: String? {
        get {
            OpenCodeGoWorkspace.normalizedID(from: defaults.string(forKey: Keys.openCodeGoWorkspaceID))
        }
        set {
            defaults.set(
                OpenCodeGoWorkspace.normalizedID(from: newValue),
                forKey: Keys.openCodeGoWorkspaceID
            )
        }
    }

    public func isProviderVisible(_ provider: ProviderID) -> Bool {
        let key = Keys.providerVisibility(provider)
        guard defaults.object(forKey: key) != nil else {
            return !provider.isHiddenByDefault
        }

        return defaults.bool(forKey: key)
    }

    public func setProvider(_ provider: ProviderID, visible: Bool) {
        defaults.set(visible, forKey: Keys.providerVisibility(provider))
    }
}

private enum Keys {
    static let pollInterval = "settings.pollInterval"
    static let warningThresholds = "settings.warningThresholds"
    /// Pre-multiple-warnings key, read only for migration into
    /// `warningThresholds`. The string must never change.
    static let legacyThresholdPercent = "settings.thresholdPercent"
    static let launchAtLoginEnabled = "settings.launchAtLoginEnabled"
    static let openCodeGoWorkspaceID = "settings.openCodeGo.workspaceID"

    static func providerVisibility(_ provider: ProviderID) -> String {
        "settings.provider.\(provider.keyComponent).visible"
    }
}

private extension ProviderID {
    var keyComponent: String {
        switch self {
        case .claude:
            return "claude"
        case .codex:
            return "codex"
        case .openCodeGo:
            return "openCodeGo"
        case .openCodeCredits:
            return "openCodeCredits"
        case .miniMax:
            return "miniMax"
        case .cursor:
            return "cursor"
        }
    }
}
