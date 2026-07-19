import SwiftUI
import UsageCore

/// Standalone Settings window content, presented via the `Settings` scene (⌘,).
/// Edits are staged in a draft and only committed on OK; Cancel discards them.
struct AppSettingsView: View {
    @Bindable var model: UsageBarShellModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AppSettingsDraft.placeholder

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Refresh") {
                    Picker("Interval", selection: $draft.pollInterval) {
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
                                get: { draft.visibility(for: provider) },
                                set: { draft.providerVisibility[provider] = $0 }
                            )
                        )
                    }
                }

                Section("Notifications") {
                    Stepper(
                        "Alert below \(draft.thresholdPercent)% remaining",
                        value: $draft.thresholdPercent,
                        in: 1...100,
                        step: 1
                    )
                }

                Section("General") {
                    Toggle("Launch at login", isOn: $draft.launchAtLoginEnabled)

                    if let launchAtLoginError = model.launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollIndicators(.hidden)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("OK") {
                    let attemptedLaunchChange = draft.apply(to: model)
                    if attemptedLaunchChange, model.launchAtLoginError != nil {
                        // Keep the dialog open so the failure/approval message stays visible,
                        // and re-sync the toggle to launch-at-login's effective state.
                        draft = .capture(from: model)
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { draft = .capture(from: model) }
        .onDisappear { draft = .capture(from: model) }
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
