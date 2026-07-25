import SwiftUI
import UsageCore

/// Standalone Settings window content, presented via the `Settings` scene (⌘,).
/// Controls are split across toolbar-style tabs (General / Providers / Notifications), but all
/// edits are staged in one draft shared by the tabs and only committed on OK; Cancel discards.
struct AppSettingsView: View {
    @Bindable var model: UsageBarShellModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AppSettingsDraft.placeholder
    @State private var selectedTab = SettingsTab.initial

    // Tab panes lay out with plain stacks (rather than a grouped `Form`) so there is no scroll
    // view, and therefore no scroll indicator — the window sizes to fit the tallest tab.
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                GeneralSettingsPane(
                    draft: $draft,
                    launchAtLoginError: model.launchAtLoginError
                )
                .settingsTabItem(.general)

                ProvidersSettingsPane(draft: $draft, statusRows: model.providerStatusViewModel.rows)
                    .settingsTabItem(.providers)

                NotificationsSettingsPane(draft: $draft)
                    .settingsTabItem(.notifications)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

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
                        selectedTab = .general
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { draft = .capture(from: model) }
        .onDisappear { draft = .capture(from: model) }
    }
}

// MARK: - Tab panes

private struct GeneralSettingsPane: View {
    @Binding var draft: AppSettingsDraft
    let launchAtLoginError: String?

    var body: some View {
        SettingsPaneLayout {
            LabeledContent("Refresh every") {
                Picker("Refresh every", selection: $draft.pollInterval) {
                    Text("1 minute").tag(TimeInterval(60))
                    Text("2 minutes").tag(TimeInterval(120))
                    Text("5 minutes").tag(TimeInterval(300))
                    Text("10 minutes").tag(TimeInterval(600))
                }
                .labelsHidden()
                .fixedSize()
            }

            Text("Also refreshes on wake and with Refresh Now.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            LabeledContent("Launch at login") {
                Toggle("Launch at login", isOn: $draft.launchAtLoginEnabled)
                    .labelsHidden()
            }

            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ProvidersSettingsPane: View {
    @Binding var draft: AppSettingsDraft
    let statusRows: [ProviderStatusRow]

    var body: some View {
        SettingsPaneLayout {
            // Each provider is one visual unit: its toggle, then the status line
            // for that provider tucked directly beneath it.
            ForEach(ProviderID.allCases, id: \.self) { provider in
                VStack(alignment: .leading, spacing: 3) {
                    LabeledContent(provider.settingsDisplayName) {
                        Toggle(
                            provider.settingsDisplayName,
                            isOn: Binding(
                                get: { draft.visibility(for: provider) },
                                set: { draft.providerVisibility[provider] = $0 }
                            )
                        )
                        .labelsHidden()
                    }

                    if let status = statusRows.first(where: { $0.provider == provider }) {
                        ProviderStatusLineView(status: status)
                    }
                }
            }

            if draft.visibility(for: .openCodeGo) {
                LabeledContent("OpenCode Go workspace") {
                    TextField("Optional wrk_\u{2026} ID or URL", text: $draft.openCodeGoWorkspace)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                }
            }
        }
    }
}

/// One-line `State · method · age` indicator under a provider's toggle.
/// Renders only: every string and the dot state come from `ProviderStatusRow`.
private struct ProviderStatusLineView: View {
    let status: ProviderStatusRow

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.indicator.dotColor)
                .frame(width: 7, height: 7)
            Text(status.text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.providerName) status: \(status.text)")
    }
}

private extension ProviderStatusIndicator {
    var dotColor: Color {
        switch self {
        case .live:
            return .green
        case .stale:
            return .orange
        case .off, .checking:
            return .secondary
        }
    }
}

private struct NotificationsSettingsPane: View {
    @Binding var draft: AppSettingsDraft

    var body: some View {
        SettingsPaneLayout {
            LabeledContent("Alert below") {
                HStack(spacing: 6) {
                    Text("\(draft.thresholdPercent)")
                        .monospacedDigit()
                    Stepper(
                        "Alert below",
                        value: $draft.thresholdPercent,
                        in: 1...100,
                        step: 1
                    )
                    .labelsHidden()
                    Text("% remaining")
                }
            }

            Text("One alert per usage window each reset cycle. Stale data never alerts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared pane chrome

/// Common spacing/alignment for every tab's rows, so panes differ only in their controls.
private struct SettingsPaneLayout<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

private extension View {
    func settingsTabItem(_ tab: SettingsTab) -> some View {
        tabItem {
            Label(tab.title, systemImage: tab.systemImage)
        }
        .tag(tab)
    }
}

extension ProviderID {
    var settingsDisplayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .openCodeGo:
            return "OpenCode Go"
        }
    }
}
