import AppKit
import SwiftUI
import UsageCore

struct MenuBarContentView: View {
    @Bindable var model: UsageBarShellModel
    @Environment(\.openSettings) private var openSettings

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

            HStack {
                Button {
                    model.presentSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")
                .keyboardShortcut(",", modifiers: .command)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            model.setSettingsOpener {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            }
        }
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

