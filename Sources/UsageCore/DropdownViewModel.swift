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
            if provider == .openCodeGo, states[provider] == nil {
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
    public let weekly: DropdownUsageWindowRow
    public let monthly: DropdownUsageWindowRow?
    public let fable: DropdownUsageWindowRow?
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
            self.weekly = DropdownUsageWindowRow(
                title: "Weekly",
                usageWindow: usage.weekly,
                now: now,
                calendar: calendar,
                locale: locale
            )
            self.monthly = usage.monthly.map {
                DropdownUsageWindowRow(title: "Monthly", usageWindow: $0, now: now, calendar: calendar, locale: locale)
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
            self.statusTone = tone(for: usage)
        case let .stale(last: usage?, reason: reason):
            self.isStale = true
            self.staleMessage = "Stale: \(reason.dropdownMessage)"
            self.fiveHour = DropdownUsageWindowRow.fiveHour(
                for: usage.fiveHour,
                now: now,
                calendar: calendar,
                locale: locale
            )
            self.weekly = DropdownUsageWindowRow(
                title: "Weekly",
                usageWindow: usage.weekly,
                now: now,
                calendar: calendar,
                locale: locale
            )
            self.monthly = usage.monthly.map {
                DropdownUsageWindowRow(title: "Monthly", usageWindow: $0, now: now, calendar: calendar, locale: locale)
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
            self.statusTone = tone(for: usage)
        case let .stale(last: nil, reason: reason):
            self.isStale = true
            self.staleMessage = "Stale: \(reason.dropdownMessage)"
            self.fiveHour = provider.showsFiveHourWindow
                ? DropdownUsageWindowRow.placeholder(title: "5h")
                : nil
            self.weekly = DropdownUsageWindowRow.placeholder(title: "Weekly")
            self.monthly = provider == .openCodeGo
                ? DropdownUsageWindowRow.placeholder(title: "Monthly")
                : nil
            self.fable = nil
            self.statusTone = nil
        case .hidden:
            self.isStale = false
            self.staleMessage = nil
            self.fiveHour = provider.showsFiveHourWindow
                ? DropdownUsageWindowRow.placeholder(title: "5h")
                : nil
            self.weekly = DropdownUsageWindowRow.placeholder(title: "Weekly")
            self.monthly = provider == .openCodeGo
                ? DropdownUsageWindowRow.placeholder(title: "Monthly")
                : nil
            self.fable = nil
            self.statusTone = nil
        }
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
        }
    }

    var showsFiveHourWindow: Bool {
        switch self {
        case .claude:
            return true
        case .codex:
            return false
        case .openCodeGo:
            return true
        }
    }
}

private extension StaleReason {
    var dropdownMessage: String {
        switch self {
        case .parseFailure:
            return "parse failure"
        case .networkError:
            return "network error"
        case .tokenExpired:
            return "token expired"
        case .credentialUnavailable:
            return "credential unavailable"
        case .workspaceSelectionRequired:
            return "select an OpenCode Go workspace in Settings"
        case .sessionExpired:
            return "OpenCode session expired; sign in again in Chrome"
        }
    }
}
