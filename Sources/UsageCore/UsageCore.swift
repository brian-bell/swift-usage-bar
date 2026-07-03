import CryptoKit
import Foundation
import Observation
import Security

public enum UsageCore {
    public static let version = "0.1.0"
}

public struct UsageWindow: Equatable, Sendable {
    public let percentRemaining: Int
    public let resetsAt: Date?

    public init(percentRemaining: Int, resetsAt: Date?) {
        self.percentRemaining = percentRemaining
        self.resetsAt = resetsAt
    }
}

public struct ProviderUsage: Equatable, Sendable {
    public let fiveHour: UsageWindow
    public let weekly: UsageWindow

    public init(fiveHour: UsageWindow, weekly: UsageWindow) {
        self.fiveHour = fiveHour
        self.weekly = weekly
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
            let previousResetCycle = ResetCycle(resetsAt: window.previous.resetsAt)
            let currentResetCycle = ResetCycle(resetsAt: window.current.resetsAt)
            let crossedThreshold = window.previous.percentRemaining >= threshold
                && window.current.percentRemaining < threshold
            let newResetCycleAlreadyBelowThreshold = previousResetCycle != currentResetCycle
                && window.current.percentRemaining < threshold

            let key = ThresholdNotificationKey(
                provider: provider,
                window: window.kind,
                threshold: threshold,
                resetCycle: currentResetCycle
            )
            let retryingFailedDelivery = failedCycles.contains(key)
                && window.current.percentRemaining < threshold

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
                    percentRemaining: window.current.percentRemaining,
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

public protocol UsageProvider: Sendable {
    func fetch(previous: ProviderUsage?) async -> ProviderState
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
    private var lastAttemptedRefreshes: [ProviderID: Date]
    private var lastSuccessfulRefreshes: [ProviderID: Date]

    public init(
        providerStates: [ProviderID: ProviderState] = [:],
        lastAttemptedRefreshes: [ProviderID: Date] = [:],
        lastSuccessfulRefreshes: [ProviderID: Date] = [:]
    ) {
        self.providerStates = providerStates
        self.lastAttemptedRefreshes = lastAttemptedRefreshes
        self.lastSuccessfulRefreshes = lastSuccessfulRefreshes
    }

    public var states: [ProviderID: ProviderState] {
        providerStates
    }

    public func providerState(for provider: ProviderID) -> ProviderState? {
        providerStates[provider]
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
        providerStates[provider] == .hidden
    }

    public func setProvider(_ provider: ProviderID, visible: Bool) {
        if visible {
            if providerStates[provider] == .hidden {
                providerStates.removeValue(forKey: provider)
            }
        } else {
            providerStates[provider] = .hidden
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

        if case .hidden = providerStates[provider] {
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
        if case .hidden = providerStates[provider] {
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
        requestPoll()
    }

    public func stop() {
        isRunning = false
        isPolling = false
        pendingPoll = false
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
        requestPoll()
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
        requestPoll()
    }

    private func requestPoll() {
        guard isRunning else {
            return
        }

        cancelTimer()

        if isPolling {
            pendingPoll = true
            return
        }

        isPolling = true
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

                    let state = await provider.fetch(previous: previous)
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
        requestPoll()
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
    private let cacheReader: any ClaudeStatuslineCacheReading
    private let now: @Sendable () -> Date

    public init(
        cacheReader: any ClaudeStatuslineCacheReading,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cacheReader = cacheReader
        self.now = now
    }

    public func fetch(previous: ProviderUsage?) async -> ProviderState {
        do {
            return Self.providerState(from: try cacheReader.read(now: now()), previous: previous)
        } catch {
            return .stale(last: previous, reason: .networkError)
        }
    }

    private static func providerState(
        from result: ClaudeStatuslineCacheReadResult,
        previous: ProviderUsage?
    ) -> ProviderState {
        switch result {
        case let .fresh(data: _, usage: usage, asOf: asOf):
            return .fresh(usage, asOf: asOf)
        case let .stale(last: last, reason: reason, hint: _):
            return .stale(last: last ?? previous, reason: reason)
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
    case codex
}

public enum CredentialStoreReadError: Error, Equatable, Sendable {
    case unavailable
}

public protocol CredentialStore: Sendable {
    func read(_ credential: CredentialIdentifier) throws -> Data?
}

public enum CodexCredentialReadResult: Equatable, Sendable {
    case fresh(CodexCredential)
    case stale(reason: StaleReason)
}

public protocol CodexCredentialReading: Sendable {
    func read() throws -> CodexCredentialReadResult
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

    public func read() throws -> CodexCredentialReadResult {
        let data: Data?
        do {
            data = try store.read(.codex)
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

    public func fetch(previous: ProviderUsage?) async -> ProviderState {
        let credential: CodexCredential
        do {
            switch try credentialReader.read() {
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

    private let accountResolver: @Sendable (CredentialIdentifier) -> String
    private let copyMatching: CopyMatching

    public init() {
        self.accountResolver = Self.defaultAccount(for:)
        self.copyMatching = SecItemCopyMatching
    }

    public init(copyMatching: @escaping CopyMatching) {
        self.accountResolver = Self.defaultAccount(for:)
        self.copyMatching = copyMatching
    }

    init(codexHomePath: String, copyMatching: @escaping CopyMatching) {
        self.accountResolver = { _ in codexKeychainAccount(codexHomePath: codexHomePath) }
        self.copyMatching = copyMatching
    }

    public init(
        accountResolver: @escaping @Sendable (CredentialIdentifier) -> String,
        copyMatching: @escaping CopyMatching = SecItemCopyMatching
    ) {
        self.accountResolver = accountResolver
        self.copyMatching = copyMatching
    }

    public func read(_ credential: CredentialIdentifier) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: credential.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        query[kSecAttrAccount as String] = accountResolver(credential)

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

    private static func defaultAccount(for credential: CredentialIdentifier) -> String {
        switch credential {
        case .codex:
            return codexKeychainAccount(codexHomePath: defaultCodexHomePath())
        }
    }
}

public func tone(for usage: ProviderUsage, warningThreshold: Int = 20) -> UsageStatusTone {
    let remaining = min(usage.fiveHour.percentRemaining, usage.weekly.percentRemaining)
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

public struct CodexUsageParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> ProviderUsage {
        do {
            let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)

            return ProviderUsage(
                fiveHour: usageWindow(
                    usedPercentage: response.rateLimit.primaryWindow.usedPercent,
                    resetAt: response.rateLimit.primaryWindow.resetAt
                ),
                weekly: usageWindow(
                    usedPercentage: response.rateLimit.secondaryWindow.usedPercent,
                    resetAt: response.rateLimit.secondaryWindow.resetAt
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

public enum MenuBarTitleFormatter {
    public static func format(_ states: [ProviderID: ProviderState]) -> AttributedString {
        let segments = ProviderID.allCases.compactMap { provider -> String? in
            guard let state = states[provider] else {
                return "\(provider.symbol) --/--"
            }

            switch state {
            case let .fresh(usage, _):
                return "\(provider.symbol) \(usage.remainingPair)"
            case let .stale(last: usage?, reason: _):
                return "\(provider.symbol) ~\(usage.remainingPair)"
            case .stale(last: nil, reason: _):
                return "\(provider.symbol) --/--"
            case .hidden:
                return nil
            }
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
    let usedPercentage: Int
    let resetsAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

private struct CodexUsageResponse: Decodable {
    let rateLimit: CodexRateLimit

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

private extension CredentialIdentifier {
    var keychainService: String {
        "Codex Auth"
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
    let primaryWindow: CodexRateLimitWindow
    let secondaryWindow: CodexRateLimitWindow

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

private func usageWindow(usedPercentage: Int, resetAt: TimeInterval) -> UsageWindow {
    UsageWindow(
        percentRemaining: percentRemaining(fromUsedPercentage: usedPercentage),
        resetsAt: Date(timeIntervalSince1970: resetAt)
    )
}

private func percentRemaining(fromUsedPercentage usedPercentage: Int) -> Int {
    if usedPercentage <= 0 {
        return 100
    }

    if usedPercentage >= 100 {
        return 0
    }

    return 100 - usedPercentage
}

private func staleReason(forHTTPStatusCode statusCode: Int) -> StaleReason {
    if statusCode == 401 {
        return .tokenExpired
    }

    return .networkError
}

private extension ProviderUsage {
    var remainingPair: String {
        "\(fiveHour.percentRemaining)/\(weekly.percentRemaining)"
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
