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
    /// OpenCode Go: `opencode.ai` with the read-only Chrome cookie.
    case openCodeGoChromeCookie

    public var provider: ProviderID {
        switch self {
        case .claudeWebSession, .claudeOAuthAPI, .claudeStatuslineCache:
            return .claude
        case .codexAPI:
            return .codex
        case .openCodeGoChromeCookie:
            return .openCodeGo
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
            return "ChatGPT API (Keychain token)"
        case .openCodeGoChromeCookie:
            return "Chrome cookie"
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
            return "ChatGPT API \u{00B7} Keychain token"
        case .openCodeGoChromeCookie:
            return "Chrome cookie \u{00B7} opencode.ai"
        }
    }
}

/// A provider's fetch outcome plus the source that produced it.
///
/// Carried alongside `ProviderState` rather than inside it so that adding source
/// reporting does not change `ProviderState`'s pattern arity or its `Equatable`
/// semantics — two states holding the same usage still compare equal regardless
/// of which path fetched them.
///
/// `source` is `nil` whenever no path produced data (every stale outcome) or
/// when a provider does not report one.
public struct ProviderFetchReport: Equatable, Sendable {
    public let state: ProviderState
    public let source: ProviderDataSource?

    public init(state: ProviderState, source: ProviderDataSource? = nil) {
        self.state = state
        self.source = source
    }
}
