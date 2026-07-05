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
    public let fiveHour: DropdownUsageWindowRow
    public let weekly: DropdownUsageWindowRow
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
            self.fiveHour = DropdownUsageWindowRow(
                title: "5h",
                usageWindow: usage.fiveHour,
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
            self.fiveHour = DropdownUsageWindowRow(
                title: "5h",
                usageWindow: usage.fiveHour,
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
            self.fiveHour = DropdownUsageWindowRow.placeholder(title: "5h")
            self.weekly = DropdownUsageWindowRow.placeholder(title: "Weekly")
            self.fable = nil
            self.statusTone = nil
        case .hidden:
            self.isStale = false
            self.staleMessage = nil
            self.fiveHour = DropdownUsageWindowRow.placeholder(title: "5h")
            self.weekly = DropdownUsageWindowRow.placeholder(title: "Weekly")
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
        self.percentLabel = "\(usageWindow.percentRemaining)%"
        self.barFraction = Double(min(100, max(0, usageWindow.percentRemaining))) / 100
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
        }
    }
}
