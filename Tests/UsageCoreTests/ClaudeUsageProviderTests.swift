import Foundation
import Testing
import UsageCore

@Test
func claudeUsageProviderReturnsFreshUsageFromFreshStatuslineCache() async {
    let asOf = Date(timeIntervalSince1970: 1_783_000_000)
    let usage = sampleUsage(fiveHour: 62, weekly: 81)
    let provider = ClaudeUsageProvider(
        cacheReader: FakeClaudeStatuslineCacheReader(result: .fresh(
            data: Data("{}".utf8),
            usage: usage,
            asOf: asOf
        )),
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    let state = await provider.fetch(previous: nil)

    #expect(state == .fresh(usage, asOf: asOf))
}

@Test
func claudeUsageProviderMapsMissingCacheToStaleNetworkErrorWithPreviousUsage() async {
    let previous = sampleUsage(fiveHour: 55, weekly: 75)
    let provider = ClaudeUsageProvider(
        cacheReader: FakeClaudeStatuslineCacheReader(result: .stale(
            last: nil,
            reason: .networkError,
            hint: "Configure Claude Code statusline to write its cache."
        )),
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: previous, reason: .networkError))
}

@Test
func claudeUsageProviderMapsStaleCacheToStaleNetworkErrorWithCacheUsage() async {
    let cached = sampleUsage(fiveHour: 62, weekly: 81)
    let previous = sampleUsage(fiveHour: 55, weekly: 75)
    let provider = ClaudeUsageProvider(
        cacheReader: FakeClaudeStatuslineCacheReader(result: .stale(
            last: cached,
            reason: .networkError,
            hint: "Configure Claude Code statusline to write its cache."
        )),
        now: { Date(timeIntervalSince1970: 1_783_000_301) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: cached, reason: .networkError))
}

@Test
func claudeUsageProviderMapsMalformedCacheToStaleParseFailureWithPreviousUsage() async {
    let previous = sampleUsage(fiveHour: 55, weekly: 75)
    let provider = ClaudeUsageProvider(
        cacheReader: FakeClaudeStatuslineCacheReader(result: .stale(
            last: nil,
            reason: .parseFailure,
            hint: "Configure Claude Code statusline to write its cache."
        )),
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: previous, reason: .parseFailure))
}

@Test
func claudeUsageProviderMapsReaderThrowToStaleNetworkErrorWithPreviousUsage() async {
    let previous = sampleUsage(fiveHour: 55, weekly: 75)
    let provider = ClaudeUsageProvider(
        cacheReader: FakeClaudeStatuslineCacheReader(error: CocoaError(.fileReadUnknown)),
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    let state = await provider.fetch(previous: previous)

    #expect(state == .stale(last: previous, reason: .networkError))
}

private struct FakeClaudeStatuslineCacheReader: ClaudeStatuslineCacheReading {
    var result: ClaudeStatuslineCacheReadResult?
    var error: (any Error)?

    func read(now _: Date) throws -> ClaudeStatuslineCacheReadResult {
        if let error {
            throw error
        }

        return result!
    }
}

private func sampleUsage(fiveHour: Int, weekly: Int) -> ProviderUsage {
    ProviderUsage(
        fiveHour: UsageWindow(
            percentRemaining: fiveHour,
            resetsAt: Date(timeIntervalSince1970: 1_783_008_000)
        ),
        weekly: UsageWindow(
            percentRemaining: weekly,
            resetsAt: Date(timeIntervalSince1970: 1_783_555_200)
        )
    )
}
