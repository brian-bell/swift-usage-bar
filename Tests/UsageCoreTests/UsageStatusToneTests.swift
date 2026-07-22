import Foundation
import Testing
import UsageCore

@Test
func statusToneIsNormalWhenMinimumRemainingMeetsWarningThreshold() {
    let usage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 20, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 40, resetsAt: nil)
    )

    #expect(tone(for: usage, warningThreshold: 20) == .normal)
}

@Test
func statusToneIsWarningWhenMinimumRemainingIsBelowWarningThreshold() {
    let usage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 19, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 40, resetsAt: nil)
    )

    #expect(tone(for: usage, warningThreshold: 20) == .warning)
}

@Test
func statusToneIsCriticalBelowFiveEvenWhenWarningThresholdIsLower() {
    let usage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 4, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 40, resetsAt: nil)
    )

    #expect(tone(for: usage, warningThreshold: 3) == .critical)
}

@Test
func statusToneUsesMinimumRemainingAcrossFiveHourAndWeeklyWindows() {
    let usage = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 90, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 19, resetsAt: nil)
    )

    #expect(tone(for: usage, warningThreshold: 20) == .warning)
}

@Test
func statusToneIncludesMonthlyButStillExcludesFable() {
    let monthlyWarning = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 90, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 80, resetsAt: nil),
        monthly: UsageWindow(percentRemaining: 19, resetsAt: nil),
        fable: UsageWindow(percentRemaining: 1, resetsAt: nil)
    )
    let fableOnlyWarning = ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: 90, resetsAt: nil),
        weekly: UsageWindow(percentRemaining: 80, resetsAt: nil),
        fable: UsageWindow(percentRemaining: 1, resetsAt: nil)
    )

    #expect(tone(for: monthlyWarning, warningThreshold: 20) == .warning)
    #expect(tone(for: fableOnlyWarning, warningThreshold: 20) == .normal)
}
