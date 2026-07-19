import SwiftUI
import UsageCore

/// Standalone Settings window content, presented via the `Settings` scene (⌘,).
/// Replaces the settings block that used to live inline in the menu bar dropdown.
struct AppSettingsView: View {
    @Bindable var model: UsageBarShellModel

    var body: some View {
        Form {
            Section("Refresh") {
                Picker(
                    "Interval",
                    selection: Binding(
                        get: { model.pollInterval },
                        set: { model.setPollInterval($0) }
                    )
                ) {
                    Text("1 min").tag(TimeInterval(60))
                    Text("2 min").tag(TimeInterval(120))
                    Text("5 min").tag(TimeInterval(300))
                    Text("10 min").tag(TimeInterval(600))
                }
            }

            Section("Providers") {
                ForEach(ProviderID.allCases, id: \.self) { provider in
                    Toggle(
                        provider.settingsDisplayName,
                        isOn: Binding(
                            get: { model.isProviderVisible(provider) },
                            set: { model.setProvider(provider, visible: $0) }
                        )
                    )
                }
            }

            Section("Notifications") {
                Stepper(
                    "Alert below \(model.thresholdPercent)% remaining",
                    value: Binding(
                        get: { model.thresholdPercent },
                        set: { model.setThresholdPercent($0) }
                    ),
                    in: 1...100,
                    step: 1
                )
            }

            Section("General") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLoginEnabled($0) }
                    )
                )

                if let launchAtLoginError = model.launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension ProviderID {
    var settingsDisplayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }
}
