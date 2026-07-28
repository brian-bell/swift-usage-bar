import AppKit
import Foundation
import Security

/// Result of the read-only Codex desktop app-server rate-limit request.
public enum CodexAppServerUsageReadResult: Equatable, Sendable {
    case fresh(ProviderUsage)
    case stale(reason: StaleReason)
}

/// Narrow boundary used by `CodexUsageProvider` for its credential-unavailable
/// fallback. Implementations may only read rate limits; no authentication or
/// mutation operations are exposed here.
public protocol CodexAppServerUsageReading: Sendable {
    func readUsage() async -> CodexAppServerUsageReadResult
    func shutdown() async
}

public extension CodexAppServerUsageReading {
    func shutdown() async {}
}

public protocol CodexDesktopHelperDiscovering: Sendable {
    func locateHelper() -> URL?
}

public protocol CodexDesktopAppLocating: Sendable {
    func applicationURL(bundleIdentifier: String) -> URL?
}

public struct NSWorkspaceCodexDesktopAppLocator: CodexDesktopAppLocating {
    public init() {}

    public func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}

public protocol CodexCodeSignatureValidating: Sendable {
    func hasValidSignature(at url: URL, teamIdentifier: String) -> Bool
}

public struct SystemCodexCodeSignatureValidator: CodexCodeSignatureValidating {
    public init() {}

    public func hasValidSignature(at url: URL, teamIdentifier: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil) == errSecSuccess else {
            return false
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [String: Any],
        let actualTeamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String else {
            return false
        }
        return actualTeamIdentifier == teamIdentifier
    }
}

/// Resolves only the helper bundled by the installed Codex desktop application.
/// PATH lookup and arbitrary executables are deliberately unsupported.
public struct CodexDesktopHelperDiscovery: CodexDesktopHelperDiscovering {
    public static let bundleIdentifier = "com.openai.codex"
    public static let openAITeamIdentifier = "2DC432GLL2"

    private let appLocator: any CodexDesktopAppLocating
    private let signatureValidator: any CodexCodeSignatureValidating

    public init(
        appLocator: any CodexDesktopAppLocating = NSWorkspaceCodexDesktopAppLocator(),
        signatureValidator: any CodexCodeSignatureValidating = SystemCodexCodeSignatureValidator()
    ) {
        self.appLocator = appLocator
        self.signatureValidator = signatureValidator
    }

    public func locateHelper() -> URL? {
        guard let rawAppURL = appLocator.applicationURL(
            bundleIdentifier: Self.bundleIdentifier
        ) else {
            return nil
        }

        let appURL = rawAppURL.standardizedFileURL.resolvingSymlinksInPath()
        let helperURL = rawAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        let resolvedHelperURL = helperURL.standardizedFileURL.resolvingSymlinksInPath()
        let containedPrefix = appURL.path.hasSuffix("/") ? appURL.path : appURL.path + "/"

        guard resolvedHelperURL.path.hasPrefix(containedPrefix),
              FileManager.default.isExecutableFile(atPath: resolvedHelperURL.path),
              signatureValidator.hasValidSignature(
                  at: resolvedHelperURL,
                  teamIdentifier: Self.openAITeamIdentifier
              ) else {
            return nil
        }

        return resolvedHelperURL
    }
}

public enum CodexAppServerProcessError: Error, Equatable, Sendable {
    case responseTooLarge
    case processFailure
}

public protocol CodexAppServerProcessSession: Sendable {
    var isRunning: Bool { get }
    func writeLine(_ data: Data) throws
    func readLine(maxBytes: Int) async throws -> Data?
    func terminate()
}

public protocol CodexAppServerProcessLaunching: Sendable {
    func launch(
        executableURL: URL,
        arguments: [String]
    ) throws -> any CodexAppServerProcessSession
}

public struct FoundationCodexAppServerProcessLauncher: CodexAppServerProcessLaunching {
    public init() {}

    public func launch(
        executableURL: URL,
        arguments: [String]
    ) throws -> any CodexAppServerProcessSession {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        // Never retain or surface app-server diagnostics: they may contain
        // account context that AIUsageBar has no reason to observe.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexAppServerProcessError.processFailure
        }

        return FoundationCodexAppServerProcessSession(
            process: process,
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading
        )
    }
}

private final class FoundationCodexAppServerProcessSession:
    CodexAppServerProcessSession,
    @unchecked Sendable
{
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let stateLock = NSLock()
    private var bufferedOutput = Data()
    private var wasTerminated = false

    init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
    }

    var isRunning: Bool {
        stateLock.withLock {
            !wasTerminated && process.isRunning
        }
    }

    func writeLine(_ data: Data) throws {
        let writable = stateLock.withLock { !wasTerminated }
        guard writable else {
            throw CodexAppServerProcessError.processFailure
        }
        do {
            try input.write(contentsOf: data + Data([0x0A]))
        } catch {
            throw CodexAppServerProcessError.processFailure
        }
    }

    func readLine(maxBytes: Int) async throws -> Data? {
        try await Task.detached { [self] in
            try readLineBlocking(maxBytes: maxBytes)
        }.value
    }

    func terminate() {
        let shouldTerminate = stateLock.withLock {
            guard !wasTerminated else {
                return false
            }
            wasTerminated = true
            bufferedOutput.removeAll(keepingCapacity: false)
            return true
        }
        guard shouldTerminate else {
            return
        }

        try? input.close()
        try? output.close()
        if process.isRunning {
            process.terminate()
        }
    }

    deinit {
        terminate()
    }

    private func readLineBlocking(maxBytes: Int) throws -> Data? {
        while true {
            let bufferedResult: Data?? = stateLock.withLock {
                if let newline = bufferedOutput.firstIndex(of: 0x0A) {
                    let line = Data(bufferedOutput[..<newline])
                    bufferedOutput.removeSubrange(...newline)
                    return line.count > maxBytes ? .some(nil) : .some(line)
                }
                if bufferedOutput.count > maxBytes {
                    return .some(nil)
                }
                return nil
            }
            if let bufferedResult {
                guard let line = bufferedResult else {
                    throw CodexAppServerProcessError.responseTooLarge
                }
                return line
            }

            let chunk: Data
            do {
                guard let read = try output.read(upToCount: 4_096), !read.isEmpty else {
                    return stateLock.withLock {
                        guard !bufferedOutput.isEmpty else {
                            return nil
                        }
                        let final = bufferedOutput
                        bufferedOutput.removeAll(keepingCapacity: false)
                        return final
                    }
                }
                chunk = read
            } catch {
                throw CodexAppServerProcessError.processFailure
            }

            let exceeded = stateLock.withLock {
                bufferedOutput.append(chunk)
                return bufferedOutput.count > maxBytes
                    && bufferedOutput.firstIndex(of: 0x0A) == nil
            }
            if exceeded {
                throw CodexAppServerProcessError.responseTooLarge
            }
        }
    }
}

/// Actor-owned, lazily launched JSON-RPC client for the one read-only app-server
/// method AIUsageBar is allowed to call.
public actor CodexAppServerUsageReader: CodexAppServerUsageReading {
    private let helperDiscovery: any CodexDesktopHelperDiscovering
    private let processLauncher: any CodexAppServerProcessLaunching
    private let parser: CodexAppServerRateLimitParser
    private let clock: any UsageClock
    private let initializationTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let maximumLineBytes: Int

    private var session: (any CodexAppServerProcessSession)?
    private var isInitialized = false
    private var isShutDown = false
    private var nextRequestID = 1

    public init(
        helperDiscovery: any CodexDesktopHelperDiscovering,
        processLauncher: any CodexAppServerProcessLaunching,
        parser: CodexAppServerRateLimitParser = CodexAppServerRateLimitParser(),
        clock: any UsageClock = SystemUsageClock(),
        initializationTimeout: TimeInterval = 5,
        requestTimeout: TimeInterval = 8,
        maximumLineBytes: Int = 256 * 1024
    ) {
        self.helperDiscovery = helperDiscovery
        self.processLauncher = processLauncher
        self.parser = parser
        self.clock = clock
        self.initializationTimeout = max(0.1, initializationTimeout)
        self.requestTimeout = max(0.1, requestTimeout)
        self.maximumLineBytes = max(1_024, maximumLineBytes)
    }

    public func readUsage() async -> CodexAppServerUsageReadResult {
        guard !isShutDown else {
            return .stale(reason: .credentialUnavailable)
        }

        do {
            let activeSession = try ensureSession()
            if !isInitialized {
                let initializeID = nextID()
                try sendRequest(
                    id: initializeID,
                    method: "initialize",
                    params: [
                        "clientInfo": [
                            "name": "AIUsageBar",
                            "title": "AIUsageBar",
                            "version": UsageCore.version,
                        ],
                        "capabilities": [:],
                    ],
                    to: activeSession
                )
                _ = try await responseResult(
                    matching: initializeID,
                    from: activeSession,
                    timeout: initializationTimeout
                )
                try sendNotification(method: "initialized", to: activeSession)
                isInitialized = true
            }

            let requestID = nextID()
            try sendRequest(
                id: requestID,
                method: "account/rateLimits/read",
                params: NSNull(),
                to: activeSession
            )
            let resultData = try await responseResult(
                matching: requestID,
                from: activeSession,
                timeout: requestTimeout
            )
            return .fresh(try parser.parse(resultData))
        } catch let error as ReaderError {
            closeSession()
            switch error {
            case .helperUnavailable, .rpcFailure:
                return .stale(reason: .credentialUnavailable)
            case .malformedResponse, .responseTooLarge:
                return .stale(reason: .parseFailure)
            case .eof, .timeout, .processFailure:
                return .stale(reason: .networkError)
            }
        } catch UsageParsingError.parseFailure {
            closeSession()
            return .stale(reason: .parseFailure)
        } catch CodexAppServerProcessError.responseTooLarge {
            closeSession()
            return .stale(reason: .parseFailure)
        } catch {
            closeSession()
            return .stale(reason: .networkError)
        }
    }

    public func shutdown() async {
        isShutDown = true
        closeSession()
    }

    private func ensureSession() throws -> any CodexAppServerProcessSession {
        if let session, session.isRunning {
            return session
        }

        closeSession()
        guard let helperURL = helperDiscovery.locateHelper() else {
            throw ReaderError.helperUnavailable
        }

        do {
            let launched = try processLauncher.launch(
                executableURL: helperURL,
                arguments: [
                    "--sandbox", "read-only",
                    "--ask-for-approval", "untrusted",
                    "app-server", "--stdio",
                ]
            )
            session = launched
            return launched
        } catch {
            throw ReaderError.processFailure
        }
    }

    private func nextID() -> Int {
        defer { nextRequestID &+= 1 }
        return nextRequestID
    }

    private func sendRequest(
        id: Int,
        method: String,
        params: Any,
        to session: any CodexAppServerProcessSession
    ) throws {
        try writeJSONObject(
            ["id": id, "method": method, "params": params],
            to: session
        )
    }

    private func sendNotification(
        method: String,
        to session: any CodexAppServerProcessSession
    ) throws {
        try writeJSONObject(["method": method], to: session)
    }

    private func writeJSONObject(
        _ object: [String: Any],
        to session: any CodexAppServerProcessSession
    ) throws {
        do {
            try session.writeLine(JSONSerialization.data(withJSONObject: object))
        } catch {
            throw ReaderError.processFailure
        }
    }

    private func responseResult(
        matching expectedID: Int,
        from session: any CodexAppServerProcessSession,
        timeout: TimeInterval
    ) async throws -> Data {
        let maximumLineBytes = maximumLineBytes
        let clock = clock
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await Self.readMatchingResponse(
                    expectedID: expectedID,
                    from: session,
                    maximumLineBytes: maximumLineBytes
                )
            }
            group.addTask {
                try await clock.sleep(for: timeout)
                throw ReaderError.timeout
            }

            do {
                let first = try await group.next()!
                group.cancelAll()
                return first
            } catch {
                session.terminate()
                group.cancelAll()
                throw error
            }
        }
    }

    private static func readMatchingResponse(
        expectedID: Int,
        from session: any CodexAppServerProcessSession,
        maximumLineBytes: Int
    ) async throws -> Data {
        while true {
            let line: Data
            do {
                guard let nextLine = try await session.readLine(
                    maxBytes: maximumLineBytes
                ) else {
                    throw ReaderError.eof
                }
                line = nextLine
            } catch CodexAppServerProcessError.responseTooLarge {
                throw ReaderError.responseTooLarge
            } catch let error as ReaderError {
                throw error
            } catch {
                throw ReaderError.processFailure
            }

            let object: [String: Any]
            do {
                guard let decoded = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw ReaderError.malformedResponse
                }
                object = decoded
            } catch let error as ReaderError {
                throw error
            } catch {
                throw ReaderError.malformedResponse
            }

            // Notifications (and unrelated responses) may be interleaved with
            // the response we are awaiting.
            guard let responseID = (object["id"] as? NSNumber)?.intValue,
                  responseID == expectedID else {
                continue
            }
            if object["error"] != nil {
                throw ReaderError.rpcFailure
            }
            guard let result = object["result"],
                  JSONSerialization.isValidJSONObject(result) else {
                throw ReaderError.malformedResponse
            }
            do {
                return try JSONSerialization.data(withJSONObject: result)
            } catch {
                throw ReaderError.malformedResponse
            }
        }
    }

    private func closeSession() {
        session?.terminate()
        session = nil
        isInitialized = false
    }

    private enum ReaderError: Error {
        case helperUnavailable
        case rpcFailure
        case malformedResponse
        case responseTooLarge
        case eof
        case timeout
        case processFailure
    }
}

/// Parses only the rate-limit fields used by AIUsageBar. Account metadata,
/// credits, reset-credit inventory, and non-Codex limit buckets are ignored.
public struct CodexAppServerRateLimitParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> ProviderUsage {
        do {
            let response = try JSONDecoder().decode(CodexAppServerRateLimitsResponse.self, from: data)
            let snapshot = response.rateLimitsByLimitID?["codex"] ?? response.rateLimits
            guard let weekly = snapshot?.weeklyWindow else {
                throw UsageParsingError.parseFailure
            }

            return ProviderUsage(
                fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
                weekly: UsageWindow(
                    percentRemaining: remainingPercent(fromUsed: weekly.usedPercent),
                    resetsAt: weekly.resetsAt.map(Date.init(timeIntervalSince1970:))
                )
            )
        } catch {
            throw UsageParsingError.parseFailure
        }
    }
}

private struct CodexAppServerRateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshot?
    let rateLimitsByLimitID: [String: RateLimitSnapshot]?

    enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
    }
}

private struct RateLimitSnapshot: Decodable {
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?

    var weeklyWindow: RateLimitWindow? {
        if secondary?.windowDurationMinutes == 10_080 {
            return secondary
        }
        if primary?.windowDurationMinutes == 10_080 {
            return primary
        }

        // Older app-server builds omitted the duration from the legacy
        // secondary weekly window. Never extend this compatibility to primary:
        // a duration-less primary may be the old 5-hour window.
        if let secondary, secondary.windowDurationMinutes == nil {
            return secondary
        }
        return nil
    }
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMinutes: Int?
    let resetsAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowDurationMinutes = "windowDurationMins"
        case resetsAt
    }
}

private func remainingPercent(fromUsed usedPercent: Double) -> Int {
    if usedPercent <= 0 {
        return 100
    }
    if usedPercent >= 100 {
        return 0
    }
    return 100 - Int(usedPercent.rounded())
}
