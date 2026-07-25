import Foundation

/// Dot colour for a provider's status line.
public enum ProviderStatusIndicator: Equatable, Sendable {
    /// Green: this poll produced fresh data.
    case live
    /// Amber: showing last-known data because retrieval failed.
    case stale
    /// Grey: the provider is hidden, so nothing is fetched for it.
    case off
    /// Grey: visible, but the first poll hasn't reported yet. Distinct from
    /// `stale` because nothing has failed — claiming otherwise at launch would
    /// be a false alarm.
    case checking
}

/// One provider's status line, rendered as `State · method · age`.
///
/// Pure data: every string is built here so the Settings view only renders.
public struct ProviderStatusRow: Equatable, Identifiable, Sendable {
    public var id: ProviderID { provider }

    public let provider: ProviderID
    public let providerName: String
    public let indicator: ProviderStatusIndicator
    public let stateLabel: String
    /// The winning source when live, the failure summary when stale, `nil` when
    /// off or when no source was reported.
    public let methodLabel: String?
    /// `updated <age>` when live, `last data <age>` when stale; `nil` when the
    /// provider has never produced data.
    public let ageLabel: String?
    /// The three slots joined with ` · `, omitting the empty ones.
    public let text: String

    fileprivate init(
        provider: ProviderID,
        state: ProviderState?,
        source: ProviderDataSource?,
        lastUpdatedAt: Date?,
        now: Date
    ) {
        self.provider = provider
        self.providerName = provider.statusDisplayName

        let age = lastUpdatedAt.map { formatStatusAge(updatedAt: $0, now: now) }
        switch state {
        case .hidden:
            self.indicator = .off
            self.stateLabel = "Off"
            self.methodLabel = nil
            self.ageLabel = nil
        case .fresh:
            self.indicator = .live
            self.stateLabel = "Live"
            self.methodLabel = source?.displayName
            self.ageLabel = age.map { "updated \($0)" }
        case let .stale(last: _, reason: reason):
            self.indicator = .stale
            self.stateLabel = "Stale"
            self.methodLabel = reason.statusSummary(for: provider)
            self.ageLabel = age.map { "last data \($0)" }
        case nil:
            // Visible, but the poller has not reported on it yet — the first poll
            // is still in flight. Nothing has failed, so this is not `stale`.
            self.indicator = .checking
            self.stateLabel = "Checking\u{2026}"
            self.methodLabel = nil
            self.ageLabel = nil
        }

        self.text = [stateLabel, methodLabel, ageLabel]
            .compactMap { $0 }
            .joined(separator: " \u{00B7} ")
    }
}

/// Pure view model behind the per-provider status lines in Settings › Providers.
public struct ProviderStatusViewModel: Equatable, Sendable {
    public let rows: [ProviderStatusRow]

    public init(
        states: [ProviderID: ProviderState],
        dataSources: [ProviderID: ProviderDataSource] = [:],
        lastUpdatedAt: [ProviderID: Date] = [:],
        now: Date = Date()
    ) {
        // Every provider gets a line: the Providers tab lists a toggle for each,
        // including hidden ones, which render as `Off`.
        self.rows = ProviderID.allCases.map { provider in
            ProviderStatusRow(
                provider: provider,
                state: states[provider],
                source: dataSources[provider],
                lastUpdatedAt: lastUpdatedAt[provider],
                now: now
            )
        }
    }
}

/// Coarse, non-localised age used by the status line. Deliberately coarser than
/// `CountdownFormatter`: this is "how old is this reading", not a countdown.
private func formatStatusAge(updatedAt: Date, now: Date) -> String {
    // A clock skew that puts the refresh in the future reads as "just now"
    // rather than a negative age.
    let elapsedSeconds = max(0, Int(now.timeIntervalSince(updatedAt)))
    if elapsedSeconds < 60 {
        return "just now"
    }

    let elapsedMinutes = elapsedSeconds / 60
    if elapsedMinutes < 60 {
        return "\(elapsedMinutes) min ago"
    }

    let elapsedHours = elapsedMinutes / 60
    if elapsedHours < 24 {
        return "\(elapsedHours) h ago"
    }

    return "\(elapsedHours / 24) d ago"
}

private extension ProviderID {
    var statusDisplayName: String {
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

private extension StaleReason {
    /// Short failure summary shown in the method slot when a provider is stale.
    /// Provider-specific where the same reason has a different cause and a
    /// different fix (a Claude token expiring is not an OpenCode cookie expiring).
    func statusSummary(for provider: ProviderID) -> String {
        switch self {
        case .parseFailure:
            return "Unexpected response format"
        case .networkError:
            return "Network error"
        case .tokenExpired:
            switch provider {
            case .claude:
                return "OAuth token expired"
            case .codex:
                return "Keychain token expired"
            case .openCodeGo:
                return "Session token expired"
            }
        case .credentialUnavailable:
            switch provider {
            case .claude:
                return "No Claude Code credential found"
            case .codex:
                return "No Codex credential found"
            case .openCodeGo:
                return "No opencode.ai cookie in Chrome"
            }
        case .sessionExpired:
            switch provider {
            case .claude:
                return "claude.ai session expired"
            case .codex:
                return "Session expired"
            case .openCodeGo:
                return "Chrome session expired"
            }
        case .workspaceSelectionRequired:
            switch provider {
            case .openCodeGo:
                return "Choose a workspace in Settings"
            case .claude, .codex:
                return "Workspace selection required"
            }
        }
    }
}
