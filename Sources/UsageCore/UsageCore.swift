import CryptoKit
import Foundation
import Observation
import Security

public enum UsageCore {
    public static let version = "0.1.0"
}

public struct UsageWindow: Equatable, Sendable {
    /// `nil` when the provider reports that this rate-limit window is unavailable.
    public let percentRemaining: Int?
    public let resetsAt: Date?

    public init(percentRemaining: Int?, resetsAt: Date?) {
        self.percentRemaining = percentRemaining
        self.resetsAt = resetsAt
    }
}

public struct ProviderUsage: Equatable, Sendable {
    public let fiveHour: UsageWindow
    public let weekly: UsageWindow
    // Model-scoped weekly window (Claude's "Fable" limit), when the API reports one.
    public let fable: UsageWindow?

    public init(fiveHour: UsageWindow, weekly: UsageWindow, fable: UsageWindow? = nil) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fable = fable
    }
}

private extension ProviderUsage {
    func windows(comparedWith previous: ProviderUsage) -> [UsageWindowComparison] {
        [
            UsageWindowComparison(kind: .fiveHour, previous: previous.fiveHour, current: fiveHour),
            UsageWindowComparison(kind: .weekly, previous: previous.weekly, current: weekly),
        ]
    }
}

private struct UsageWindowComparison {
    let kind: UsageWindowKind
    let previous: UsageWindow
    let current: UsageWindow
}

public enum UsageParsingError: Error, Equatable, Sendable {
    case parseFailure
}

public enum ProviderID: CaseIterable, Hashable, Sendable {
    case claude
    case codex
}

public enum StaleReason: Equatable, Sendable {
    case parseFailure
    case networkError
    case tokenExpired
    case credentialUnavailable
}

public enum ProviderState: Equatable, Sendable {
    case fresh(ProviderUsage, asOf: Date)
    case stale(last: ProviderUsage?, reason: StaleReason)
    case hidden
}

public enum UsageWindowKind: Equatable, Hashable, Sendable {
    case fiveHour
    case weekly
}

public struct UsageThresholdNotification: Equatable, Sendable {
    public let provider: ProviderID
    public let window: UsageWindowKind
    public let percentRemaining: Int
    public let threshold: Int
    public let resetsAt: Date?

    public init(
        provider: ProviderID,
        window: UsageWindowKind,
        percentRemaining: Int,
        threshold: Int,
        resetsAt: Date?
    ) {
        self.provider = provider
        self.window = window
        self.percentRemaining = percentRemaining
        self.threshold = threshold
        self.resetsAt = resetsAt
    }

    public var title: String {
        "\(provider.notificationDisplayName) \(window.notificationDisplayName) usage below \(threshold)%"
    }

    public var body: String {
        "\(percentRemaining)% remaining before this window resets."
    }
}

private extension ProviderID {
    var notificationDisplayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }
}

private extension UsageWindowKind {
    var notificationDisplayName: String {
        switch self {
        case .fiveHour:
            return "five-hour"
        case .weekly:
            return "weekly"
        }
    }
}

public protocol NotificationSending: Sendable {
    func send(_ notification: UsageThresholdNotification) async throws
}

public actor ThresholdNotifier {
    private let sender: any NotificationSending
    private var firedCycles: Set<ThresholdNotificationKey> = []
    private var failedCycles: Set<ThresholdNotificationKey> = []

    public init(sender: any NotificationSending) {
        self.sender = sender
    }

    public func evaluate(
        previous: ProviderUsage?,
        current: ProviderUsage,
        provider: ProviderID,
        threshold: Int
    ) async {
        guard let previous else {
            return
        }

        for window in current.windows(comparedWith: previous) {
            guard let currentPercentRemaining = window.current.percentRemaining else {
                continue
            }

            let previousResetCycle = ResetCycle(resetsAt: window.previous.resetsAt)
            let currentResetCycle = ResetCycle(resetsAt: window.current.resetsAt)
            let crossedThreshold = (window.previous.percentRemaining.map { $0 >= threshold } ?? false)
                && currentPercentRemaining < threshold
            let newResetCycleAlreadyBelowThreshold = previousResetCycle != currentResetCycle
                && currentPercentRemaining < threshold

            let key = ThresholdNotificationKey(
                provider: provider,
                window: window.kind,
                threshold: threshold,
                resetCycle: currentResetCycle
            )
            let retryingFailedDelivery = failedCycles.contains(key)
                && currentPercentRemaining < threshold

            guard crossedThreshold || newResetCycleAlreadyBelowThreshold || retryingFailedDelivery else {
                continue
            }

            guard firedCycles.insert(key).inserted else {
                continue
            }

            do {
                try await sender.send(UsageThresholdNotification(
                    provider: provider,
                    window: window.kind,
                    percentRemaining: currentPercentRemaining,
                    threshold: threshold,
                    resetsAt: window.current.resetsAt
                ))
                failedCycles.remove(key)
            } catch {
                firedCycles.remove(key)
                failedCycles.insert(key)
            }
        }
    }
}

private struct ThresholdNotificationKey: Hashable, Sendable {
    let provider: ProviderID
    let window: UsageWindowKind
    let threshold: Int
    let resetCycle: ResetCycle
}

private enum ResetCycle: Hashable, Sendable {
    case known(Date)
    case unknown

    init(resetsAt: Date?) {
        if let resetsAt {
            self = .known(resetsAt)
        } else {
            self = .unknown
        }
    }
}

/// Whether a credential read may present an interactive Keychain prompt.
///
/// Background polls must never prompt: if access would require interaction, the
/// read fails and the provider degrades to its fallback (e.g. the Claude
/// statusline cache) instead of popping a dialog. Only user-initiated refreshes
/// use `.interactive`, so prompts are reserved for moments the user asked for.
public enum CredentialAccessMode: Sendable, Equatable {
    case interactive
    case background
}

public protocol UsageProvider: Sendable {
    func fetch(previous: ProviderUsage?, mode: CredentialAccessMode) async -> ProviderState
}

public extension UsageProvider {
    /// Convenience for callers that don't distinguish access modes; defaults to
    /// the prompt-safe `.background` mode.
    func fetch(previous: ProviderUsage?) async -> ProviderState {
        await fetch(previous: previous, mode: .background)
    }
}

public protocol UsageClock: Sendable {
    var now: Date { get async }

    func sleep(for duration: TimeInterval) async throws
}

public struct SystemUsageClock: UsageClock {
    public init() {}

    public var now: Date {
        get async { Date() }
    }

    public func sleep(for duration: TimeInterval) async throws {
        let seconds = max(0, duration)
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

@MainActor
@Observable
public final class AppState: @unchecked Sendable {
    private var providerStates: [ProviderID: ProviderState]
    private var hiddenProviders: Set<ProviderID>
    private var lastAttemptedRefreshes: [ProviderID: Date]
    private var lastSuccessfulRefreshes: [ProviderID: Date]

    public init(
        providerStates: [ProviderID: ProviderState] = [:],
        lastAttemptedRefreshes: [ProviderID: Date] = [:],
        lastSuccessfulRefreshes: [ProviderID: Date] = [:]
    ) {
        self.providerStates = providerStates.filter { _, state in state != .hidden }
        self.hiddenProviders = Set(providerStates.compactMap { provider, state in
            state == .hidden ? provider : nil
        })
        self.lastAttemptedRefreshes = lastAttemptedRefreshes
        self.lastSuccessfulRefreshes = lastSuccessfulRefreshes
    }

    public var states: [ProviderID: ProviderState] {
        var states = providerStates
        for provider in hiddenProviders {
            states[provider] = .hidden
        }
        return states
    }

    public func providerState(for provider: ProviderID) -> ProviderState? {
        if hiddenProviders.contains(provider) {
            return .hidden
        }

        return providerStates[provider]
    }

    public func lastAttemptedRefresh(provider: ProviderID) -> Date? {
        lastAttemptedRefreshes[provider]
    }

    public func lastUpdated(provider: ProviderID) -> Date? {
        lastSuccessfulRefreshes[provider]
    }

    public func previousUsage(provider: ProviderID) -> ProviderUsage? {
        switch providerStates[provider] {
        case let .fresh(usage, asOf: _):
            return usage
        case let .stale(last: usage, reason: _):
            return usage
        case .hidden, nil:
            return nil
        }
    }

    public func isHidden(provider: ProviderID) -> Bool {
        hiddenProviders.contains(provider)
    }

    public func setProvider(_ provider: ProviderID, visible: Bool) {
        if visible {
            hiddenProviders.remove(provider)
        } else {
            hiddenProviders.insert(provider)
        }
    }

    public func recordRefreshAttempt(provider: ProviderID, at attemptedAt: Date) {
        lastAttemptedRefreshes[provider] = attemptedAt
    }

    @discardableResult
    public func recordRefreshAttemptAndApplyResult(
        provider: ProviderID,
        attemptedAt: Date,
        state: ProviderState,
        completedAt: Date,
        shouldApply: @Sendable () -> Bool = { true }
    ) -> Bool {
        guard shouldApply() else {
            return false
        }

        if hiddenProviders.contains(provider) {
            return false
        }

        recordRefreshAttempt(provider: provider, at: attemptedAt)
        applyRefreshResult(provider: provider, state: state, completedAt: completedAt)
        return true
    }

    public func applyRefreshResult(
        provider: ProviderID,
        state: ProviderState,
        completedAt: Date
    ) {
        if hiddenProviders.contains(provider) {
            return
        }

        if state == .hidden {
            providerStates.removeValue(forKey: provider)
            hiddenProviders.insert(provider)
            return
        }

        let resolvedState: ProviderState
        switch state {
        case let .stale(last: nil, reason: reason):
            resolvedState = .stale(last: previousUsage(provider: provider), reason: reason)
        default:
            resolvedState = state
        }

        providerStates[provider] = resolvedState
        if case .fresh = resolvedState {
            lastSuccessfulRefreshes[provider] = completedAt
        }
    }
}

public actor UsagePoller {
    public static let defaultInterval: TimeInterval = 120
    private static let minimumInterval: TimeInterval = 1

    private let providers: [ProviderID: any UsageProvider]
    private let appState: AppState
    private let clock: any UsageClock
    private let wakeEvents: (@Sendable () -> AsyncStream<Void>)?
    private let thresholdNotifier: ThresholdNotifier?
    private let thresholdProvider: @Sendable () async -> Int
    private let lifecycle = PollLifecycle()
    private var interval: TimeInterval
    private var isRunning = false
    private var isPolling = false
    private var pendingPoll = false
    // Access mode for the in-flight cycle and for a coalesced pending poll. A
    // manual refresh (.interactive) that lands mid-cycle upgrades the pending
    // poll so the user-requested prompt isn't downgraded to a silent one.
    private var pollMode: CredentialAccessMode = .background
    private var pendingPollMode: CredentialAccessMode = .background
    private var pollGeneration: UInt64 = 0
    private var timerGeneration: UInt64 = 0
    private var timerTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var thresholdEvaluationTasks: [UUID: Task<Void, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        providers: [ProviderID: any UsageProvider],
        appState: AppState,
        clock: any UsageClock = SystemUsageClock(),
        interval: TimeInterval = UsagePoller.defaultInterval,
        wakeEvents: (@Sendable () -> AsyncStream<Void>)? = nil,
        thresholdNotifier: ThresholdNotifier? = nil,
        thresholdProvider: @escaping @Sendable () async -> Int = { 20 }
    ) {
        self.providers = providers
        self.appState = appState
        self.clock = clock
        self.interval = Self.normalizedInterval(interval)
        self.wakeEvents = wakeEvents
        self.thresholdNotifier = thresholdNotifier
        self.thresholdProvider = thresholdProvider
    }

    public func start() {
        guard !isRunning else {
            return
        }

        isRunning = true
        pollGeneration &+= 1
        lifecycle.markRunning(generation: pollGeneration)
        startWakeTask()
        requestPoll(mode: .background)
    }

    public func stop() {
        isRunning = false
        isPolling = false
        pendingPoll = false
        pendingPollMode = .background
        pollGeneration &+= 1
        lifecycle.markStopped(generation: pollGeneration)
        timerGeneration &+= 1
        timerTask?.cancel()
        pollTask?.cancel()
        wakeTask?.cancel()
        for task in thresholdEvaluationTasks.values {
            task.cancel()
        }
        timerTask = nil
        pollTask = nil
        wakeTask = nil
        thresholdEvaluationTasks.removeAll()
        resumeIdleWaiters()
    }

    public func refreshNow() {
        // User-initiated: allowed to present a Keychain prompt so the user can
        // grant access after a token rotation reset the item's ACL.
        requestPoll(mode: .interactive)
    }

    public func waitUntilIdle() async {
        if !isPolling, thresholdEvaluationTasks.isEmpty {
            return
        }

        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    public func setPollingInterval(_ interval: TimeInterval) {
        self.interval = Self.normalizedInterval(interval)
        guard isRunning else {
            return
        }

        if isPolling {
            return
        }

        scheduleTimer()
    }

    private func startWakeTask() {
        guard let wakeEvents else {
            return
        }

        let stream = wakeEvents()
        wakeTask = Task { [stream] in
            for await _ in stream {
                if Task.isCancelled {
                    return
                }

                self.wakeDidFire()
            }
        }
    }

    private func wakeDidFire() {
        requestPoll(mode: .background)
    }

    private func requestPoll(mode: CredentialAccessMode) {
        guard isRunning else {
            return
        }

        cancelTimer()

        if isPolling {
            pendingPoll = true
            if mode == .interactive {
                pendingPollMode = .interactive
            }
            return
        }

        isPolling = true
        pollMode = mode
        let generation = pollGeneration
        pollTask = Task {
            await self.runPollChain(generation: generation)
        }
    }

    private func runPollChain(generation: UInt64) async {
        while isRunning, !Task.isCancelled {
            await runPollCycle(generation: generation)

            guard generation == pollGeneration else {
                return
            }

            if pendingPoll, isRunning, !Task.isCancelled {
                pendingPoll = false
                pollMode = pendingPollMode
                pendingPollMode = .background
                continue
            }

            isPolling = false
            pollTask = nil
            if isRunning, !Task.isCancelled {
                scheduleTimer()
            }
            resumeIdleWaiters()
            return
        }

        guard generation == pollGeneration else {
            return
        }

        isPolling = false
        pollTask = nil
        resumeIdleWaiters()
    }

    private func runPollCycle(generation: UInt64) async {
        let providers = providers
        let appState = appState
        let clock = clock
        let thresholdNotifier = thresholdNotifier
        let thresholdProvider = thresholdProvider
        let mode = pollMode

        await withTaskGroup(of: ProviderPollResult?.self) { group in
            for (providerID, provider) in providers {
                group.addTask {
                    if Task.isCancelled {
                        return nil
                    }

                    if await appState.isHidden(provider: providerID) {
                        return nil
                    }

                    let previous = await appState.previousUsage(provider: providerID)
                    if Task.isCancelled {
                        return nil
                    }

                    let attemptedAt = await clock.now
                    if Task.isCancelled {
                        return nil
                    }

                    let state = await provider.fetch(previous: previous, mode: mode)
                    if Task.isCancelled {
                        return nil
                    }

                    let completedAt = await clock.now
                    if Task.isCancelled {
                        return nil
                    }

                    return ProviderPollResult(
                        provider: providerID,
                        previousUsage: previous,
                        attemptedAt: attemptedAt,
                        state: state,
                        completedAt: completedAt
                    )
                }
            }

            for await result in group {
                guard let result else {
                    continue
                }

                guard isRunning, generation == pollGeneration, lifecycle.isCurrent(generation), !Task.isCancelled else {
                    continue
                }

                let lifecycle = lifecycle
                let didApply = await appState.recordRefreshAttemptAndApplyResult(
                    provider: result.provider,
                    attemptedAt: result.attemptedAt,
                    state: result.state,
                    completedAt: result.completedAt,
                    shouldApply: { lifecycle.isCurrent(generation) }
                )
                guard didApply else {
                    continue
                }

                if case .fresh = result.state, let thresholdNotifier {
                    scheduleThresholdEvaluation(
                        notifier: thresholdNotifier,
                        lifecycle: lifecycle,
                        generation: generation,
                        appState: appState,
                        thresholdProvider: thresholdProvider,
                        previous: result.previousUsage,
                        provider: result.provider
                    )
                }
            }
        }
    }

    private func scheduleThresholdEvaluation(
        notifier: ThresholdNotifier,
        lifecycle: PollLifecycle,
        generation: UInt64,
        appState: AppState,
        thresholdProvider: @escaping @Sendable () async -> Int,
        previous: ProviderUsage?,
        provider: ProviderID
    ) {
        let taskID = UUID()
        thresholdEvaluationTasks[taskID] = Task {
            let threshold = await thresholdProvider()
            guard lifecycle.isCurrent(generation), !Task.isCancelled else {
                self.thresholdEvaluationDidFinish(taskID)
                return
            }

            let latestState = await appState.providerState(for: provider)
            guard lifecycle.isCurrent(generation), !Task.isCancelled else {
                self.thresholdEvaluationDidFinish(taskID)
                return
            }

            let current: ProviderUsage?
            switch latestState {
            case let .fresh(usage, asOf: _):
                current = usage
            case let .stale(last: usage, reason: _):
                current = usage
            case .hidden, nil:
                current = nil
            }

            guard let current else {
                self.thresholdEvaluationDidFinish(taskID)
                return
            }

            await notifier.evaluate(
                previous: previous,
                current: current,
                provider: provider,
                threshold: threshold
            )
            self.thresholdEvaluationDidFinish(taskID)
        }
    }

    private func thresholdEvaluationDidFinish(_ taskID: UUID) {
        thresholdEvaluationTasks.removeValue(forKey: taskID)
        resumeIdleWaiters()
    }

    private func scheduleTimer() {
        guard isRunning else {
            return
        }

        timerGeneration &+= 1
        let generation = timerGeneration
        let interval = interval
        let clock = clock
        timerTask?.cancel()
        timerTask = Task {
            do {
                try await clock.sleep(for: interval)
                self.timerDidFire(generation: generation)
            } catch {}
        }
    }

    private func cancelTimer() {
        timerGeneration &+= 1
        timerTask?.cancel()
        timerTask = nil
    }

    private func timerDidFire(generation: UInt64) {
        guard isRunning, generation == timerGeneration else {
            return
        }

        timerTask = nil
        requestPoll(mode: .background)
    }

    private func resumeIdleWaiters() {
        guard !isPolling, thresholdEvaluationTasks.isEmpty else {
            return
        }

        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private static func normalizedInterval(_ interval: TimeInterval) -> TimeInterval {
        max(minimumInterval, interval)
    }
}

private struct ProviderPollResult: Sendable {
    let provider: ProviderID
    let previousUsage: ProviderUsage?
    let attemptedAt: Date
    let state: ProviderState
    let completedAt: Date
}

private final class PollLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var generation: UInt64 = 0

    func markRunning(generation: UInt64) {
        lock.withLock {
            self.running = true
            self.generation = generation
        }
    }

    func markStopped(generation: UInt64) {
        lock.withLock {
            self.running = false
            self.generation = generation
        }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock {
            running && self.generation == generation
        }
    }
}

public enum UsageStatusTone: Equatable, Sendable {
    case normal
    case warning
    case critical
}

public enum ClaudeStatuslineCacheReadResult: Equatable, Sendable {
    case fresh(data: Data, usage: ProviderUsage, asOf: Date)
    case stale(last: ProviderUsage?, reason: StaleReason, hint: String)
}

public protocol ClaudeStatuslineCacheReading: Sendable {
    func read(now: Date) throws -> ClaudeStatuslineCacheReadResult
}

public struct ClaudeStatuslineCacheReader: Sendable {
    private let cacheURL: URL
    private let maximumAge: TimeInterval
    private let parser: ClaudeStatuslineParser

    public init(
        cacheURL: URL,
        maximumAge: TimeInterval,
        parser: ClaudeStatuslineParser = ClaudeStatuslineParser()
    ) {
        self.cacheURL = cacheURL
        self.maximumAge = maximumAge
        self.parser = parser
    }

    public func read(now: Date) throws -> ClaudeStatuslineCacheReadResult {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return .stale(
                last: nil,
                reason: .networkError,
                hint: Self.configureStatuslineHint
            )
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        let modifiedAt = attributes[.modificationDate] as? Date ?? .distantPast
        let data = try Data(contentsOf: cacheURL)
        let usage: ProviderUsage
        do {
            usage = try parser.parse(data)
        } catch UsageParsingError.parseFailure {
            return .stale(
                last: nil,
                reason: .parseFailure,
                hint: Self.configureStatuslineHint
            )
        }

        if now.timeIntervalSince(modifiedAt) > maximumAge {
            return .stale(
                last: usage,
                reason: .networkError,
                hint: Self.configureStatuslineHint
            )
        }

        return .fresh(data: data, usage: usage, asOf: modifiedAt)
    }

    private static let configureStatuslineHint =
        "Configure Claude Code statusline to write its cache."
}

extension ClaudeStatuslineCacheReader: ClaudeStatuslineCacheReading {}

public struct ClaudeUsageProvider: UsageProvider {
    private let credentialReader: any ClaudeCredentialReading
    private let cacheReader: any ClaudeStatuslineCacheReading
    private let transport: any HTTPTransport
    private let parser: ClaudeUsageParser
    private let now: @Sendable () -> Date

    public init(
        credentialReader: any ClaudeCredentialReading,
        cacheReader: any ClaudeStatuslineCacheReading,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        parser: ClaudeUsageParser = ClaudeUsageParser(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialReader = credentialReader
        self.cacheReader = cacheReader
        self.transport = transport
        self.parser = parser
        self.now = now
    }

    // Both modes take the API-then-cache path; the difference lives in the
    // keychain layer, where a `.background` read fails silently instead of
    // presenting a prompt (kSecUseAuthenticationUIFail), degrading to the
    // statusline-cache fallback.
    public func fetch(previous: ProviderUsage?, mode: CredentialAccessMode) async -> ProviderState {
        switch await fetchFromAPI(mode: mode) {
        case let .fresh(usage, asOf):
            return .fresh(usage, asOf: asOf)
        case let .stale(apiReason):
            return fallbackState(apiReason: apiReason, previous: previous)
        }
    }

    private enum APIOutcome {
        case fresh(ProviderUsage, asOf: Date)
        case stale(StaleReason)
    }

    private func fetchFromAPI(mode: CredentialAccessMode) async -> APIOutcome {
        let credential: ClaudeCredential
        do {
            switch try credentialReader.read(mode: mode) {
            case let .fresh(freshCredential):
                credential = freshCredential
            case let .stale(reason):
                return .stale(reason)
            }
        } catch {
            return .stale(.credentialUnavailable)
        }

        do {
            let (data, response) = try await transport.send(Self.usageRequest(for: credential))
            guard response.statusCode == 200 else {
                return .stale(staleReason(forHTTPStatusCode: response.statusCode))
            }

            return .fresh(try parser.parse(data), asOf: now())
        } catch UsageParsingError.parseFailure {
            return .stale(.parseFailure)
        } catch {
            return .stale(.networkError)
        }
    }

    // The API's failure reason wins over the cache's: the API is the primary
    // path and its reason is more actionable (tokenExpired -> run Claude Code,
    // which also refreshes the statusline cache).
    private func fallbackState(apiReason: StaleReason, previous: ProviderUsage?) -> ProviderState {
        guard let cacheResult = try? cacheReader.read(now: now()) else {
            return .stale(last: previous, reason: apiReason)
        }

        switch cacheResult {
        case let .fresh(data: _, usage: usage, asOf: asOf):
            return .fresh(usage, asOf: asOf)
        case let .stale(last: last, reason: _, hint: _):
            return .stale(last: last ?? previous, reason: apiReason)
        }
    }

    private static func usageRequest(for credential: ClaudeCredential) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AIUsageBar/\(UsageCore.version)", forHTTPHeaderField: "User-Agent")

        return request
    }
}

public struct ClaudeCredential: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date

    public init(accessToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

public struct ClaudeCredentialParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> ClaudeCredential {
        do {
            let stored = try JSONDecoder().decode(ClaudeStoredCredential.self, from: data)
            guard stored.claudeAiOauth.hasUsableAccessToken else {
                throw UsageParsingError.parseFailure
            }

            return ClaudeCredential(
                accessToken: stored.claudeAiOauth.accessToken,
                expiresAt: Date(timeIntervalSince1970: stored.claudeAiOauth.expiresAt / 1000)
            )
        } catch {
            throw UsageParsingError.parseFailure
        }
    }
}

public struct CodexCredential: Equatable, Sendable {
    public let accessToken: String
    public let accountID: String?
    public let expiresAt: Date

    public init(accessToken: String, accountID: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.expiresAt = expiresAt
    }
}

public struct CodexCredentialParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> CodexCredential {
        do {
            let stored = try JSONDecoder().decode(CodexStoredCredential.self, from: data)
            guard stored.tokens.hasRequiredValues else {
                throw UsageParsingError.parseFailure
            }

            return CodexCredential(
                accessToken: stored.tokens.accessToken,
                accountID: stored.tokens.normalizedAccountID,
                expiresAt: try expiryDate(fromJWT: stored.tokens.accessToken)
            )
        } catch {
            throw UsageParsingError.parseFailure
        }
    }
}

public enum CredentialIdentifier: Hashable, Sendable {
    case claude
    case codex
}

public enum CredentialStoreReadError: Error, Equatable, Sendable {
    case unavailable
}

public protocol CredentialStore: Sendable {
    func read(_ credential: CredentialIdentifier, mode: CredentialAccessMode) throws -> Data?
}

public extension CredentialStore {
    /// Convenience defaulting to the prompt-safe `.background` mode.
    func read(_ credential: CredentialIdentifier) throws -> Data? {
        try read(credential, mode: .background)
    }
}

public enum ClaudeCredentialReadResult: Equatable, Sendable {
    case fresh(ClaudeCredential)
    case stale(reason: StaleReason)
}

public protocol ClaudeCredentialReading: Sendable {
    func read(mode: CredentialAccessMode) throws -> ClaudeCredentialReadResult
}

public extension ClaudeCredentialReading {
    /// Convenience defaulting to the prompt-safe `.background` mode.
    func read() throws -> ClaudeCredentialReadResult {
        try read(mode: .background)
    }
}

public struct ClaudeCredentialReader: Sendable {
    private let store: any CredentialStore
    private let fallbackStore: (any CredentialStore)?
    private let parser: ClaudeCredentialParser
    private let now: @Sendable () -> Date

    public init(
        store: any CredentialStore,
        fallbackStore: (any CredentialStore)? = nil,
        parser: ClaudeCredentialParser = ClaudeCredentialParser(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.fallbackStore = fallbackStore
        self.parser = parser
        self.now = now
    }

    public func read(mode: CredentialAccessMode) throws -> ClaudeCredentialReadResult {
        let data: Data?
        do {
            data = try store.read(.claude, mode: mode)
        } catch {
            return fallingBack(from: .stale(reason: .credentialUnavailable), mode: mode)
        }

        let primary = evaluate(data)
        if case .fresh = primary {
            return primary
        }

        return fallingBack(from: primary, mode: mode)
    }

    // A present credentials file is the stronger evidence of CLI state (the
    // Keychain item may hold only mcpOAuth entries on Claude Code 2.1.x), so a
    // readable file's verdict wins over the Keychain's. An absent or unreadable
    // file proves nothing and keeps the Keychain's reason.
    private func fallingBack(from primary: ClaudeCredentialReadResult, mode: CredentialAccessMode) -> ClaudeCredentialReadResult {
        guard
            let fallbackStore,
            let data = try? fallbackStore.read(.claude, mode: mode)
        else {
            return primary
        }

        return evaluate(data)
    }

    private func evaluate(_ data: Data?) -> ClaudeCredentialReadResult {
        guard let data else {
            // Mirrors the Codex mapping: "no credential" and "expired
            // credential" have the same user remedy — run the CLI.
            return .stale(reason: .tokenExpired)
        }

        // The parser maps every failure to UsageParsingError.parseFailure.
        guard let credential = try? parser.parse(data) else {
            return .stale(reason: .parseFailure)
        }

        guard credential.expiresAt > now() else {
            return .stale(reason: .tokenExpired)
        }

        return .fresh(credential)
    }
}

extension ClaudeCredentialReader: ClaudeCredentialReading {}

public enum CodexCredentialReadResult: Equatable, Sendable {
    case fresh(CodexCredential)
    case stale(reason: StaleReason)
}

public protocol CodexCredentialReading: Sendable {
    func read(mode: CredentialAccessMode) throws -> CodexCredentialReadResult
}

public extension CodexCredentialReading {
    /// Convenience defaulting to the prompt-safe `.background` mode.
    func read() throws -> CodexCredentialReadResult {
        try read(mode: .background)
    }
}

public struct CodexCredentialReader: Sendable {
    private let store: any CredentialStore
    private let parser: CodexCredentialParser
    private let now: @Sendable () -> Date

    public init(
        store: any CredentialStore,
        parser: CodexCredentialParser = CodexCredentialParser(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.parser = parser
        self.now = now
    }

    public func read(mode: CredentialAccessMode) throws -> CodexCredentialReadResult {
        let data: Data?
        do {
            data = try store.read(.codex, mode: mode)
        } catch CredentialStoreReadError.unavailable {
            return .stale(reason: .credentialUnavailable)
        } catch {
            return .stale(reason: .credentialUnavailable)
        }

        guard let data else {
            return .stale(reason: .tokenExpired)
        }

        let credential: CodexCredential
        do {
            credential = try parser.parse(data)
        } catch UsageParsingError.parseFailure {
            return .stale(reason: .parseFailure)
        }

        guard credential.expiresAt > now() else {
            return .stale(reason: .tokenExpired)
        }

        return .fresh(credential)
    }
}

extension CodexCredentialReader: CodexCredentialReading {}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        return (data, httpResponse)
    }
}

public struct CodexUsageProvider: UsageProvider {
    private let credentialReader: any CodexCredentialReading
    private let transport: any HTTPTransport
    private let parser: CodexUsageParser
    private let now: @Sendable () -> Date

    public init(
        credentialReader: any CodexCredentialReading,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        parser: CodexUsageParser = CodexUsageParser(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialReader = credentialReader
        self.transport = transport
        self.parser = parser
        self.now = now
    }

    public func fetch(previous: ProviderUsage?, mode: CredentialAccessMode) async -> ProviderState {
        let credential: CodexCredential
        do {
            switch try credentialReader.read(mode: mode) {
            case let .fresh(freshCredential):
                credential = freshCredential
            case let .stale(reason):
                return .stale(last: previous, reason: reason)
            }
        } catch {
            return .stale(last: previous, reason: .credentialUnavailable)
        }

        do {
            let (data, response) = try await transport.send(Self.usageRequest(for: credential))
            guard response.statusCode == 200 else {
                return .stale(last: previous, reason: staleReason(forHTTPStatusCode: response.statusCode))
            }

            return .fresh(try parser.parse(data), asOf: now())
        } catch UsageParsingError.parseFailure {
            return .stale(last: previous, reason: .parseFailure)
        } catch {
            return .stale(last: previous, reason: .networkError)
        }
    }

    private static func usageRequest(for credential: CodexCredential) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("AIUsageBar/\(UsageCore.version)", forHTTPHeaderField: "User-Agent")
        if let accountID = credential.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        return request
    }
}

public struct KeychainCredentialStore: CredentialStore {
    public typealias CopyMatching = @Sendable (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus

    /// Toggles process-wide legacy-Keychain user interaction. Injectable so tests
    /// can observe the call without touching the real security subsystem.
    public typealias SetUserInteractionAllowed = @Sendable (Bool) -> OSStatus

    private let accountResolver: @Sendable (CredentialIdentifier) -> String?
    private let copyMatching: CopyMatching
    // `nil` means "use the real SecKeychain toggle"; tests inject a spy.
    private let setUserInteractionAllowedOverride: SetUserInteractionAllowed?

    public init() {
        self.accountResolver = Self.defaultAccount(for:)
        self.copyMatching = SecItemCopyMatching
        self.setUserInteractionAllowedOverride = nil
    }

    public init(
        copyMatching: @escaping CopyMatching,
        setUserInteractionAllowed: SetUserInteractionAllowed? = nil
    ) {
        self.accountResolver = Self.defaultAccount(for:)
        self.copyMatching = copyMatching
        self.setUserInteractionAllowedOverride = setUserInteractionAllowed
    }

    init(codexHomePath: String, copyMatching: @escaping CopyMatching) {
        self.accountResolver = { _ in codexKeychainAccount(codexHomePath: codexHomePath) }
        self.copyMatching = copyMatching
        self.setUserInteractionAllowedOverride = nil
    }

    public init(
        accountResolver: @escaping @Sendable (CredentialIdentifier) -> String?,
        copyMatching: @escaping CopyMatching = SecItemCopyMatching
    ) {
        self.accountResolver = accountResolver
        self.copyMatching = copyMatching
        self.setUserInteractionAllowedOverride = nil
    }

    public func read(_ credential: CredentialIdentifier, mode: CredentialAccessMode) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: credential.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        if let account = accountResolver(credential) {
            query[kSecAttrAccount as String] = account
        }

        // Background polls must never present a Keychain prompt. This item can
        // raise two DIFFERENT legacy prompts, each needing its own guard:
        //
        //  1. Trusted-application ACL prompt — suppressed by
        //     `kSecUseAuthenticationUIFail` on the query below.
        //  2. Partition-id password prompt — appears when the app's Team ID is
        //     absent from the item's partition list. Claude Code refreshes its
        //     OAuth token by shelling out to `/usr/bin/security`, whose write
        //     resets the partition list to `apple-tool:`, dropping the
        //     `teamid:<app>` entry that a prior "Always Allow" had added. On the
        //     next poll the partition check fails and macOS asks for the login
        //     password. `kSecUseAuthenticationUIFail` does NOT suppress this
        //     prompt (verified empirically: a UIFail read of a partition-mismatched
        //     item still pops the dialog). The only reliable suppressor is
        //     disabling legacy-Keychain UI process-wide, which makes the blocked
        //     read fail fast (errSecAuthFailed) so the provider degrades to its
        //     statusline-cache/file fallback silently.
        //
        // Interactive reads (manual refresh) re-enable UI so the user can act.
        // The toggle is process-global, but the poller runs one cycle at a time
        // and every provider in a cycle shares the same mode, so concurrent reads
        // never disagree on the value.
        _ = setUserInteractionAllowed(mode == .interactive)

        if mode == .background {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw CredentialStoreReadError.unavailable
        }

        return item as? Data
    }

    /// Resolves to the injected spy in tests, else the real SecKeychain toggle.
    private var setUserInteractionAllowed: SetUserInteractionAllowed {
        setUserInteractionAllowedOverride ?? Self.systemSetUserInteractionAllowed
    }

    // Single chokepoint for the deprecated (macOS 10.10) SecKeychain toggle. The
    // whole SecKeychain family is deprecated, but it is the only API that governs
    // the legacy partition-id prompt this app must avoid; confining the reference
    // here keeps the deprecation to one line.
    private static let systemSetUserInteractionAllowed: SetUserInteractionAllowed = { allowed in
        SecKeychainSetUserInteractionAllowed(allowed)
    }

    private static func defaultAccount(for credential: CredentialIdentifier) -> String? {
        switch credential {
        case .claude:
            // The Claude Code item is unique per service; matching by service
            // alone stays robust to whatever account string Claude Code writes.
            return nil
        case .codex:
            return codexKeychainAccount(codexHomePath: defaultCodexHomePath())
        }
    }
}

/// Read-only access to Claude Code's on-disk credentials file
/// (`${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json`), the fallback source
/// when the Keychain item can't produce a usable credential (e.g. Claude Code
/// versions that keep only `mcpOAuth` state in the Keychain).
public struct ClaudeCredentialsFileStore: CredentialStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Resolves Claude Code's config directory the way the CLI does:
    /// `$CLAUDE_CONFIG_DIR` when set, else `~/.claude`.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let configDirectory: URL
        if let path = environment["CLAUDE_CONFIG_DIR"], !path.isEmpty {
            configDirectory = URL(fileURLWithPath: path)
        } else {
            configDirectory = homeDirectory.appendingPathComponent(".claude")
        }
        self.init(fileURL: configDirectory.appendingPathComponent(".credentials.json"))
    }

    public func read(_ credential: CredentialIdentifier, mode: CredentialAccessMode) throws -> Data? {
        do {
            return try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            // Mirrors the Keychain store's errSecItemNotFound mapping: an absent
            // credential is "no data", not an access failure.
            return nil
        } catch {
            throw CredentialStoreReadError.unavailable
        }
    }
}

public func tone(for usage: ProviderUsage, warningThreshold: Int = 20) -> UsageStatusTone {
    let remaining = [usage.fiveHour.percentRemaining, usage.weekly.percentRemaining]
        .compactMap { $0 }
        .min() ?? 100
    if remaining < 5 {
        return .critical
    }

    if remaining < warningThreshold {
        return .warning
    }

    return .normal
}

public struct ClaudeStatuslineParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> ProviderUsage {
        do {
            let statusline = try JSONDecoder().decode(ClaudeStatuslineResponse.self, from: data)

            return ProviderUsage(
                fiveHour: usageWindow(
                    usedPercentage: statusline.rateLimits.fiveHour.usedPercentage,
                    resetAt: statusline.rateLimits.fiveHour.resetsAt
                ),
                weekly: usageWindow(
                    usedPercentage: statusline.rateLimits.sevenDay.usedPercentage,
                    resetAt: statusline.rateLimits.sevenDay.resetsAt
                )
            )
        } catch {
            throw UsageParsingError.parseFailure
        }
    }
}

public struct ClaudeUsageParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> ProviderUsage {
        do {
            let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)

            return ProviderUsage(
                fiveHour: try usageWindow(from: response.fiveHour),
                weekly: try usageWindow(from: response.sevenDay),
                fable: fableWindow(from: response.limits)
            )
        } catch {
            throw UsageParsingError.parseFailure
        }
    }

    private func usageWindow(from window: ClaudeUsageResponseWindow?) throws -> UsageWindow {
        guard let window else {
            // Lapsed window: nothing used, and no reset exists until usage
            // opens the next window.
            return UsageWindow(percentRemaining: 100, resetsAt: nil)
        }

        guard let resetsAt = claudeUsageResetDate(from: window.resetsAt) else {
            throw UsageParsingError.parseFailure
        }

        return UsageWindow(
            percentRemaining: percentRemaining(fromUsedPercentage: window.utilization),
            resetsAt: resetsAt
        )
    }

    // The Fable weekly limit arrives as a model-scoped entry in `limits`, not a
    // top-level window. A missing/unparseable reset degrades to nil (shown as
    // "reset unknown") rather than dropping the whole window.
    private func fableWindow(from limits: [FailableDecodable<ClaudeUsageLimit>]?) -> UsageWindow? {
        guard let limit = limits?.compactMap(\.value).first(where: {
            $0.scope?.model?.displayName?.caseInsensitiveCompare("Fable") == .orderedSame
        }) else {
            return nil
        }

        return UsageWindow(
            percentRemaining: percentRemaining(fromUsedPercentage: limit.percent),
            resetsAt: limit.resetsAt.flatMap(claudeUsageResetDate(from:))
        )
    }
}

public struct CodexUsageParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> ProviderUsage {
        do {
            let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            guard response.rateLimit.primaryWindow != nil
                    || response.rateLimit.secondaryWindow != nil else {
                throw UsageParsingError.parseFailure
            }

            return ProviderUsage(
                fiveHour: usageWindow(
                    codexWindow: response.rateLimit.primaryWindow
                ),
                weekly: usageWindow(
                    codexWindow: response.rateLimit.secondaryWindow
                )
            )
        } catch {
            throw UsageParsingError.parseFailure
        }
    }
}

public enum CountdownFormatter {
    public static func format(
        resetAt: Date,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let remainingSeconds = resetAt.timeIntervalSince(now)
        if remainingSeconds <= 0 {
            return "resetting..."
        }

        if remainingSeconds >= 24 * 60 * 60 {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "EEE h:mm a"

            return "resets \(formatter.string(from: resetAt))"
        }

        let remainingMinutes = max(0, Int(remainingSeconds / 60))
        let hours = remainingMinutes / 60
        let minutes = remainingMinutes % 60

        return "resets in \(hours)h \(minutes)m"
    }
}

public struct MenuBarTitleSegment: Equatable, Sendable {
    public let provider: ProviderID
    public let value: String
    public let isStale: Bool

    public init(provider: ProviderID, value: String, isStale: Bool) {
        self.provider = provider
        self.value = value
        self.isStale = isStale
    }
}

public enum MenuBarTitleFormatter {
    public static func segments(_ states: [ProviderID: ProviderState]) -> [MenuBarTitleSegment] {
        ProviderID.allCases.compactMap { provider -> MenuBarTitleSegment? in
            guard let state = states[provider] else {
                return MenuBarTitleSegment(provider: provider, value: "--/--", isStale: false)
            }

            switch state {
            case let .fresh(usage, _):
                return MenuBarTitleSegment(provider: provider, value: usage.remainingPair, isStale: false)
            case let .stale(last: usage?, reason: _):
                return MenuBarTitleSegment(provider: provider, value: usage.remainingPair, isStale: true)
            case .stale(last: nil, reason: _):
                return MenuBarTitleSegment(provider: provider, value: "--/--", isStale: false)
            case .hidden:
                return nil
            }
        }
    }

    public static func format(_ states: [ProviderID: ProviderState]) -> AttributedString {
        let segments = segments(states).map { segment in
            let prefix = segment.isStale ? "~" : ""
            return "\(segment.provider.symbol) \(prefix)\(segment.value)"
        }

        return AttributedString(segments.joined(separator: "  "))
    }
}

private struct ClaudeStatuslineResponse: Decodable {
    let rateLimits: ClaudeStatuslineRateLimits

    enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }
}

private struct ClaudeStatuslineRateLimits: Decodable {
    let fiveHour: ClaudeStatuslineWindow
    let sevenDay: ClaudeStatuslineWindow

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct ClaudeStatuslineWindow: Decodable {
    // Claude Code computes this as a float; whole values serialize as ints
    // but floating-point noise (7.000000000000001) must still decode.
    let usedPercentage: Double
    let resetsAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

private struct ClaudeUsageResponse: Decodable {
    // A window that saw no usage lapses to an explicit null (a five-hour
    // window closes after an idle night); decode it as absent rather than
    // failing the whole response.
    let fiveHour: ClaudeUsageResponseWindow?
    let sevenDay: ClaudeUsageResponseWindow?
    // Lossy: a malformed or restructured limit entry (e.g. a future non-Fable
    // limit missing `percent`) must not fail the whole decode and strand the
    // valid five_hour/seven_day windows in a parseFailure.
    let limits: [FailableDecodable<ClaudeUsageLimit>]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A body carrying neither window key (an error payload, `{}`) is not
        // a usage response; treating it as "all windows lapsed" would render
        // 100% remaining from garbage. An explicit null still counts as
        // present: the key marks the body as a genuine usage response.
        guard container.contains(.fiveHour) || container.contains(.sevenDay) else {
            throw DecodingError.keyNotFound(CodingKeys.fiveHour, DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "response has no usage window keys"
            ))
        }

        fiveHour = try container.decodeIfPresent(ClaudeUsageResponseWindow.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(ClaudeUsageResponseWindow.self, forKey: .sevenDay)
        limits = try container.decodeIfPresent([FailableDecodable<ClaudeUsageLimit>].self, forKey: .limits)
    }
}

// Decodes each array element independently: an element that fails becomes nil
// instead of throwing out of the enclosing container.
private struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct ClaudeUsageResponseWindow: Decodable {
    let utilization: Double
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

// A model-scoped rate-limit entry from the usage API's `limits` array; the app
// only reads its percent/reset for the Fable weekly window.
private struct ClaudeUsageLimit: Decodable {
    let percent: Double
    let resetsAt: String?
    let scope: ClaudeUsageLimitScope?

    enum CodingKeys: String, CodingKey {
        case percent
        case resetsAt = "resets_at"
        case scope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        percent = try container.decode(Double.self, forKey: .percent)
        scope = try container.decodeIfPresent(ClaudeUsageLimitScope.self, forKey: .scope)
        // Lossy: a present-but-wrong-type `resets_at` (e.g. a number instead of
        // an ISO string) degrades this field to nil — shown as "reset unknown" —
        // instead of throwing and dropping the whole Fable row.
        resetsAt = try? container.decodeIfPresent(String.self, forKey: .resetsAt)
    }
}

private struct ClaudeUsageLimitScope: Decodable {
    let model: ClaudeUsageLimitModel?
}

private struct ClaudeUsageLimitModel: Decodable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

// The usage API emits ISO 8601 with 6-digit fractional seconds
// (2026-07-04T06:10:00.229359+00:00); ISO8601DateFormatter's
// .withFractionalSeconds only reliably parses exactly 3, so other
// fraction lengths are normalized before parsing.
private func claudeUsageResetDate(from string: String) -> Date? {
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: string) {
        return date
    }

    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) {
        return date
    }

    if let normalized = normalizingFractionalSeconds(string, to: 3) {
        return fractional.date(from: normalized)
    }

    return nil
}

private func normalizingFractionalSeconds(_ string: String, to digits: Int) -> String? {
    guard let dotIndex = string.firstIndex(of: ".") else {
        return nil
    }

    let fractionStart = string.index(after: dotIndex)
    var fractionEnd = fractionStart
    while fractionEnd < string.endIndex, string[fractionEnd].isNumber {
        fractionEnd = string.index(after: fractionEnd)
    }

    let fraction = string[fractionStart..<fractionEnd]
    guard !fraction.isEmpty, fraction.count != digits else {
        return nil
    }

    let normalized = fraction.count > digits
        ? String(fraction.prefix(digits))
        : fraction.padding(toLength: digits, withPad: "0", startingAt: 0)

    return string.replacingCharacters(in: fractionStart..<fractionEnd, with: normalized)
}

private struct CodexUsageResponse: Decodable {
    let rateLimit: CodexRateLimit

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

private extension CredentialIdentifier {
    var keychainService: String {
        switch self {
        case .claude:
            return "Claude Code-credentials"
        case .codex:
            return "Codex Auth"
        }
    }
}

private struct ClaudeStoredCredential: Decodable {
    let claudeAiOauth: OAuth

    struct OAuth: Decodable {
        let accessToken: String
        // Claude Code stores this as epoch milliseconds.
        let expiresAt: Double

        var hasUsableAccessToken: Bool {
            !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private struct CodexStoredCredential: Decodable {
    let tokens: Tokens

    struct Tokens: Decodable {
        let accessToken: String
        let accountID: String?

        var hasRequiredValues: Bool {
            !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var normalizedAccountID: String? {
            guard let accountID else {
                return nil
            }

            let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexRateLimitWindow?
    let secondaryWindow: CodexRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct JWTPayload: Decodable {
    let exp: TimeInterval
}

private func expiryDate(fromJWT token: String) throws -> Date {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count >= 2 else {
        throw UsageParsingError.parseFailure
    }

    let payloadSegment = String(segments[1])
    guard let payloadData = Data(base64URLEncoded: payloadSegment) else {
        throw UsageParsingError.parseFailure
    }

    do {
        let payload = try JSONDecoder().decode(JWTPayload.self, from: payloadData)
        return Date(timeIntervalSince1970: payload.exp)
    } catch {
        throw UsageParsingError.parseFailure
    }
}

private struct CodexRateLimitWindow: Decodable {
    let resetAt: TimeInterval
    let usedPercent: Int

    enum CodingKeys: String, CodingKey {
        case resetAt = "reset_at"
        case usedPercent = "used_percent"
    }
}

private func usageWindow(usedPercentage: Double, resetAt: TimeInterval) -> UsageWindow {
    UsageWindow(
        percentRemaining: percentRemaining(fromUsedPercentage: usedPercentage),
        resetsAt: Date(timeIntervalSince1970: resetAt)
    )
}

private func usageWindow(codexWindow: CodexRateLimitWindow?) -> UsageWindow {
    // A null or omitted window means the provider isn't enforcing this limit
    // right now (e.g. weekly quota disabled): pin to 100% remaining with an
    // unknown reset, matching the Claude parser's lapsed-window semantics.
    // Conflating null with an absent key is deliberate — the parse() guard
    // still rejects bodies where neither window decodes.
    guard let codexWindow else {
        return UsageWindow(percentRemaining: 100, resetsAt: nil)
    }

    return usageWindow(
        usedPercentage: Double(codexWindow.usedPercent),
        resetAt: codexWindow.resetAt
    )
}

// Clamp before converting to Int: extreme doubles (1e300) would trap in Int().
private func percentRemaining(fromUsedPercentage usedPercentage: Double) -> Int {
    if usedPercentage <= 0 {
        return 100
    }

    if usedPercentage >= 100 {
        return 0
    }

    return 100 - Int(usedPercentage.rounded())
}

private func staleReason(forHTTPStatusCode statusCode: Int) -> StaleReason {
    if statusCode == 401 {
        return .tokenExpired
    }

    return .networkError
}

private extension ProviderUsage {
    var remainingPair: String {
        "\(fiveHour.percentRemaining.map(String.init) ?? "--")/\(weekly.percentRemaining.map(String.init) ?? "--")"
    }
}

private extension ProviderID {
    var symbol: String {
        switch self {
        case .claude:
            "*"
        case .codex:
            "#"
        }
    }
}

func codexKeychainAccount(codexHomePath: String) -> String {
    "cli|\(codexHomeHashPrefix(codexHomePath: codexHomePath))"
}

private func defaultCodexHomePath() -> String {
    let environment = ProcessInfo.processInfo.environment

    return environment["CODEX_HOME"] ?? "\(environment["HOME"] ?? NSHomeDirectory())/.codex"
}

private func codexHomeHashPrefix(codexHomePath: String) -> String {
    let canonicalPath = URL(fileURLWithPath: codexHomePath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
    let digest = SHA256.hash(data: Data(canonicalPath.utf8))

    return digest
        .prefix(8)
        .map { String(format: "%02x", $0) }
        .joined()
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let paddingCount = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: paddingCount))

        self.init(base64Encoded: base64)
    }
}
