import Foundation

/// Which retrieval method actually produced a provider's usage data.
///
/// This is a *label*, never data: it names the path that won, and deliberately
/// carries nothing about the credential, cookie, or token that path used. It
/// exists so the Settings UI can tell the user where the numbers came from,
/// which matters most for Claude, whose provider silently walks three paths.
public enum ProviderDataSource: Hashable, Sendable, CaseIterable {
    /// Claude, first attempt: the read-only claude.ai browser cookie path.
    case claudeWebSession
    /// Claude, second attempt: `api.anthropic.com` with Claude Code's OAuth token.
    case claudeOAuthAPI
    /// Claude, fallback: the local statusline cache file written by Claude Code.
    case claudeStatuslineCache
    /// Codex: `chatgpt.com` with the Keychain-held Codex CLI token.
    case codexAPI
    /// Codex fallback: the signed Codex desktop helper's read-only rate-limit RPC.
    case codexAppServer
    /// OpenCode Go: `opencode.ai` with the read-only Chrome cookie.
    case openCodeGoChromeCookie
    /// MiniMax: token plan API authenticated by an OpenCode auth.json key.
    case minimaxTokenPlanAPI

    public var provider: ProviderID {
        switch self {
        case .claudeWebSession, .claudeOAuthAPI, .claudeStatuslineCache:
            return .claude
        case .codexAPI, .codexAppServer:
            return .codex
        case .openCodeGoChromeCookie:
            return .openCodeGo
        case .minimaxTokenPlanAPI:
            return .miniMax
        }
    }

    /// Method text for the one-line `State · method · age` status indicator.
    public var displayName: String {
        switch self {
        case .claudeWebSession:
            return "claude.ai web session"
        case .claudeOAuthAPI:
            return "OAuth usage API"
        case .claudeStatuslineCache:
            return "Statusline cache"
        case .codexAPI:
            return "ChatGPT API (local Codex credential)"
        case .codexAppServer:
            return "Codex desktop app"
        case .openCodeGoChromeCookie:
            return "Chrome cookie"
        case .minimaxTokenPlanAPI:
            return "MiniMax token plan API"
        }
    }

    /// Label for a single step in the per-provider retrieval chain UI, where the
    /// endpoint and the credential it uses are separated rather than parenthesised.
    /// Rendered by the expandable chain, not by the one-line status.
    public var chainStepName: String {
        switch self {
        case .claudeWebSession, .claudeOAuthAPI, .claudeStatuslineCache:
            return displayName
        case .codexAPI:
            return "ChatGPT API \u{00B7} Local Codex credential"
        case .codexAppServer:
            return "Codex app-server \u{00B7} Desktop sign-in"
        case .openCodeGoChromeCookie:
            return "Chrome cookie \u{00B7} opencode.ai"
        case .minimaxTokenPlanAPI:
            return "MiniMax token plan API (OpenCode key)"
        }
    }
}

public extension ProviderID {
    /// The provider's retrieval sources in the order they are attempted, which
    /// is also the order the chain UI numbers and lists them in. Claude is the
    /// only provider with more than one.
    var dataSourceChain: [ProviderDataSource] {
        switch self {
        case .claude:
            return [.claudeWebSession, .claudeOAuthAPI, .claudeStatuslineCache]
        case .codex:
            return [.codexAPI, .codexAppServer]
        case .openCodeGo:
            return [.openCodeGoChromeCookie]
        case .miniMax:
            return [.minimaxTokenPlanAPI]
        }
    }
}

/// What happened to one step of a provider's retrieval chain during a fetch.
public enum ProviderDataSourceStepOutcome: Equatable, Sendable {
    /// This step produced the data the app is showing.
    case used
    /// Never attempted, because an earlier step already succeeded.
    case standingBy
    /// Attempted and failed. The reason is recorded *for display only* — it does
    /// not necessarily become the provider's surfaced `StaleReason`. Claude's web
    /// path in particular fails silently by design: its reason lives here and
    /// never leaves the chain.
    case failed(StaleReason)
}

/// One step of a provider's retrieval chain: a source label and its outcome.
///
/// Like `ProviderDataSource` this is a *label plus a verdict*, never data — no
/// cookie, token, org ID or session key is carried, logged, or persisted.
public struct ProviderDataSourceStep: Equatable, Sendable {
    public let source: ProviderDataSource
    public let outcome: ProviderDataSourceStepOutcome

    public init(_ source: ProviderDataSource, _ outcome: ProviderDataSourceStepOutcome) {
        self.source = source
        self.outcome = outcome
    }

    /// Convenience for single-path providers, whose one step's outcome is
    /// exactly the fetch's outcome.
    public static func singlePath(
        _ source: ProviderDataSource,
        state: ProviderState
    ) -> ProviderDataSourceStep {
        switch state {
        case .fresh:
            return ProviderDataSourceStep(source, .used)
        case let .stale(last: _, reason: reason):
            return ProviderDataSourceStep(source, .failed(reason))
        case .hidden:
            return ProviderDataSourceStep(source, .standingBy)
        }
    }
}

/// A provider's fetch outcome plus the retrieval chain that produced it.
///
/// Carried alongside `ProviderState` rather than inside it so that adding source
/// reporting does not change `ProviderState`'s pattern arity or its `Equatable`
/// semantics — two states holding the same usage still compare equal regardless
/// of which path fetched them.
///
/// A provider reports only the steps it actually walked; the view model pads the
/// remainder of the declared chain as `standingBy`. `source` is derived: it is
/// the step that was `used`, and is `nil` whenever no path produced data (every
/// stale outcome) or when a provider reports no chain at all.
public struct ProviderFetchReport: Equatable, Sendable {
    public let state: ProviderState
    public let chain: [ProviderDataSourceStep]

    public var source: ProviderDataSource? {
        chain.first { $0.outcome == .used }?.source
    }

    public init(state: ProviderState, chain: [ProviderDataSourceStep]) {
        self.state = state
        self.chain = chain
    }

    /// Naming a single winning source is the same thing as a one-step chain
    /// whose only step was used; no winner means no steps to report.
    public init(state: ProviderState, source: ProviderDataSource? = nil) {
        self.state = state
        self.chain = source.map { [ProviderDataSourceStep($0, .used)] } ?? []
    }
}
