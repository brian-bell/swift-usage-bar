import Foundation

public final class SettingsStore {
    private enum Defaults {
        static let pollInterval = UsagePoller.defaultInterval
        static let thresholdPercent = 20
        static let launchAtLoginEnabled = false
        static let providerVisible = true
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

    public func isProviderVisible(_ provider: ProviderID) -> Bool {
        let key = Keys.providerVisibility(provider)
        guard defaults.object(forKey: key) != nil else {
            return Defaults.providerVisible
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
        }
    }
}
