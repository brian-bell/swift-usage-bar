import AppKit
import SwiftUI
import UsageCore

struct MenuBarContentView: View {
    @Bindable var model: UsageBarShellModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.dropdownViewModel.rows) { row in
                ProviderUsageRowView(row: row)
            }

            Divider()

            HStack {
                Button("Refresh now") {
                    Task {
                        await model.refreshNow()
                    }
                }

                Spacer()

                Text(lastUpdatedText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Divider()

            SettingsView(model: model)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var lastUpdatedText: String {
        model.dropdownViewModel.updatedLabel ?? "Not updated yet"
    }
}

private struct ProviderUsageRowView: View {
    let row: DropdownProviderRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProviderIconView(provider: row.provider, size: 16)
                Text(row.providerName)
                    .font(.headline)
                Spacer()
                if let staleMessage = row.staleMessage {
                    Text(staleMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let fiveHour = row.fiveHour {
                UsageWindowRowView(row: fiveHour)
            }
            UsageWindowRowView(row: row.weekly)
            if let fable = row.fable {
                UsageWindowRowView(row: fable)
            }
        }
        .foregroundStyle(row.isStale ? .secondary : .primary)
    }
}

private struct UsageWindowRowView: View {
    let row: DropdownUsageWindowRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.title)
                    .frame(width: 52, alignment: .leading)
                Text(row.percentLabel)
                    .monospacedDigit()
                Spacer()
                Text(row.countdownLabel)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            ProgressView(value: row.barFraction)
                .progressViewStyle(.linear)
        }
    }
}

struct SettingsView: View {
    @Bindable var model: UsageBarShellModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            ForEach(ProviderID.allCases, id: \.self) { provider in
                Toggle(
                    provider.settingsDisplayName,
                    isOn: Binding(
                        get: { model.isProviderVisible(provider) },
                        set: { model.setProvider(provider, visible: $0) }
                    )
                )
            }

            Stepper(
                "Threshold: \(model.thresholdPercent)%",
                value: Binding(
                    get: { model.thresholdPercent },
                    set: { model.setThresholdPercent($0) }
                ),
                in: 1...100,
                step: 1
            )

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

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

private extension ProviderID {
    var settingsDisplayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }
}
