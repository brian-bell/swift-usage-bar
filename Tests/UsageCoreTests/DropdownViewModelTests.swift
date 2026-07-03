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
    #expect(row.fiveHour.percentLabel == "120%")
    #expect(row.fiveHour.barFraction == 1)
    #expect(row.fiveHour.countdownLabel == "resets in 1h 30m")
    #expect(row.weekly.percentLabel == "-20%")
    #expect(row.weekly.barFraction == 0)
    #expect(row.weekly.countdownLabel == "resets Thu 12:00 PM")
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
    #expect(row.fiveHour.percentLabel == "62%")
    #expect(row.weekly.percentLabel == "81%")
}

@Test
func dropdownRowsUsePlaceholdersForStaleProvidersWithoutData() throws {
    let model = DropdownViewModel(
        states: [.codex: .stale(last: nil, reason: .tokenExpired)],
        now: referenceNow,
        calendar: deterministicCalendar(),
        locale: Locale(identifier: "en_US_POSIX")
    )

    let row = try #require(model.rows.first)
    #expect(row.isStale)
    #expect(row.staleMessage == "Stale: token expired")
    #expect(row.fiveHour.percentLabel == "--")
    #expect(row.fiveHour.barFraction == 0)
    #expect(row.fiveHour.countdownLabel == "reset unknown")
    #expect(row.weekly.percentLabel == "--")
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
