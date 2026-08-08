import Foundation

/// Extracts the workspace credit balance from the billing record embedded in
/// the workspace's `/go` SSR page — the same page `OpenCodeGoUsageParser`
/// reads, but with ownership inverted: here the billing record *is* the
/// product, so drift in a configured record throws instead of degrading.
///
/// Verdicts:
/// - a configured record (`customerID:"…"`) with parsable numbers → the
///   balance;
/// - a workspace page without a record, or with `customerID:null` → `nil`
///   ("billing not configured" — never a fabricated $0.00);
/// - a configured record whose shape has drifted, a signed-out page, or a
///   body that is not a workspace SSR page at all → `parseFailure`.
public struct OpenCodeCreditsParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> CreditBalance? {
        guard let text = String(data: data, encoding: .utf8),
              !Self.looksSignedOut(text),
              text.contains("$R[")
        else {
            throw UsageParsingError.parseFailure
        }

        // The three numeric fields appear in source-verified order within one
        // brace group, before the nested `lite:{…}` object; `[^{}]*` gaps
        // cannot cross a nested object. See docs/endpoints.md › OpenCode
        // credits for units and evidence.
        let pattern = #"\{customerID:"([^"]+)"[^{}]*balance:(\d+)[^{}]*monthlyLimit:(\d+)[^{}]*monthlyUsage:(\d+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            // A configured record the regex cannot read is unobserved drift;
            // anything else is a workspace without billing. `customerID:""`
            // lands here deliberately: only `null` is the observed
            // not-configured sentinel, and the Go parser's billing exemption
            // makes the same call — inventing a benign meaning for an
            // unobserved shape in one parser but not the other would let the
            // two disagree about the same bytes.
            if text.contains(#"customerID:""#) {
                throw UsageParsingError.parseFailure
            }
            return nil
        }

        guard let balanceRange = Range(match.range(at: 2), in: text),
              let limitRange = Range(match.range(at: 3), in: text),
              let usageRange = Range(match.range(at: 4), in: text),
              let balance = Double(text[balanceRange]), balance.isFinite,
              let limit = Int(text[limitRange]),
              let monthlyUsage = Double(text[usageRange]), monthlyUsage.isFinite
        else {
            throw UsageParsingError.parseFailure
        }

        // 10⁻⁸-dollar units per docs/endpoints.md. Rounding to cents is the
        // formatter's job, not the model's — keeps two captures of the same
        // balance equal.
        return CreditBalance(
            balanceUSD: balance / 100_000_000,
            monthlyUsedUSD: monthlyUsage / 100_000_000,
            monthlyLimitUSD: limit
        )
    }

    private static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("/auth/authorize") || lower.contains(">sign in<")
    }
}

/// The OpenCode Credits provider: the same Chrome cookie and locked-down
/// transport as OpenCode Go, reading the same workspace page for the billing
/// record instead of the Go windows. Fully independent of the Go provider —
/// each fetches, qualifies, and toggles on its own.
public struct OpenCodeCreditsProvider: UsageProvider {
    private let sessionReader: any OpenCodeSessionReading
    private let transport: any OpenCodeGoTransporting
    private let workspaceOverride: @Sendable () -> String?
    private let parser: OpenCodeCreditsParser
    private let maximumConcurrentWorkspaceRequests: Int

    public init(
        sessionReader: any OpenCodeSessionReading,
        transport: any OpenCodeGoTransporting,
        workspaceOverride: @escaping @Sendable () -> String?,
        parser: OpenCodeCreditsParser = OpenCodeCreditsParser(),
        maximumConcurrentWorkspaceRequests: Int = 4
    ) {
        self.sessionReader = sessionReader
        self.transport = transport
        self.workspaceOverride = workspaceOverride
        self.parser = parser
        self.maximumConcurrentWorkspaceRequests = max(1, maximumConcurrentWorkspaceRequests)
    }

    public func fetch(previous: ProviderUsage?, mode: CredentialAccessMode) async -> ProviderState {
        await fetchReport(previous: previous, mode: mode).state
    }

    public func fetchReport(
        previous: ProviderUsage?,
        mode: CredentialAccessMode
    ) async -> ProviderFetchReport {
        let state = await fetchState(previous: previous, mode: mode)

        return ProviderFetchReport(
            state: state,
            chain: [ProviderDataSourceStep.singlePath(.openCodeCreditsChromeCookie, state: state)]
        )
    }

    private func fetchState(previous: ProviderUsage?, mode: CredentialAccessMode) async -> ProviderState {
        let session: OpenCodeSession
        do {
            guard let readSession = try sessionReader.readSession(mode: mode) else {
                return .stale(last: previous, reason: .credentialUnavailable)
            }
            session = readSession
        } catch {
            return .stale(last: previous, reason: .credentialUnavailable)
        }

        do {
            if let workspaceID = OpenCodeGoWorkspace.normalizedID(from: workspaceOverride()) {
                let response = try await transport.fetchUsagePage(workspaceID: workspaceID, session: session)
                guard let credits = try parser.parse(response.data) else {
                    // A healthy page with no configured billing record: there
                    // is no balance to read on this workspace.
                    return .stale(last: previous, reason: .credentialUnavailable)
                }
                return .fresh(Self.usage(for: credits), asOf: response.receivedAt)
            }

            let discovered = try await transport.discoverWorkspaceIDs(session: session)
            let workspaceIDs = Array(Set(discovered.compactMap {
                OpenCodeGoWorkspace.normalizedID(from: $0)
            })).sorted()
            let candidates = await qualifyingCandidates(workspaceIDs: workspaceIDs, session: session)
            if candidates.usages.isEmpty {
                // Drift outranks "no billing": a configured record we could
                // not read means billing exists and the page changed shape —
                // telling the user to configure billing would be wrong.
                if candidates.sessionExpired {
                    return .stale(last: previous, reason: .sessionExpired)
                }
                if candidates.parseFailure {
                    return .stale(last: previous, reason: .parseFailure)
                }
                return .stale(last: previous, reason: .credentialUnavailable)
            }
            guard candidates.usages.count == 1 else {
                return .stale(last: previous, reason: .workspaceSelectionRequired)
            }
            let selected = candidates.usages[0]
            return .fresh(selected.usage, asOf: selected.asOf)
        } catch OpenCodeGoTransportError.sessionExpired {
            return .stale(last: previous, reason: .sessionExpired)
        } catch OpenCodeGoTransportError.parseFailure, UsageParsingError.parseFailure {
            return .stale(last: previous, reason: .parseFailure)
        } catch {
            return .stale(last: previous, reason: .networkError)
        }
    }

    /// Both percent slots stay unavailable: this provider's usage is the
    /// dollar balance alone, which keeps it out of tone and threshold
    /// notifications (they read only the percent windows).
    private static func usage(for credits: CreditBalance) -> ProviderUsage {
        ProviderUsage(
            fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
            weekly: UsageWindow(percentRemaining: nil, resetsAt: nil),
            credits: credits
        )
    }

    private struct Candidate: Sendable {
        let usage: ProviderUsage
        let asOf: Date
    }

    private enum CandidateResult: Sendable {
        case usage(Candidate)
        case sessionExpired
        case parseFailure
        case rejected
    }

    private func qualifyingCandidates(
        workspaceIDs: [String],
        session: OpenCodeSession
    ) async -> (usages: [Candidate], sessionExpired: Bool, parseFailure: Bool) {
        guard !workspaceIDs.isEmpty else { return ([], false, false) }
        let transport = self.transport
        let parser = self.parser
        let limit = maximumConcurrentWorkspaceRequests

        return await withTaskGroup(of: CandidateResult.self) { group in
            var iterator = workspaceIDs.makeIterator()
            for _ in 0..<min(limit, workspaceIDs.count) {
                if let workspaceID = iterator.next() {
                    group.addTask { await Self.fetchCandidate(
                        workspaceID: workspaceID,
                        session: session,
                        transport: transport,
                        parser: parser
                    ) }
                }
            }

            var usages: [Candidate] = []
            var sawSessionExpired = false
            var sawParseFailure = false
            while let result = await group.next() {
                switch result {
                case let .usage(candidate): usages.append(candidate)
                case .sessionExpired: sawSessionExpired = true
                case .parseFailure: sawParseFailure = true
                case .rejected: break
                }
                if let workspaceID = iterator.next() {
                    group.addTask { await Self.fetchCandidate(
                        workspaceID: workspaceID,
                        session: session,
                        transport: transport,
                        parser: parser
                    ) }
                }
            }
            return (usages, sawSessionExpired, sawParseFailure)
        }
    }

    private static func fetchCandidate(
        workspaceID: String,
        session: OpenCodeSession,
        transport: any OpenCodeGoTransporting,
        parser: OpenCodeCreditsParser
    ) async -> CandidateResult {
        do {
            try Task.checkCancellation()
            let response = try await transport.fetchUsagePage(workspaceID: workspaceID, session: session)
            guard let credits = try parser.parse(response.data) else {
                // A workspace without configured billing is not a credits
                // candidate.
                return .rejected
            }
            return .usage(Candidate(usage: usage(for: credits), asOf: response.receivedAt))
        } catch OpenCodeGoTransportError.sessionExpired {
            return .sessionExpired
        } catch UsageParsingError.parseFailure {
            // A configured-but-drifted billing record. Not the same as
            // "no billing on this workspace" — the caller surfaces it when
            // no sibling workspace qualifies.
            return .parseFailure
        } catch {
            return .rejected
        }
    }
}
