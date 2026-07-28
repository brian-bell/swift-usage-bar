import Foundation
import Testing
import UsageCore

@Test
func codexAppServerParserPrefersCodexLimitAndFindsWeeklyWindowByDuration() throws {
    let usage = try CodexAppServerRateLimitParser().parse(
        fixtureData("codex-app-server-rate-limits.json")
    )

    #expect(usage == ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(
            percentRemaining: 68,
            resetsAt: Date(timeIntervalSince1970: 1_783_388_608)
        )
    ))
}

@Test
func codexAppServerParserFallsBackToLegacySingleBucket() throws {
    let data = Data("""
    {
      "rateLimits": {
        "primary": {
          "usedPercent": 41,
          "windowDurationMins": 10080,
          "resetsAt": 1783388608
        }
      }
    }
    """.utf8)

    let usage = try CodexAppServerRateLimitParser().parse(data)

    #expect(usage.weekly.percentRemaining == 59)
    #expect(usage.weekly.resetsAt == Date(timeIntervalSince1970: 1_783_388_608))
}

@Test
func codexAppServerParserAcceptsOnlyLegacySecondaryWhenDurationIsMissing() throws {
    let data = Data("""
    {
      "rateLimits": {
        "primary": {
          "usedPercent": 11,
          "resetsAt": 1783006145
        },
        "secondary": {
          "usedPercent": 34,
          "resetsAt": 1783388608
        }
      }
    }
    """.utf8)

    let usage = try CodexAppServerRateLimitParser().parse(data)

    #expect(usage.weekly.percentRemaining == 66)
    #expect(usage.weekly.resetsAt == Date(timeIntervalSince1970: 1_783_388_608))
}

@Test
func codexAppServerParserRejectsMalformedOrNonWeeklySnapshots() {
    let invalidPayloads = [
        #"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300}}}"#,
        #"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":15}}}"#,
        #"{"rateLimits":{"primary":{"usedPercent":12}}}"#,
        #"{"rateLimits":{"secondary":{"usedPercent":12,"windowDurationMins":300}}}"#,
        #"{"rateLimits":{"primary":{"windowDurationMins":10080}}}"#,
        #"{"rateLimits":null}"#,
        #"not json"#,
        """
        {
          "rateLimits": {
            "primary": {"usedPercent": 20, "windowDurationMins": 10080}
          },
          "rateLimitsByLimitId": {
            "codex": {
              "primary": {"usedPercent": 12, "windowDurationMins": 300}
            }
          }
        }
        """,
    ]

    for payload in invalidPayloads {
        do {
            _ = try CodexAppServerRateLimitParser().parse(Data(payload.utf8))
            Issue.record("Expected parse failure")
        } catch UsageParsingError.parseFailure {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test
func codexAppServerReaderHandshakesIgnoresNotificationsAndReadsRateLimits() async throws {
    let fixture = try fixtureData("codex-app-server-rate-limits.json")
    let fixtureObject = try #require(
        JSONSerialization.jsonObject(with: fixture) as? [String: Any]
    )
    let session = FakeCodexAppServerProcessSession(lines: [
        try jsonLine(["id": 1, "result": ["serverInfo": ["name": "codex"]]]),
        try jsonLine(["method": "account/rateLimits/updated", "params": [:]]),
        try jsonLine(["id": 2, "result": fixtureObject]),
    ])
    let launcher = FakeCodexAppServerProcessLauncher(session: session)
    let reader = CodexAppServerUsageReader(
        helperDiscovery: FakeCodexDesktopHelperDiscovery(
            result: URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        ),
        processLauncher: launcher
    )

    let result = await reader.readUsage()

    #expect(result == .fresh(ProviderUsage(
        fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
        weekly: UsageWindow(
            percentRemaining: 68,
            resetsAt: Date(timeIntervalSince1970: 1_783_388_608)
        )
    )))
    #expect(launcher.launches.count == 1)
    #expect(launcher.launches.first?.arguments == [
        "--sandbox", "read-only",
        "--ask-for-approval", "untrusted",
        "app-server", "--stdio",
    ])

    let messages = try session.writtenLines.map(jsonObject)
    #expect(messages.count == 3)
    #expect(messages[0]["method"] as? String == "initialize")
    let params = try #require(messages[0]["params"] as? [String: Any])
    let clientInfo = try #require(params["clientInfo"] as? [String: Any])
    #expect(clientInfo["name"] as? String == "AIUsageBar")
    #expect(clientInfo["version"] as? String == UsageCore.version)
    #expect(messages[1]["method"] as? String == "initialized")
    #expect(messages[1]["id"] == nil)
    #expect(messages[2]["method"] as? String == "account/rateLimits/read")
    #expect(messages[2]["id"] as? Int == 2)
}

@Test
func codexAppServerReaderReusesInitializedChildAcrossReads() async throws {
    let fixtureObject = try #require(JSONSerialization.jsonObject(
        with: fixtureData("codex-app-server-rate-limits.json")
    ) as? [String: Any])
    let session = FakeCodexAppServerProcessSession(lines: [
        try jsonLine(["id": 1, "result": [:]]),
        try jsonLine(["id": 2, "result": fixtureObject]),
        try jsonLine(["id": 3, "result": fixtureObject]),
    ])
    let launcher = FakeCodexAppServerProcessLauncher(session: session)
    let reader = CodexAppServerUsageReader(
        helperDiscovery: FakeCodexDesktopHelperDiscovery(
            result: URL(fileURLWithPath: "/trusted/codex")
        ),
        processLauncher: launcher
    )

    #expect(await reader.readUsage().isFresh)
    #expect(await reader.readUsage().isFresh)
    #expect(launcher.launches.count == 1)

    let methods = try session.writtenLines.map(jsonObject).compactMap { $0["method"] as? String }
    #expect(methods == [
        "initialize",
        "initialized",
        "account/rateLimits/read",
        "account/rateLimits/read",
    ])
}

@Test
func codexAppServerReaderCleansUpAfterRPCErrorAndRelaunches() async throws {
    let fixtureObject = try #require(JSONSerialization.jsonObject(
        with: fixtureData("codex-app-server-rate-limits.json")
    ) as? [String: Any])
    let failedSession = FakeCodexAppServerProcessSession(lines: [
        try jsonLine(["id": 1, "error": ["code": -32_000, "message": "unavailable"]]),
    ])
    let recoveredSession = FakeCodexAppServerProcessSession(lines: [
        try jsonLine(["id": 2, "result": [:]]),
        try jsonLine(["id": 3, "result": fixtureObject]),
    ])
    let launcher = FakeCodexAppServerProcessLauncher(
        sessions: [failedSession, recoveredSession]
    )
    let reader = CodexAppServerUsageReader(
        helperDiscovery: FakeCodexDesktopHelperDiscovery(
            result: URL(fileURLWithPath: "/trusted/codex")
        ),
        processLauncher: launcher
    )

    #expect(await reader.readUsage() == .stale(reason: .credentialUnavailable))
    #expect(failedSession.terminationCount == 1)
    #expect(await reader.readUsage().isFresh)
    #expect(launcher.launches.count == 2)
}

@Test
func codexAppServerReaderMapsMalformedOversizedAndEOFResponses() async {
    let cases: [(FakeCodexAppServerProcessSession, CodexAppServerUsageReadResult)] = [
        (
            FakeCodexAppServerProcessSession(lines: [Data("not json".utf8)]),
            .stale(reason: .parseFailure)
        ),
        (
            FakeCodexAppServerProcessSession(lines: [Data(repeating: 0x20, count: 1_025)]),
            .stale(reason: .parseFailure)
        ),
        (
            FakeCodexAppServerProcessSession(lines: []),
            .stale(reason: .networkError)
        ),
    ]

    for (session, expected) in cases {
        let reader = CodexAppServerUsageReader(
            helperDiscovery: FakeCodexDesktopHelperDiscovery(
                result: URL(fileURLWithPath: "/trusted/codex")
            ),
            processLauncher: FakeCodexAppServerProcessLauncher(session: session),
            maximumLineBytes: 1_024
        )

        #expect(await reader.readUsage() == expected)
        #expect(session.terminationCount == 1)
    }
}

@Test
func codexAppServerReaderTimesOutAndTerminatesChild() async {
    let session = BlockingCodexAppServerProcessSession()
    let reader = CodexAppServerUsageReader(
        helperDiscovery: FakeCodexDesktopHelperDiscovery(
            result: URL(fileURLWithPath: "/trusted/codex")
        ),
        processLauncher: FakeCodexAppServerProcessLauncher(session: session),
        clock: ImmediateUsageClock(),
        initializationTimeout: 1
    )

    #expect(await reader.readUsage() == .stale(reason: .networkError))
    #expect(session.terminationCount == 1)
    #expect(session.isRunning == false)
}

@Test
func codexAppServerReaderShutdownTerminatesReusableChild() async throws {
    let fixtureObject = try #require(JSONSerialization.jsonObject(
        with: fixtureData("codex-app-server-rate-limits.json")
    ) as? [String: Any])
    let session = FakeCodexAppServerProcessSession(lines: [
        try jsonLine(["id": 1, "result": [:]]),
        try jsonLine(["id": 2, "result": fixtureObject]),
    ])
    let reader = CodexAppServerUsageReader(
        helperDiscovery: FakeCodexDesktopHelperDiscovery(
            result: URL(fileURLWithPath: "/trusted/codex")
        ),
        processLauncher: FakeCodexAppServerProcessLauncher(session: session)
    )
    #expect(await reader.readUsage().isFresh)

    await reader.shutdown()

    #expect(session.terminationCount == 1)
    #expect(session.isRunning == false)
}

@Test
func codexAppServerReaderShutdownPreventsLateReadFromLaunchingChild() async {
    let session = FakeCodexAppServerProcessSession(lines: [])
    let launcher = FakeCodexAppServerProcessLauncher(session: session)
    let reader = CodexAppServerUsageReader(
        helperDiscovery: FakeCodexDesktopHelperDiscovery(
            result: URL(fileURLWithPath: "/trusted/codex")
        ),
        processLauncher: launcher
    )

    await reader.shutdown()
    let result = await reader.readUsage()

    #expect(result == .stale(reason: .credentialUnavailable))
    #expect(launcher.launches.isEmpty)
    #expect(session.terminationCount == 0)
}

@Test
func codexAppServerReaderDoesNotLaunchWhenDesktopAppIsUnavailable() async {
    let launcher = FakeCodexAppServerProcessLauncher(sessions: [])
    let reader = CodexAppServerUsageReader(
        helperDiscovery: FakeCodexDesktopHelperDiscovery(result: nil),
        processLauncher: launcher
    )

    #expect(await reader.readUsage() == .stale(reason: .credentialUnavailable))
    #expect(launcher.launches.isEmpty)
}

@Test
func codexDesktopHelperDiscoveryRequiresContainedExecutableWithOpenAISignature() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let appURL = root.appendingPathComponent("Codex.app", isDirectory: true)
    let helperURL = appURL.appendingPathComponent("Contents/Resources/codex")
    try FileManager.default.createDirectory(
        at: helperURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    #expect(FileManager.default.createFile(atPath: helperURL.path, contents: Data()))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: helperURL.path
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let signature = FakeCodexCodeSignatureValidator(result: true)
    let discovery = CodexDesktopHelperDiscovery(
        appLocator: FakeCodexDesktopAppLocator(result: appURL),
        signatureValidator: signature
    )

    #expect(discovery.locateHelper() == helperURL)
    #expect(signature.requests == [
        .init(url: helperURL, teamIdentifier: "2DC432GLL2"),
    ])
}

@Test
func codexDesktopHelperDiscoveryRejectsMissingUntrustedAndEscapingHelpers() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let appURL = root.appendingPathComponent("Codex.app", isDirectory: true)
    let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    let helperURL = resourcesURL.appendingPathComponent("codex")
    try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let locator = FakeCodexDesktopAppLocator(result: appURL)
    #expect(CodexDesktopHelperDiscovery(
        appLocator: locator,
        signatureValidator: FakeCodexCodeSignatureValidator(result: true)
    ).locateHelper() == nil)

    #expect(FileManager.default.createFile(atPath: helperURL.path, contents: Data()))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    #expect(CodexDesktopHelperDiscovery(
        appLocator: locator,
        signatureValidator: FakeCodexCodeSignatureValidator(result: false)
    ).locateHelper() == nil)

    try FileManager.default.removeItem(at: helperURL)
    let outsideURL = root.appendingPathComponent("outside-codex")
    #expect(FileManager.default.createFile(atPath: outsideURL.path, contents: Data()))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outsideURL.path)
    try FileManager.default.createSymbolicLink(at: helperURL, withDestinationURL: outsideURL)
    #expect(CodexDesktopHelperDiscovery(
        appLocator: locator,
        signatureValidator: FakeCodexCodeSignatureValidator(result: true)
    ).locateHelper() == nil)
}

private func fixtureData(_ name: String) throws -> Data {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: packageRoot
        .appendingPathComponent("Tests/Fixtures")
        .appendingPathComponent(name))
}

private struct FakeCodexDesktopAppLocator: CodexDesktopAppLocating {
    let result: URL?

    func applicationURL(bundleIdentifier: String) -> URL? {
        #expect(bundleIdentifier == "com.openai.codex")
        return result
    }
}

private final class FakeCodexCodeSignatureValidator:
    CodexCodeSignatureValidating,
    @unchecked Sendable
{
    struct Request: Equatable {
        let url: URL
        let teamIdentifier: String
    }

    private let result: Bool
    private(set) var requests: [Request] = []

    init(result: Bool) {
        self.result = result
    }

    func hasValidSignature(at url: URL, teamIdentifier: String) -> Bool {
        requests.append(Request(url: url, teamIdentifier: teamIdentifier))
        return result
    }
}

private struct FakeCodexDesktopHelperDiscovery: CodexDesktopHelperDiscovering {
    let result: URL?

    func locateHelper() -> URL? {
        result
    }
}

private final class FakeCodexAppServerProcessLauncher:
    CodexAppServerProcessLaunching,
    @unchecked Sendable
{
    struct Launch {
        let executableURL: URL
        let arguments: [String]
    }

    private var sessions: [any CodexAppServerProcessSession]
    private(set) var launches: [Launch] = []

    init(session: any CodexAppServerProcessSession) {
        self.sessions = [session]
    }

    init(sessions: [any CodexAppServerProcessSession]) {
        self.sessions = sessions
    }

    func launch(
        executableURL: URL,
        arguments: [String]
    ) throws -> any CodexAppServerProcessSession {
        launches.append(Launch(executableURL: executableURL, arguments: arguments))
        guard !sessions.isEmpty else {
            throw CodexAppServerProcessError.processFailure
        }
        return sessions.removeFirst()
    }
}

private final class FakeCodexAppServerProcessSession:
    CodexAppServerProcessSession,
    @unchecked Sendable
{
    private var lines: [Data?]
    private(set) var writtenLines: [Data] = []
    private(set) var terminationCount = 0
    var isRunning = true

    init(lines: [Data?]) {
        self.lines = lines
    }

    func writeLine(_ data: Data) throws {
        writtenLines.append(data)
    }

    func readLine(maxBytes: Int) async throws -> Data? {
        guard !lines.isEmpty else {
            return nil
        }
        let line = lines.removeFirst()
        if let line, line.count > maxBytes {
            throw CodexAppServerProcessError.responseTooLarge
        }
        return line
    }

    func terminate() {
        guard isRunning else {
            return
        }
        terminationCount += 1
        isRunning = false
    }
}

private final class BlockingCodexAppServerProcessSession:
    CodexAppServerProcessSession,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var running = true
    private var terminations = 0

    var isRunning: Bool {
        lock.withLock { running }
    }

    var terminationCount: Int {
        lock.withLock { terminations }
    }

    func writeLine(_: Data) throws {}

    func readLine(maxBytes _: Int) async throws -> Data? {
        while isRunning {
            await Task.yield()
        }
        return nil
    }

    func terminate() {
        lock.withLock {
            guard running else {
                return
            }
            running = false
            terminations += 1
        }
    }
}

private struct ImmediateUsageClock: UsageClock {
    var now: Date {
        get async { Date(timeIntervalSince1970: 0) }
    }

    func sleep(for _: TimeInterval) async throws {}
}

private func jsonLine(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private extension CodexAppServerUsageReadResult {
    var isFresh: Bool {
        if case .fresh = self {
            return true
        }
        return false
    }
}
