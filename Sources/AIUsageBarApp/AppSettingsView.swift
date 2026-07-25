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
    // Which provider disclosures are open. Held here so it survives closing and
    // reopening the Settings window; stale providers are folded in on open by
    // `expandedProviders(remembering:)`, which is where that decision is tested.
    @State private var expandedProviders: Set<ProviderID> = []

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

                ProvidersSettingsPane(
                    draft: $draft,
                    expandedProviders: $expandedProviders,
                    statusRows: model
                        .providerStatusViewModel(stagedVisibility: draft.providerVisibility)
                        .rows
                )
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
        .onAppear {
            draft = .capture(from: model)
            expandedProviders = model.providerStatusViewModel
                .expandedProviders(remembering: expandedProviders)
        }
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
    @Binding var expandedProviders: Set<ProviderID>
    let statusRows: [ProviderStatusRow]

    var body: some View {
        SettingsPaneLayout {
            // Each provider is one visual unit: its toggle, then the status line
            // for that provider, which doubles as the disclosure label for the
            // retrieval chain beneath it.
            ForEach(statusRows) { status in
                ProviderSettingsRow(
                    status: status,
                    isVisible: Binding(
                        get: { draft.visibility(for: status.provider) },
                        set: { draft.providerVisibility[status.provider] = $0 }
                    ),
                    isExpanded: Binding(
                        get: { expandedProviders.contains(status.provider) },
                        set: { isExpanded in
                            if isExpanded {
                                expandedProviders.insert(status.provider)
                            } else {
                                expandedProviders.remove(status.provider)
                            }
                        }
                    ),
                    workspace: $draft.openCodeGoWorkspace
                )
            }
        }
    }
}

/// A provider's toggle plus its expandable retrieval chain. Turning the provider
/// off drops the disclosure entirely — a hidden provider reads no sources, so it
/// has no chain to tell.
private struct ProviderSettingsRow: View {
    let status: ProviderStatusRow
    @Binding var isVisible: Bool
    @Binding var isExpanded: Bool
    @Binding var workspace: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(status.providerName) {
                Toggle(status.providerName, isOn: $isVisible)
                    .labelsHidden()
            }

            if isVisible {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ProviderChainView(chain: status.chain, workspace: $workspace)
                        .padding(.top, 6)
                } label: {
                    ProviderStatusLineView(status: status)
                }
            } else {
                ProviderStatusLineView(status: status)
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

/// The contents of a provider's disclosure: numbered chain steps, the caption
/// explaining them, a recovery callout when stale, and — for OpenCode Go only —
/// the optional workspace field. Renders only; every string comes from
/// `ProviderChainSection`.
private struct ProviderChainView: View {
    let chain: ProviderChainSection
    @Binding var workspace: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(chain.steps) { step in
                    ProviderChainStepView(step: step)
                }
            }

            if let caption = chain.caption {
                SettingsCaption(caption)
            }

            if let callout = chain.recoveryCallout {
                RecoveryCalloutView(text: callout)
            }

            if chain.showsWorkspaceField {
                LabeledContent(chain.workspaceFieldLabel) {
                    TextField(chain.workspaceFieldPlaceholder, text: $workspace)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .accessibilityLabel(chain.workspaceFieldAccessibilityLabel)
                }

                if let workspaceCaption = chain.workspaceCaption {
                    SettingsCaption(workspaceCaption)
                }
            }
        }
        .padding(.leading, 4)
    }
}

private struct ProviderChainStepView: View {
    let step: ProviderChainStepRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(step.number).")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)

            Circle()
                .fill(step.indicator?.dotColor ?? .clear)
                .frame(width: 6, height: 6)

            Text(step.name)
                .font(.caption)
                .fontWeight(step.isEmphasized ? .semibold : .regular)
                .foregroundStyle(step.textStyle)

            Spacer(minLength: 12)

            Text(step.stateText)
                .font(.caption)
                .fontWeight(step.isEmphasized ? .semibold : .regular)
                .foregroundStyle(step.textStyle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.number), \(step.name): \(step.stateText)")
    }
}

/// Amber-tinted guidance box shown inside a stale provider's disclosure.
private struct RecoveryCalloutView: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

private struct SettingsCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension ProviderChainStepRow {
    /// Ink for a step's text: amber for a failure, muted for standing by,
    /// primary for the step that produced the data.
    var textStyle: Color {
        switch style {
        case .failed:
            return .orange
        case .standingBy:
            return .secondary
        case .used:
            return .primary
        }
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
