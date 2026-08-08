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
    /// Everything rendered inside this provider's expandable disclosure.
    public let chain: ProviderChainSection

    fileprivate init(
        provider: ProviderID,
        state: ProviderState?,
        source: ProviderDataSource?,
        chain: [ProviderDataSourceStep],
        lastUpdatedAt: Date?,
        workspaceID: String?,
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

        self.chain = ProviderChainSection(
            provider: provider,
            state: state,
            reportedSteps: chain,
            age: age,
            workspaceID: workspaceID
        )
    }
}

// MARK: - Retrieval chain disclosure

/// How one chain step reads: the mockup's three step states.
public enum ProviderChainStepStyle: Equatable, Sendable {
    /// This step produced the data. Bold, primary ink, green dot.
    case used
    /// Never attempted because an earlier step won. Muted, plain, no dot.
    case standingBy
    /// Attempted and failed. Bold, amber, amber dot.
    case failed
}

/// One numbered row inside a provider's chain disclosure.
public struct ProviderChainStepRow: Equatable, Identifiable, Sendable {
    public var id: Int { number }

    /// 1-based position in the provider's fallback order.
    public let number: Int
    public let source: ProviderDataSource
    /// The step's label, e.g. `ChatGPT API · Local Codex credential`.
    public let name: String
    /// The right-hand state text: `Used 2 min ago`, `Standing by`,
    /// `Session expired · 1 h ago`.
    public let stateText: String
    public let style: ProviderChainStepStyle

    /// Dot colour, or `nil` for a standing-by step, which shows no dot at all.
    public var indicator: ProviderStatusIndicator? {
        switch style {
        case .used:
            return .live
        case .failed:
            return .stale
        case .standingBy:
            return nil
        }
    }

    /// Bold for the steps that carry information; plain for standing-by.
    public var isEmphasized: Bool { style != .standingBy }
    /// Secondary ink for the steps that merely explain what did not run.
    public var isMuted: Bool { style == .standingBy }

    fileprivate init(
        number: Int,
        source: ProviderDataSource,
        outcome: ProviderDataSourceStepOutcome,
        age: String?
    ) {
        self.number = number
        self.source = source
        self.name = source.chainStepName

        switch outcome {
        case .used:
            self.style = .used
            self.stateText = age.map { "Used \($0)" } ?? "Used"
        case .standingBy:
            self.style = .standingBy
            self.stateText = "Standing by"
        case let .failed(reason):
            self.style = .failed
            let phrase = source.chainFailureSummary(for: reason)
            self.stateText = age.map { "\(phrase) \u{00B7} \($0)" } ?? phrase
        }
    }
}

/// Everything inside one provider's disclosure: the numbered chain, an optional
/// explanatory caption, a recovery callout when the provider is stale, and — for
/// the two OpenCode providers — the shared optional workspace field.
public struct ProviderChainSection: Equatable, Identifiable, Sendable {
    public var id: ProviderID { provider }

    public let provider: ProviderID
    /// Empty when the provider is off: a hidden provider reads no sources, so it
    /// has no chain to show.
    public let steps: [ProviderChainStepRow]
    public let caption: String?
    /// Actionable guidance shown in an amber callout while the provider is stale.
    public let recoveryCallout: String?
    public let isOff: Bool
    public let showsWorkspaceField: Bool
    public let workspaceCaption: String?

    public var workspaceFieldLabel: String { "Workspace" }
    public var workspaceFieldPlaceholder: String { "Optional wrk_\u{2026} ID or URL" }
    public var workspaceFieldAccessibilityLabel: String { "OpenCode workspace" }

    fileprivate init(
        provider: ProviderID,
        state: ProviderState?,
        reportedSteps: [ProviderDataSourceStep],
        age: String?,
        workspaceID: String?
    ) {
        self.provider = provider

        guard state != .hidden else {
            self.steps = []
            self.caption = nil
            self.recoveryCallout = nil
            self.isOff = true
            self.showsWorkspaceField = false
            self.workspaceCaption = nil
            return
        }

        self.isOff = false
        // Providers report only the steps they walked; the remainder of the
        // declared chain never ran because an earlier step won, which is exactly
        // what "standing by" means.
        self.steps = provider.dataSourceChain.enumerated().map { index, source in
            let outcome = reportedSteps.first { $0.source == source }?.outcome ?? .standingBy
            return ProviderChainStepRow(
                number: index + 1,
                source: source,
                outcome: outcome,
                age: age
            )
        }
        self.caption = provider.chainCaption

        if case let .stale(last: _, reason: reason) = state {
            self.recoveryCallout = provider.recoveryCallout(for: reason)
        } else {
            self.recoveryCallout = nil
        }

        // Both OpenCode providers share the one workspace setting, and each
        // disclosure must offer it — enabling only Credits would otherwise
        // strand the field inside a hidden Go disclosure.
        self.showsWorkspaceField = provider == .openCodeGo || provider == .openCodeCredits
        if showsWorkspaceField {
            let trimmed = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let discovery = trimmed.isEmpty
                ? "Currently auto-discovered. Set an ID to skip discovery."
                : "Using the workspace ID you set; discovery is skipped."
            // Symmetric: whichever disclosure the user edits from, the
            // caption says the value also moves the other OpenCode provider.
            let sharing = provider == .openCodeCredits
                ? " Shared with OpenCode Go."
                : " Shared with OpenCode Credits."
            self.workspaceCaption = discovery + sharing
        } else {
            self.workspaceCaption = nil
        }
    }
}

/// Pure view model behind the per-provider status lines in Settings › Providers.
public struct ProviderStatusViewModel: Equatable, Sendable {
    public let rows: [ProviderStatusRow]

    public init(
        states: [ProviderID: ProviderState],
        dataSources: [ProviderID: ProviderDataSource] = [:],
        chains: [ProviderID: [ProviderDataSourceStep]] = [:],
        lastUpdatedAt: [ProviderID: Date] = [:],
        workspaceID: String? = nil,
        now: Date = Date()
    ) {
        // Every provider gets a line: the Providers tab lists a toggle for each,
        // including hidden ones, which render as `Off`.
        self.rows = ProviderID.allCases.map { provider in
            ProviderStatusRow(
                provider: provider,
                state: states[provider],
                source: dataSources[provider],
                chain: chains[provider] ?? [],
                lastUpdatedAt: lastUpdatedAt[provider],
                workspaceID: workspaceID,
                now: now
            )
        }
    }

    /// Which provider disclosures should be open when the Settings window opens.
    ///
    /// A stale provider auto-expands so its recovery guidance is visible without
    /// a click; everything the user opened by hand stays open. This is a
    /// decision, not rendering, so it lives here rather than in `onAppear`.
    public func expandedProviders(remembering remembered: Set<ProviderID>) -> Set<ProviderID> {
        remembered.union(rows.filter { $0.indicator == .stale }.map(\.provider))
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

public extension ProviderDataSource {
    /// Short failure phrase for this source's row in the chain disclosure.
    ///
    /// Deliberately terser than `StaleReason.statusSummary(for:)`: the step's own
    /// name already says which path failed, so repeating it ("Chrome session
    /// expired" next to "Chrome cookie · opencode.ai") would be noise.
    func chainFailureSummary(for reason: StaleReason) -> String {
        switch reason {
        case .parseFailure:
            return "Unexpected response"
        case .networkError:
            switch self {
            case .claudeStatuslineCache:
                // Reading the statusline cache is a local file operation, so it
                // can never fail for network reasons. `.networkError` is the one
                // reason its reader uses for a cache that parsed but is older
                // than the app's freshness bound; saying "Network error" here
                // would send the user off debugging a network that was never
                // involved.
                return "Cache out of date"
            case .codexAppServer:
                return "Desktop helper unavailable"
            case .claudeWebSession, .claudeOAuthAPI, .codexAPI,
                 .openCodeGoChromeCookie, .openCodeCreditsChromeCookie,
                 .minimaxTokenPlanAPI:
                return "Network error"
            }
        case .tokenExpired:
            switch self {
            case .minimaxTokenPlanAPI:
                // An `sk-…` API key doesn't expire on the wire the way an
                // OAuth token does — the server rejects it, so name the cause.
                return "Key rejected"
            case .claudeWebSession, .claudeOAuthAPI, .claudeStatuslineCache,
                 .codexAPI, .codexAppServer, .openCodeGoChromeCookie,
                 .openCodeCreditsChromeCookie:
                return "Token expired"
            }
        case .sessionExpired:
            switch self {
            case .minimaxTokenPlanAPI:
                return "Key rejected"
            case .claudeWebSession, .claudeOAuthAPI, .claudeStatuslineCache,
                 .codexAPI, .codexAppServer, .openCodeGoChromeCookie,
                 .openCodeCreditsChromeCookie:
                return "Session expired"
            }
        case .workspaceSelectionRequired:
            return "Choose a workspace"
        case .credentialUnavailable:
            switch self {
            case .claudeWebSession:
                return "No Chrome cookie"
            case .openCodeGoChromeCookie:
                return "Usage unavailable"
            case .openCodeCreditsChromeCookie:
                // Covers both "no cookie" and "billing not configured on the
                // workspace" — either way there is no balance to read.
                return "No credits balance"
            case .claudeStatuslineCache:
                // The cache file is absent (the statusline wrapper was never
                // wired) or could not be read at all.
                return "No cache file"
            case .codexAppServer:
                return "Desktop sign-in unavailable"
            case .claudeOAuthAPI, .codexAPI, .minimaxTokenPlanAPI:
                return "No credential found"
            }
        }
    }
}

private extension ProviderID {
    /// Explanatory caption under a provider's chain. OpenCode Go has none: its
    /// caption belongs to the workspace field instead.
    var chainCaption: String? {
        switch self {
        case .claude:
            return """
                Sources are tried in order each refresh; data comes from the first that succeeds. \
                All access is read-only.
                """
        case .codex:
            return """
                The signed Codex desktop helper is tried only when the local Codex credential is \
                unavailable. Both paths read the weekly limit only.
                """
        case .openCodeGo:
            return nil
        case .openCodeCredits:
            return """
                Reads the workspace credit balance from opencode.ai with the same read-only \
                Chrome cookie as OpenCode Go. Only the balance and monthly spend are read.
                """
        case .miniMax:
            return """
                Reads only the OpenCode auth.json key for the MiniMax provider. All access is \
                read-only.
                """
        }
    }

    /// Actionable recovery guidance for a stale provider, shown in an amber
    /// callout inside its disclosure. Every string names one concrete next step
    /// and ends at Refresh Now, because nothing the app does can fix it —
    /// credential access is strictly read-only.
    func recoveryCallout(for reason: StaleReason) -> String {
        let prefix = "Showing last-known data. "
        switch (self, reason) {
        case (.claude, .tokenExpired):
            return prefix + "Run Claude Code once to refresh its OAuth token, then choose "
                + "Refresh Now from the menu bar."
        case (.claude, .credentialUnavailable):
            return prefix + "Sign in to Claude Code, then choose Refresh Now from the menu bar."
        case (.claude, .sessionExpired):
            return prefix + "Sign in to claude.ai in Chrome, then choose Refresh Now from "
                + "the menu bar."
        case (.codex, .tokenExpired):
            return prefix + "Open Codex and refresh its local sign-in, then choose "
                + "Refresh Now from the menu bar."
        case (.codex, .credentialUnavailable), (.codex, .sessionExpired):
            return prefix + "Sign in to the Codex desktop app or Codex CLI, then choose "
                + "Refresh Now from the "
                + "menu bar."
        case (.openCodeGo, .sessionExpired), (.openCodeGo, .tokenExpired),
             (.openCodeCredits, .sessionExpired), (.openCodeCredits, .tokenExpired):
            return prefix + "Sign in to opencode.ai in Chrome, then choose Refresh Now "
                + "from the menu bar."
        case (.openCodeGo, .credentialUnavailable):
            return prefix + "Check your opencode.ai sign-in and workspace access in Chrome, "
                + "then choose Refresh Now from the menu bar."
        case (.openCodeCredits, .credentialUnavailable):
            // No "Showing last-known data." prefix: unlike the transient
            // failures, "billing not configured" is a steady state that
            // usually has no last-known data behind it.
            return "No credits balance found. Check your opencode.ai sign-in in "
                + "Chrome and that billing is configured on the workspace, then choose "
                + "Refresh Now from the menu bar."
        case (.openCodeCredits, .parseFailure):
            // Unlike the generic "usually clears on its own": a drifted
            // billing record stays drifted until the app learns the new
            // shape.
            return prefix + "The billing data is in a shape this version can't read. "
                + "If this persists, AIUsageBar needs an update."
        case (.openCodeGo, .workspaceSelectionRequired), (.openCodeCredits, .workspaceSelectionRequired):
            return prefix + "Several workspaces matched. Set a workspace ID below, then "
                + "choose Refresh Now from the menu bar."
        case (.miniMax, .credentialUnavailable):
            return prefix + "No MiniMax key found. Sign in to the MiniMax provider in "
                + "OpenCode (run: opencode auth login) \u{2014} AIUsageBar borrows that key "
                + "read-only \u{2014} then choose Refresh Now from the menu bar."
        case (.miniMax, .tokenExpired):
            return prefix + "The MiniMax key was rejected. Re-authenticate the MiniMax "
                + "provider in OpenCode, then choose Refresh Now from the menu bar."
        case (.miniMax, .sessionExpired):
            return prefix + "Re-authenticate the MiniMax provider in OpenCode, then choose "
                + "Refresh Now from the menu bar."
        case (_, .networkError):
            return prefix + "Check your network connection, then choose Refresh Now from "
                + "the menu bar."
        case (_, .parseFailure):
            return prefix + "The service returned an unexpected response; this usually "
                + "clears on its own."
        case (_, .workspaceSelectionRequired):
            return prefix + "Choose a workspace in Settings, then choose Refresh Now from "
                + "the menu bar."
        }
    }

    var statusDisplayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .openCodeGo:
            return "OpenCode Go"
        case .openCodeCredits:
            return "OpenCode Credits"
        case .miniMax:
            return "MiniMax"
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
            case .openCodeGo, .openCodeCredits:
                return "Session token expired"
            case .miniMax:
                return "MiniMax key rejected"
            }
        case .credentialUnavailable:
            switch provider {
            case .claude:
                return "No Claude Code credential found"
            case .codex:
                return "No local Codex sign-in found"
            case .openCodeGo:
                return "OpenCode usage unavailable"
            case .openCodeCredits:
                return "No credits balance found"
            case .miniMax:
                return "No MiniMax key found"
            }
        case .sessionExpired:
            switch provider {
            case .claude:
                return "claude.ai session expired"
            case .codex:
                return "Session expired"
            case .openCodeGo, .openCodeCredits:
                return "Chrome session expired"
            case .miniMax:
                return "MiniMax key rejected"
            }
        case .workspaceSelectionRequired:
            switch provider {
            case .openCodeGo, .openCodeCredits:
                return "Choose a workspace in Settings"
            case .claude, .codex, .miniMax:
                return "Workspace selection required"
            }
        }
    }
}
