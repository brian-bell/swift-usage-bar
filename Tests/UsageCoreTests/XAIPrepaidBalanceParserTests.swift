import Foundation
import Testing
import UsageCore

@Test
func xaiPrepaidParserReadsInvertedCentsFromFixture() throws {
    let credits = try XAIPrepaidBalanceParser().parse(
        fixtureData("xai-prepaid-balance.json")
    )

    #expect(credits == CreditBalance(balanceUSD: 10))
}

@Test
func xaiPrepaidParserCannotLeakPaymentMetadata() throws {
    let credits = try XAIPrepaidBalanceParser().parse(
        fixtureData("xai-prepaid-balance.json")
    )

    #expect(credits.monthlyUsedUSD == nil)
    #expect(credits.monthlyLimitUSD == nil)
    #expect(credits == CreditBalance(balanceUSD: 10))
}

@Test
func xaiPrepaidParserIgnoresChangesArray() throws {
    let body = Data("""
    {
      "changes": [{
        "teamId": "ffffffff-ffff-4fff-8fff-ffffffffffff",
        "invoiceId": "should-not-surface",
        "invoiceNumber": "999-999-999-999",
        "paymentProcessor": {"kind": "STRIPE"},
        "amount": {"val": "-999999"}
      }],
      "total": {"val": "-250"}
    }
    """.utf8)

    #expect(try XAIPrepaidBalanceParser().parse(body) == CreditBalance(balanceUSD: 2.5))
}

@Test
func xaiPrepaidParserDoesNotReadUnofficialRemainingBalance() {
    let body = Data("""
    {"remaining_balance": 12.34, "spent_balance": 1, "total_granted": 20}
    """.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try XAIPrepaidBalanceParser().parse(body)
    }
}

@Test
func xaiPrepaidParserPrefersOfficialTotalWhenRemainingBalanceIsAlsoPresent() throws {
    let body = Data("""
    {"remaining_balance": 99, "total": {"val": "-1000"}}
    """.utf8)

    #expect(try XAIPrepaidBalanceParser().parse(body) == CreditBalance(balanceUSD: 10))
}

@Test
func xaiPrepaidParserThrowsWhenTotalIsMissing() {
    let body = Data("""
    {"changes": []}
    """.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try XAIPrepaidBalanceParser().parse(body)
    }
}

@Test
func xaiPrepaidParserThrowsWhenValIsNotAnIntegerString() {
    let body = Data("""
    {"total": {"val": "-1000.5"}}
    """.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try XAIPrepaidBalanceParser().parse(body)
    }
}

@Test
func xaiPrepaidParserThrowsWhenValIsAJSONNumber() {
    let body = Data("""
    {"total": {"val": -1000}}
    """.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try XAIPrepaidBalanceParser().parse(body)
    }
}

@Test
func xaiPrepaidParserAcceptsZeroValAsEmptyWallet() throws {
    let body = Data("""
    {"total": {"val": "0"}}
    """.utf8)

    #expect(try XAIPrepaidBalanceParser().parse(body) == CreditBalance(balanceUSD: 0))
}

@Test
func xaiPrepaidParserThrowsOnNonJSON() {
    #expect(throws: UsageParsingError.parseFailure) {
        try XAIPrepaidBalanceParser().parse(Data("not json".utf8))
    }
}

@Test
func xaiPrepaidParserDoesNotReadSnakeCaseAliases() {
    let body = Data("""
    {"total_val": "-1000"}
    """.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try XAIPrepaidBalanceParser().parse(body)
    }
}

private func fixtureData(_ name: String) throws -> Data {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(
        contentsOf: packageRoot
            .appendingPathComponent("Tests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    )
}
