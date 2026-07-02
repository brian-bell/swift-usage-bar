import Foundation
import Testing
import UsageCore

@Test
func countdownFormatterUsesRelativeHoursAndMinutesUnderOneDay() throws {
    let calendar = deterministicCalendar()
    let now = try date(year: 2026, month: 1, day: 5, hour: 6, minute: 46, calendar: calendar)
    let resetAt = try #require(calendar.date(byAdding: .minute, value: 134, to: now))

    let text = CountdownFormatter.format(
        resetAt: resetAt,
        now: now,
        calendar: calendar,
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(text == "resets in 2h 14m")
}

@Test
func countdownFormatterUsesWeekdayAndTimeAtLeastOneDayOut() throws {
    let calendar = deterministicCalendar()
    let now = try date(year: 2026, month: 1, day: 5, hour: 9, minute: 0, calendar: calendar)
    let resetAt = try date(year: 2026, month: 1, day: 8, hour: 9, minute: 0, calendar: calendar)

    let text = CountdownFormatter.format(
        resetAt: resetAt,
        now: now,
        calendar: calendar,
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(text == "resets Thu 9:00 AM")
}

@Test
func countdownFormatterShowsResettingForPastResetDate() throws {
    let calendar = deterministicCalendar()
    let now = try date(year: 2026, month: 1, day: 5, hour: 9, minute: 0, calendar: calendar)
    let resetAt = try date(year: 2026, month: 1, day: 5, hour: 8, minute: 59, calendar: calendar)

    let text = CountdownFormatter.format(
        resetAt: resetAt,
        now: now,
        calendar: calendar,
        locale: Locale(identifier: "en_US_POSIX")
    )

    #expect(text == "resetting...")
}

private func deterministicCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func date(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    calendar: Calendar
) throws -> Date {
    try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    )))
}
