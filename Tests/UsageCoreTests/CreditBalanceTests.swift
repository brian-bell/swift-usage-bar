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
    // The dropdown omits remaining / bar / limit when this is nil and
    // shows the wallet alone. The menu bar always uses balanceUSD.
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
