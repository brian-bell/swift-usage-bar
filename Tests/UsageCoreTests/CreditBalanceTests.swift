import Testing
import UsageCore

@Test
func creditBalanceMonthlyRemainingIsLimitMinusUsed() {
    let credits = CreditBalance(
        balanceUSD: 6.40,
        monthlyUsedUSD: 36.04,
        monthlyLimitUSD: 50
    )
    #expect(credits.monthlyRemainingUSD == 13.96)
}

@Test
func creditBalanceMonthlyRemainingIsNilWithoutAChartableAllowance() {
    // The menu bar and dropdown share this nil: both degrade to the
    // wallet balance when remaining cannot be charted.
    #expect(CreditBalance(balanceUSD: 6.40).monthlyRemainingUSD == nil)
    #expect(
        CreditBalance(balanceUSD: 6.40, monthlyUsedUSD: nil, monthlyLimitUSD: 50)
            .monthlyRemainingUSD == nil
    )
    #expect(
        CreditBalance(balanceUSD: 6.40, monthlyUsedUSD: 2, monthlyLimitUSD: 0)
            .monthlyRemainingUSD == nil
    )
}
