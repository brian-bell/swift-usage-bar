import Foundation
import Testing
import UsageCore

// The credits provider owns the billing record: unlike the Go parser (for
// which the record is a foreign object to skip past), drift in a *configured*
// record must surface as a parse failure here, while an unconfigured
// workspace is a legitimate nil — "no credits", never $0.00 and never an
// error.

@Test
func openCodeCreditsParserExtractsBalanceFromBillingFixture() throws {
    // Fixture (synthetic): balance:12345678 / monthlyUsage:87654321 /
    // monthlyLimit:99, 10⁻⁸ dollars for the first two.
    let credits = try #require(
        try OpenCodeCreditsParser().parse(fixtureData("opencode-go-usage-billing.html")),
        "The billing fixture carries a configured record"
    )

    #expect(abs(credits.balanceUSD - (12345678.0 / 100_000_000)) < 1e-9)
    let monthlyUsed = try #require(credits.monthlyUsedUSD)
    #expect(abs(monthlyUsed - (87654321.0 / 100_000_000)) < 1e-9)
    #expect(credits.monthlyLimitUSD == 99)
}

@Test
func openCodeCreditsParserCannotLeakPaymentMetadata() throws {
    // CreditBalance has no fields for payment metadata (customerID,
    // paymentMethodID, subscription, lite, …), so the parsed result must be
    // value-equal to one constructed from the three numbers alone. The
    // structural limit on the type is the privacy guarantee.
    let credits = try OpenCodeCreditsParser().parse(
        fixtureData("opencode-go-usage-billing.html")
    )

    #expect(credits == CreditBalance(
        balanceUSD: 12345678.0 / 100_000_000,
        monthlyUsedUSD: 87654321.0 / 100_000_000,
        monthlyLimitUSD: 99
    ))
}

@Test
func openCodeCreditsParserReturnsNilWhenBillingIsNotOnThePage() throws {
    // The Go-only fixture is a valid workspace page with no billing record:
    // "billing not configured", not an error. Discovery uses this verdict to
    // reject the workspace as a credits candidate.
    #expect(try OpenCodeCreditsParser().parse(fixtureData("opencode-go-usage.html")) == nil)
}

@Test
func openCodeCreditsParserReturnsNilWhenCustomerIDIsNull() throws {
    // customerID:null is the sentinel for "billing is not configured"; a
    // fabricated $0.00 would claim a balance that does not exist.
    let data = Data(#"""
    ((self.$R=self.$R||{}),$R[1]={customerID:null,balance:0,monthlyLimit:0,monthlyUsage:0});
    """#.utf8)

    #expect(try OpenCodeCreditsParser().parse(data) == nil)
}

@Test
func openCodeCreditsParserThrowsWhenConfiguredBalanceIsMalformed() {
    // A configured record (non-null customerID) whose shape has drifted is a
    // parse failure for the provider whose product it is — silent nil here
    // would render as "billing not configured" and hide real drift.
    let data = Data(#"""
    ((self.$R=self.$R||{}),$R[1]={customerID:"cus_x",balance:abc,monthlyLimit:50,monthlyUsage:200000000});
    """#.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try OpenCodeCreditsParser().parse(data)
    }
}

@Test(arguments: ["null", "abc"])
func openCodeCreditsParserThrowsWhenConfiguredMonthlyUsageIsMalformed(_ monthlyUsage: String) {
    let data = Data(#"""
    ((self.$R=self.$R||{}),$R[1]={customerID:"cus_x",balance:100000000,monthlyLimit:50,monthlyUsage:\#(monthlyUsage)});
    """#.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try OpenCodeCreditsParser().parse(data)
    }
}

@Test
func openCodeCreditsParserThrowsWhenNestedObjectBreaksTheBraceGroup() {
    // The `[^{}]*` gaps must stay inside one brace group; a nested object
    // between customerID and the numeric fields is unobserved drift.
    let data = Data(#"""
    ((self.$R=self.$R||{}),$R[1]={customerID:"cus_x",nested:{balance:99,monthlyLimit:99,monthlyUsage:99});
    """#.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try OpenCodeCreditsParser().parse(data)
    }
}

@Test
func openCodeCreditsParserThrowsWhenBalanceDigitsOverflowToInfinity() {
    // Double parses sufficiently long digit strings as infinity; a
    // configured record must stay in finite math or fail loudly.
    let overflowDigits = String(repeating: "9", count: 400)
    let data = Data(#"""
    ((self.$R=self.$R||{}),$R[1]={customerID:"cus_x",balance:\#(overflowDigits),monthlyLimit:50,monthlyUsage:200000000});
    """#.utf8)

    #expect(throws: UsageParsingError.parseFailure) {
        try OpenCodeCreditsParser().parse(data)
    }
}

@Test
func openCodeCreditsParserThrowsOnSignedOutPage() throws {
    #expect(throws: UsageParsingError.parseFailure) {
        try OpenCodeCreditsParser().parse(fixtureData("opencode-go-signed-out.html"))
    }
}

@Test
func openCodeCreditsParserThrowsOnANonWorkspacePage() {
    // A body with no Seroval stream at all is not a workspace page; treating
    // it as "billing not configured" would misreport transport-level garbage
    // as a benign account state.
    #expect(throws: UsageParsingError.parseFailure) {
        try OpenCodeCreditsParser().parse(Data("not usage".utf8))
    }
}

private func fixtureData(_ name: String) throws -> Data {
    let testFile = URL(fileURLWithPath: #filePath)
    return try Data(contentsOf: testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name))
}
