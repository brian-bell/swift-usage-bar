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

public final class SettingsStore: @unchecked Sendable {
    private enum Defaults {
        static let pollInterval = UsagePoller.defaultInterval
        static let thresholdPercent = 20
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

    public var thresholdPercent: Int {
        get {
            guard defaults.object(forKey: Keys.thresholdPercent) != nil else {
                return Defaults.thresholdPercent
            }

            return defaults.integer(forKey: Keys.thresholdPercent)
        }
        set {
            defaults.set(newValue, forKey: Keys.thresholdPercent)
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
            return provider != .openCodeGo
        }

        return defaults.bool(forKey: key)
    }

    public func setProvider(_ provider: ProviderID, visible: Bool) {
        defaults.set(visible, forKey: Keys.providerVisibility(provider))
    }
}

private enum Keys {
    static let pollInterval = "settings.pollInterval"
    static let thresholdPercent = "settings.thresholdPercent"
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
        }
    }
}
