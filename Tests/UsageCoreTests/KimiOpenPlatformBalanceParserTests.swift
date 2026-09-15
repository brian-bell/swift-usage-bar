import Foundation
import Testing
import UsageCore

@Test
func kimiOpenPlatformParserReadsAvailableBalanceFromLiveFixture() throws {
    let credits = try KimiOpenPlatformBalanceParser().parse(
        fixtureData("kimi-open-platform-balance.json")
    )

    #expect(credits == CreditBalance(balanceUSD: 12.34))
}

@Test
func kimiOpenPlatformParserCannotLeakPaymentMetadata() throws {
    // CreditBalance is numeric-only. The fixture carries voucher/cash
    // split fields; the parsed value must equal a wallet constructed from
    // available_balance alone.
    let credits = try KimiOpenPlatformBalanceParser().parse(
        fixtureData("kimi-open-platform-balance.json")
    )

    #expect(credits.monthlyUsedUSD == nil)
    #expect(credits.monthlyLimitUSD == nil)
    #expect(credits == CreditBalance(balanceUSD: 12.34))
}

@Test
func kimiOpenPlatformParserIgnoresVoucherAndCashSplit() throws {
    let body = Data("""
    {
      "code": 0,
      "status": true,
      "data": {
        "available_balance": 12.34,
        "voucher_balance": 999,
        "cash_balance": -4.56
      }
    }
    """.utf8)

    #expect(try KimiOpenPlatformBalanceParser().parse(body) == CreditBalance(balanceUSD: 12.34))
}

@Test
func kimiOpenPlatformParserAcceptsIntegerAvailableBalance() throws {
    // JSONDecoder maps a JSON integer onto Double; a whole-dollar wallet
    // is a real observed-adjacent shape (voucher_balance was an int live).
    let body = Data("""
    {"code":0,"status":true,"data":{"available_balance":12}}
    """.utf8)

    #expect(try KimiOpenPlatformBalanceParser().parse(body) == CreditBalance(balanceUSD: 12))
}

@Test
func kimiOpenPlatformParserAcceptsZeroAndNegativeAvailableBalance() throws {
    // Official docs: available_balance ≤ 0 blocks inference; cash can go
    // negative. Zero is a real wallet, not "no credential".
    let zero = Data("""
    {"code":0,"status":true,"data":{"available_balance":0}}
    """.utf8)
    let negative = Data("""
    {"code":0,"status":true,"data":{"available_balance":-1.5}}
    """.utf8)

    #expect(try KimiOpenPlatformBalanceParser().parse(zero) == CreditBalance(balanceUSD: 0))
    #expect(try KimiOpenPlatformBalanceParser().parse(negative) == CreditBalance(balanceUSD: -1.5))
}

@Test
func kimiOpenPlatformParserThrowsWhenCodeIsNonZero() {
    let body = Data("""
    {"code":1,"status":true,"data":{"available_balance":12.34}}
    """.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try KimiOpenPlatformBalanceParser().parse(body)
    }
}

@Test
func kimiOpenPlatformParserThrowsWhenStatusIsFalse() {
    let body = Data("""
    {"code":0,"status":false,"data":{"available_balance":12.34}}
    """.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try KimiOpenPlatformBalanceParser().parse(body)
    }
}

@Test
func kimiOpenPlatformParserThrowsWhenAvailableBalanceIsMissing() {
    let body = Data("""
    {"code":0,"status":true,"data":{"voucher_balance":10,"cash_balance":2.34}}
    """.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try KimiOpenPlatformBalanceParser().parse(body)
    }
}

@Test
func kimiOpenPlatformParserThrowsWhenAvailableBalanceIsAString() {
    // No string-number alias. The live capture and the official schema
    // both use a JSON number.
    let body = Data("""
    {"code":0,"status":true,"data":{"available_balance":"12.34"}}
    """.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try KimiOpenPlatformBalanceParser().parse(body)
    }
}

@Test
func kimiOpenPlatformParserThrowsOnNonJSON() {
    #expect(throws: UsageParsingError.parseFailure) {
        try KimiOpenPlatformBalanceParser().parse(Data("not json".utf8))
    }
}

@Test
func kimiOpenPlatformParserDoesNotReadRejectedKeyErrorBody() {
    // Official 401 body is `error.{message,type}`. Auth failure is
    // HTTP-shaped and owned by the transport; the parser must not invent
    // a tokenExpired mapping from this payload.
    let body = Data("""
    {"error":{"message":"Invalid Authentication","type":"invalid_authentication_error"}}
    """.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try KimiOpenPlatformBalanceParser().parse(body)
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
