import Foundation
import Testing
import UsageCore

@Test
func dropdownRowsUseStableProviderOrderAndOmitHiddenProviders() throws {
    let model = DropdownViewModel(
        states: [
            .codex: .fresh(codexUsage, asOf: referenceNow),
            .claude: .hidden,
        ],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(model.rows.map(\.provider) == [.codex])
    #expect(model.rows.map(\.providerName) == ["Codex"])
}

@Test
func dropdownRowsExposeClampedFractionsLabelsAndCountdowns() throws {
    let usage = ProviderUsage(
        fiveHour: UsageWindow(
            percentRemaining: 120,
            resetsAt: referenceNow.addingTimeInterval(90 * 60)
        ),
        weekly: UsageWindow(
            percentRemaining: -20,
            resetsAt: referenceNow.addingTimeInterval(3 * 24 * 60 * 60)
        )
    )

    let model = DropdownViewModel(
        states: [.claude: .fresh(usage, asOf: referenceNow)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first)
    #expect(row.fiveHour.percentLabel == "120% remaining")
    #expect(row.fiveHour.barFraction == 1)
    #expect(row.fiveHour.countdownLabel == "resets in 1h 30m")
    #expect(row.weekly.percentLabel == "-20% remaining")
    #expect(row.weekly.barFraction == 0)
    // referenceNow (2026-01-01 12:00 UTC) is a Thursday; +3 days is Sunday.
    #expect(row.weekly.countdownLabel == "resets Sun 12:00 PM")
}

@Test
func dropdownRowsShowUnavailableFreshWindowWithoutMarkingProviderStale() throws {
    let usage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 76, resetsAt: referenceNow.addingTimeInterval(60 * 60)),
        weekly: UsageWindow(percentRemaining: nil, resetsAt: nil)
    )
    let model = DropdownViewModel(
        states: [.codex: .fresh(usage, asOf: referenceNow)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == .codex })
    #expect(!row.isStale)
    #expect(row.fiveHour.percentLabel == "76% remaining")
    #expect(row.weekly.percentLabel == "--")
    #expect(row.weekly.barFraction == 0)
    #expect(row.weekly.countdownLabel == "reset unknown")
}

@Test
func dropdownRowsExposeFableWindowOnlyWhenPresent() throws {
    let withFable = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 62, resetsAt: referenceNow.addingTimeInterval(2 * 60 * 60)),
        weekly: UsageWindow(percentRemaining: 81, resetsAt: referenceNow.addingTimeInterval(5 * 24 * 60 * 60)),
        fable: UsageWindow(percentRemaining: 56, resetsAt: referenceNow.addingTimeInterval(90 * 60))
    )

    let model = DropdownViewModel(
        states: [
            .claude: .fresh(withFable, asOf: referenceNow),
            .codex: .fresh(codexUsage, asOf: referenceNow),
        ],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let claudeRow = try #require(model.rows.first { $0.provider == .claude })
    let fable = try #require(claudeRow.fable)
    #expect(fable.title == "Fable")
    #expect(fable.percentLabel == "56% remaining")
    #expect(fable.countdownLabel == "resets in 1h 30m")

    let codexRow = try #require(model.rows.first { $0.provider == .codex })
    #expect(codexRow.fable == nil)
}

@Test
func dropdownRowsFlagStaleProvidersWhilePreservingLastKnownValues() throws {
    let model = DropdownViewModel(
        states: [.claude: .stale(last: claudeUsage, reason: .networkError)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first)
    #expect(row.isStale)
    #expect(row.staleMessage == "Stale: network error")
    #expect(row.fiveHour.percentLabel == "62% remaining")
    #expect(row.weekly.percentLabel == "81% remaining")
}

@Test
func dropdownRowsUsePlaceholdersForStaleProvidersWithoutData() throws {
    let model = DropdownViewModel(
        states: [.codex: .stale(last: nil, reason: .tokenExpired)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == .codex })
    #expect(row.isStale)
    #expect(row.staleMessage == "Stale: token expired")
    #expect(row.fiveHour.percentLabel == "--")
    #expect(row.fiveHour.barFraction == 0)
    #expect(row.fiveHour.countdownLabel == "reset unknown")
    #expect(row.weekly.percentLabel == "--")
}

@Test(arguments: [
    (StaleReason.parseFailure, "Stale: parse failure"),
    (StaleReason.networkError, "Stale: network error"),
    (StaleReason.tokenExpired, "Stale: token expired"),
    (StaleReason.credentialUnavailable, "Stale: credential unavailable"),
])
func dropdownStaleMessageMatchesStaleReason(reason: StaleReason, expectedMessage: String) throws {
    let model = DropdownViewModel(
        states: [.claude: .stale(last: nil, reason: reason)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first { $0.provider == .claude })
    #expect(row.staleMessage == expectedMessage)
}

@Test
func dropdownSummaryUsesMostRecentVisibleProviderUpdate() {
    let model = DropdownViewModel(
        states: [
            .claude: .fresh(claudeUsage, asOf: referenceNow),
            .codex: .fresh(codexUsage, asOf: referenceNow),
        ],
        lastUpdatedAt: [
            .claude: referenceNow.addingTimeInterval(-10 * 60),
            .codex: referenceNow.addingTimeInterval(-2 * 60),
        ],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(model.updatedLabel == "Updated 2m ago")
}

@Test
func dropdownSummaryIgnoresHiddenProviderUpdates() {
    let model = DropdownViewModel(
        states: [
            .claude: .hidden,
            .codex: .fresh(codexUsage, asOf: referenceNow),
        ],
        lastUpdatedAt: [
            .claude: referenceNow,
            .codex: referenceNow.addingTimeInterval(-3 * 60),
        ],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(model.updatedLabel == "Updated 3m ago")
}

@Test
func dropdownSummaryIsNilWhenAllProvidersAreHidden() {
    let model = DropdownViewModel(
        states: [
            .claude: .hidden,
            .codex: .hidden,
        ],
        lastUpdatedAt: [
            .claude: referenceNow,
            .codex: referenceNow,
        ],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(model.rows.isEmpty)
    #expect(model.updatedLabel == nil)
}

@Test
func dropdownSummaryIsNilWhenVisibleProvidersHaveNoUpdateTimestamp() {
    let model = DropdownViewModel(
        states: [.claude: .fresh(claudeUsage, asOf: referenceNow)],
        lastUpdatedAt: [:],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(model.rows.map(\.provider) == [.claude, .codex])
    #expect(model.updatedLabel == nil)
}

private let referenceNow = Date(timeIntervalSince1970: 1_767_268_800) // 2026-01-01 12:00 UTC

private let claudeUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 62, resetsAt: referenceNow.addingTimeInterval(2 * 60 * 60)),
    weekly: UsageWindow(percentRemaining: 81, resetsAt: referenceNow.addingTimeInterval(5 * 24 * 60 * 60))
)

private let codexUsage = ProviderUsage(
    fiveHour: UsageWindow(percentRemaining: 72, resetsAt: referenceNow.addingTimeInterval(3 * 60 * 60)),
    weekly: UsageWindow(percentRemaining: 90, resetsAt: referenceNow.addingTimeInterval(6 * 24 * 60 * 60))
)

private func deterministicCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
