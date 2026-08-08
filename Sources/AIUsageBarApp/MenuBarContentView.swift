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
                .accessibilityIdentifier(AccessibilityID.menuBarRefresh)

                Spacer()

                Text(lastUpdatedText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .accessibilityIdentifier(AccessibilityID.menuBarUpdated)
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
                .accessibilityIdentifier(AccessibilityID.menuBarSettings)
                .keyboardShortcut(",", modifiers: .command)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .accessibilityIdentifier(AccessibilityID.menuBarQuit)
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
                    .accessibilityIdentifier(AccessibilityID.menuBarProvider(row.provider))
                Spacer()
                if let staleMessage = row.staleMessage {
                    Text(staleMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.menuBarProviderStale(row.provider))
                }
            }

            if let fiveHour = row.fiveHour {
                UsageWindowRowView(
                    row: fiveHour,
                    provider: row.provider,
                    window: .fiveHour
                )
            }
            if let weekly = row.weekly {
                UsageWindowRowView(
                    row: weekly,
                    provider: row.provider,
                    window: .weekly
                )
            }
            if let monthly = row.monthly {
                UsageWindowRowView(
                    row: monthly,
                    provider: row.provider,
                    window: .monthly
                )
            }
            if let fable = row.fable {
                UsageWindowRowView(
                    row: fable,
                    provider: row.provider,
                    window: .fable
                )
            }
            if let credits = row.credits {
                CreditsRowView(row: credits, provider: row.provider)
            }
        }
        .foregroundStyle(row.isStale ? .secondary : .primary)
    }
}

private struct CreditsRowView: View {
    let row: DropdownCreditsRow
    let provider: ProviderID

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.title)
                    .frame(width: 52, alignment: .leading)
                    .accessibilityIdentifier(AccessibilityID.menuBarProviderCredits(provider))
                Text(row.amountLabel)
                    .monospacedDigit()
                    .accessibilityIdentifier(AccessibilityID.menuBarProviderCreditsAmount(provider))
                Spacer()
                if let limitLabel = row.limitLabel {
                    Text(limitLabel)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.menuBarProviderCreditsLimit(provider))
                }
            }
            .font(.caption)

            if let barFraction = row.barFraction {
                ProgressView(value: barFraction)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier(AccessibilityID.menuBarProviderCreditsBar(provider))
                    .accessibilityValue(row.amountLabel)
            }
        }
    }
}

private struct UsageWindowRowView: View {
    let row: DropdownUsageWindowRow
    let provider: ProviderID
    let window: AccessibilityID.WindowKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.title)
                    .frame(width: 52, alignment: .leading)
                    .accessibilityIdentifier(AccessibilityID.menuBarWindow(provider, window))
                Text(row.percentLabel)
                    .monospacedDigit()
                    .accessibilityIdentifier(AccessibilityID.menuBarWindowPercent(provider, window))
                Spacer()
                Text(row.countdownLabel)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.menuBarWindowCountdown(provider, window))
            }
            .font(.caption)

            ProgressView(value: row.barFraction)
                .progressViewStyle(.linear)
                .accessibilityIdentifier(AccessibilityID.menuBarWindowBar(provider, window))
                .accessibilityValue(row.percentLabel)
        }
    }
}
