import Foundation

public struct DropdownViewModel: Equatable, Sendable {
    public let rows: [DropdownProviderRow]
    public let updatedLabel: String?

    public init(
        states: [ProviderID: ProviderState],
        lastUpdatedAt: [ProviderID: Date] = [:],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) {
        let rows = ProviderID.allCases.compactMap { provider -> DropdownProviderRow? in
            if Self.defaultHiddenProviders.contains(provider), states[provider] == nil {
                return nil
            }
            let state = states[provider] ?? .stale(last: nil, reason: .networkError)
            guard state != .hidden else {
                return nil
            }

            return DropdownProviderRow(
                provider: provider,
                state: state,
                lastUpdatedAt: lastUpdatedAt[provider],
                now: now,
                calendar: calendar,
                locale: locale
            )
        }
        self.rows = rows
        self.updatedLabel = rows
            .compactMap { row in lastUpdatedAt[row.provider] }
            .max()
            .map { formatUpdatedLabel(updatedAt: $0, now: now) }
    }

    /// Providers that ship hidden and don't render a placeholder row until they
    /// report at least once — both the menu bar title and the dropdown skip them
    /// when they have no state, by design. The membership lives on `ProviderID`
    /// so every site that needs to special-case a default-hidden provider reads
    /// the same source of truth.
    static let defaultHiddenProviders: Set<ProviderID> = ProviderID.defaultHiddenProviders
}

public struct DropdownProviderRow: Equatable, Identifiable, Sendable {
    public var id: ProviderID { provider }

    public let provider: ProviderID
    public let providerName: String
    public let isStale: Bool
    public let staleMessage: String?
    public let updatedLabel: String?
    /// `nil` when the provider does not expose a 5-hour window (Codex is weekly-only).
    public let fiveHour: DropdownUsageWindowRow?
    /// `nil` when the provider has no weekly window (OpenCode Credits is a
    /// balance, not a set of percent windows).
    public let weekly: DropdownUsageWindowRow?
    public let monthly: DropdownUsageWindowRow?
    public let fable: DropdownUsageWindowRow?
    /// Workspace credit balance — the OpenCode Credits provider's one row.
    /// Never participates in tone, threshold, or the menu-bar percent scale.
    public let credits: DropdownCreditsRow?
    public let statusTone: UsageStatusTone?

    fileprivate init(
        provider: ProviderID,
        state: ProviderState,
        lastUpdatedAt: Date?,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) {
        self.provider = provider
        self.providerName = provider.dropdownDisplayName
        self.updatedLabel = lastUpdatedAt.map { formatUpdatedLabel(updatedAt: $0, now: now) }

        switch state {
        case let .fresh(usage, asOf: _):
            self.isStale = false
            self.staleMessage = nil
            self.fiveHour = DropdownUsageWindowRow.fiveHour(
                for: usage.fiveHour,
                now: now,
                calendar: calendar,
                locale: locale
            )
            self.weekly = provider.weeklyRow(
                for: usage.weekly,
                now: now,
                calendar: calendar,
                locale: locale
            )
            self.monthly = usage.monthly.map {
                DropdownUsageWindowRow(
                    title: provider.monthlyDropdownTitle,
                    usageWindow: $0,
                    now: now,
                    calendar: calendar,
                    locale: locale
                )
            }
            self.fable = usage.fable.map { fable in
                DropdownUsageWindowRow(
                    title: "Fable",
                    usageWindow: fable,
                    now: now,
                    calendar: calendar,
                    locale: locale
                )
            }
            self.credits = usage.credits.map { DropdownCreditsRow(credits: $0, locale: locale) }
            self.statusTone = tone(for: usage)
        case let .stale(last: usage?, reason: reason):
            self.isStale = true
            self.staleMessage = "Stale: \(reason.dropdownMessage(for: provider))"
            self.fiveHour = DropdownUsageWindowRow.fiveHour(
                for: usage.fiveHour,
                now: now,
                calendar: calendar,
                locale: locale
            )
            self.weekly = provider.weeklyRow(
                for: usage.weekly,
                now: now,
                calendar: calendar,
                locale: locale
            )
            self.monthly = usage.monthly.map {
                DropdownUsageWindowRow(
                    title: provider.monthlyDropdownTitle,
                    usageWindow: $0,
                    now: now,
                    calendar: calendar,
                    locale: locale
                )
            }
            self.fable = usage.fable.map { fable in
                DropdownUsageWindowRow(
                    title: "Fable",
                    usageWindow: fable,
                    now: now,
                    calendar: calendar,
                    locale: locale
                )
            }
            self.credits = usage.credits.map { DropdownCreditsRow(credits: $0, locale: locale) }
            self.statusTone = tone(for: usage)
        case let .stale(last: nil, reason: reason):
            self.isStale = true
            self.staleMessage = "Stale: \(reason.dropdownMessage(for: provider))"
            self.fiveHour = provider.showsFiveHourWindow
                ? DropdownUsageWindowRow.placeholder(title: "5h")
                : nil
            self.weekly = provider.showsWeeklyWindow
                ? DropdownUsageWindowRow.placeholder(title: provider.weeklyDropdownTitle)
                : nil
            self.monthly = provider.showsMonthlyPlaceholder
                ? DropdownUsageWindowRow.placeholder(title: provider.monthlyDropdownTitle)
                : nil
            self.fable = nil
            self.credits = provider == .openCodeCredits ? .placeholder : nil
            self.statusTone = nil
        case .hidden:
            self.isStale = false
            self.staleMessage = nil
            self.fiveHour = provider.showsFiveHourWindow
                ? DropdownUsageWindowRow.placeholder(title: "5h")
                : nil
            self.weekly = provider.showsWeeklyWindow
                ? DropdownUsageWindowRow.placeholder(title: provider.weeklyDropdownTitle)
                : nil
            self.monthly = provider.showsMonthlyPlaceholder
                ? DropdownUsageWindowRow.placeholder(title: provider.monthlyDropdownTitle)
                : nil
            self.fable = nil
            self.credits = provider == .openCodeCredits ? .placeholder : nil
            self.statusTone = nil
        }
    }
}

/// Workspace credit balance, formatted for the dropdown. The row is purely
/// presentational — no scaling, no threshold participation.
/// Mirrors the window rows' label/bar split: `amountLabel` is unclamped
/// (overspend renders "$-10.00 remaining") while `barFraction` clamps to
/// 0...1. `limitLabel` fills the windows' countdown slot with the allowance
/// the bar is charted against ("$50 monthly limit"), using raw `Int`
/// interpolation for the dollar figure — limits are small whole dollars, so
/// a grouping-separator surprise at $1,000+ would be more confusing than
/// helpful. When either monthly field is missing — or the limit is
/// non-positive, which has no meaningful fraction — the row degrades to the
/// wallet balance alone with `barFraction == nil` (an empty bar next to a
/// real balance would falsely read "0 remaining") and `limitLabel == nil`.
public struct DropdownCreditsRow: Equatable, Sendable {
    public let title: String
    public let amountLabel: String
    public let barFraction: Double?
    public let limitLabel: String?

    public init(credits: CreditBalance, locale: Locale) {
        self.title = "Credits"
        if let monthlyUsed = credits.monthlyUsedUSD,
           let monthlyLimit = credits.monthlyLimitUSD,
           monthlyLimit > 0 {
            let remaining = Double(monthlyLimit) - monthlyUsed
            self.amountLabel = "\(Self.formatCurrency(remaining, locale: locale)) remaining"
            self.barFraction = min(1, max(0, remaining / Double(monthlyLimit)))
            self.limitLabel = "$\(monthlyLimit) monthly limit"
        } else {
            self.amountLabel = Self.formatCurrency(credits.balanceUSD, locale: locale)
            self.barFraction = nil
            self.limitLabel = nil
        }
    }

    private static func formatCurrency(_ amount: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.locale = locale
        let formatted = formatter.string(from: amount as NSNumber) ?? "\(amount)"
        return "$" + formatted
    }

    /// The credits provider's row before it has ever produced data —
    /// mirrors the window rows' `--` placeholder rather than inventing $0.
    /// Unlike the balance-only fallback, the empty bar is fine here: next
    /// to `--` it reads as "no data yet", not "0 remaining".
    static let placeholder = DropdownCreditsRow(
        title: "Credits",
        amountLabel: "--",
        barFraction: 0,
        limitLabel: nil
    )

    private init(title: String, amountLabel: String, barFraction: Double?, limitLabel: String?) {
        self.title = title
        self.amountLabel = amountLabel
        self.barFraction = barFraction
        self.limitLabel = limitLabel
    }
}

private func formatUpdatedLabel(updatedAt: Date, now: Date) -> String {
    let elapsedSeconds = max(0, Int(now.timeIntervalSince(updatedAt)))
    if elapsedSeconds < 60 {
        return "Updated just now"
    }

    let elapsedMinutes = elapsedSeconds / 60
    if elapsedMinutes < 60 {
        return "Updated \(elapsedMinutes)m ago"
    }

    let elapsedHours = elapsedMinutes / 60
    return "Updated \(elapsedHours)h ago"
}

public struct DropdownUsageWindowRow: Equatable, Sendable {
    public let title: String
    public let percentLabel: String
    public let barFraction: Double
    public let countdownLabel: String

    fileprivate init(
        title: String,
        usageWindow: UsageWindow,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) {
        self.title = title
        if let percentRemaining = usageWindow.percentRemaining {
            self.percentLabel = "\(percentRemaining)% remaining"
            self.barFraction = Double(min(100, max(0, percentRemaining))) / 100
        } else {
            self.percentLabel = "--"
            self.barFraction = 0
        }
        if let resetsAt = usageWindow.resetsAt {
            self.countdownLabel = CountdownFormatter.format(
                resetAt: resetsAt,
                now: now,
                calendar: calendar,
                locale: locale
            )
        } else {
            self.countdownLabel = "reset unknown"
        }
    }

    fileprivate static func placeholder(title: String) -> DropdownUsageWindowRow {
        DropdownUsageWindowRow(
            title: title,
            percentLabel: "--",
            barFraction: 0,
            countdownLabel: "reset unknown"
        )
    }

    /// Omit the 5h row when the window is unavailable (Codex weekly-only).
    fileprivate static func fiveHour(
        for usageWindow: UsageWindow,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> DropdownUsageWindowRow? {
        guard usageWindow.percentRemaining != nil else {
            return nil
        }

        return DropdownUsageWindowRow(
            title: "5h",
            usageWindow: usageWindow,
            now: now,
            calendar: calendar,
            locale: locale
        )
    }

    private init(
        title: String,
        percentLabel: String,
        barFraction: Double,
        countdownLabel: String
    ) {
        self.title = title
        self.percentLabel = percentLabel
        self.barFraction = barFraction
        self.countdownLabel = countdownLabel
    }
}

private extension ProviderID {
    var dropdownDisplayName: String {
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
        case .cursor:
            return "Cursor"
        }
    }

    var weeklyDropdownTitle: String {
        // 52pt title column: "Cursor" / "Other" match "Weekly" / "Fable".
        self == .cursor ? "Cursor" : "Weekly"
    }

    var monthlyDropdownTitle: String {
        self == .cursor ? "Other" : "Monthly"
    }

    var showsMonthlyPlaceholder: Bool {
        self == .openCodeGo || self == .cursor
    }

    /// Cursor's first-party pool lives in `weekly` and is omitted (Fable rule)
    /// when the payload doesn't carry `autoPercentUsed`.
    func weeklyRow(
        for usageWindow: UsageWindow,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> DropdownUsageWindowRow? {
        guard showsWeeklyWindow else {
            return nil
        }
        if self == .cursor, usageWindow.percentRemaining == nil {
            return nil
        }
        return DropdownUsageWindowRow(
            title: weeklyDropdownTitle,
            usageWindow: usageWindow,
            now: now,
            calendar: calendar,
            locale: locale
        )
    }

    var showsFiveHourWindow: Bool {
        switch self {
        case .claude:
            return true
        case .codex:
            return false
        case .openCodeGo:
            return true
        case .openCodeCredits:
            return false
        case .miniMax:
            return true
        case .cursor:
            return false
        }
    }

    /// Everything except the credits provider has a weekly window; its row
    /// is the dollar balance alone.
    var showsWeeklyWindow: Bool {
        self != .openCodeCredits
    }
}

private extension StaleReason {
    /// One-line stale hint rendered inside a provider's dropdown row. Takes
    /// the provider so the message names the failing subsystem — without
    /// this, MiniMax would inherit OpenCode-specific wording like "sign in
    /// again in Chrome" and tell the user to fix the wrong service.
    func dropdownMessage(for provider: ProviderID) -> String {
        switch self {
        case .parseFailure:
            return "parse failure"
        case .networkError:
            return "network error"
        case .tokenExpired:
            switch provider {
            case .miniMax:
                // The MiniMax API reports a rejected key as
                // `base_resp.status_code == 1004` (docs/PLAN-minimax.md),
                // which Slice 2 will map to `.tokenExpired`. The dropdown
                // must say so; the generic "token expired" makes it look
                // like an OAuth/Keychain expiry.
                return "MiniMax key rejected; re-authenticate in OpenCode"
            case .claude, .codex, .openCodeGo, .openCodeCredits, .cursor:
                return "token expired"
            }
        case .credentialUnavailable:
            switch provider {
            case .openCodeCredits:
                // For credits, "no credential" is most often "no billing
                // configured on the workspace" — the cookie itself was fine.
                return "no credits balance found"
            case .claude, .codex, .openCodeGo, .miniMax, .cursor:
                return "credential unavailable"
            }
        case .workspaceSelectionRequired:
            switch provider {
            case .openCodeGo:
                return "select an OpenCode Go workspace in Settings"
            case .openCodeCredits:
                return "select an OpenCode workspace in Settings"
            case .claude, .codex, .miniMax, .cursor:
                // Unreachable in practice (no other provider surfaces this
                // reason today), but the alternative would be to point
                // Claude/Codex/MiniMax at a Settings field that only
                // exists for OpenCode Go.
                return "workspace selection required"
            }
        case .sessionExpired:
            switch provider {
            case .openCodeGo, .openCodeCredits:
                return "OpenCode session expired; sign in again in Chrome"
            case .claude:
                return "claude.ai session expired; sign in again in Chrome"
            case .codex:
                return "Codex session expired; sign in again in the Codex app"
            case .miniMax:
                // Unreachable today (MiniMax never surfaces `.sessionExpired`
                // per its failure mapping) but kept consistent with the row
                // and chain-step wording should the mapping widen.
                return "MiniMax key rejected; re-authenticate in OpenCode"
            case .cursor:
                return "Cursor session expired; sign in again in the Cursor app"
            }
        }
    }
}
