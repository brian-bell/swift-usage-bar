import Foundation
import Testing
@testable import UsageCore

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
private let usageBody = Data(#"{"five_hour":{"utilization":5.0}}"#.utf8)
private let bootstrapBody = Data("""
{"account":{"memberships":[
  {"organization":{"uuid":"api-org","capabilities":["api","api_individual"]}},
  {"organization":{"uuid":"max-org","capabilities":["chat","claude_max"]}}
]}}
""".utf8)

@Test
func transportUsesOrgHintWithASingleRequestOnTheCommonPath() async throws {
    let sender = StubSender(routes: [
        "/api/organizations/max-org/usage": .init(status: 200, body: usageBody),
    ])
    let transport = ClaudeWebHTTPTransport(sender: sender, userAgent: "UA", now: { epoch })
    let session = ClaudeWebSession(cookieHeader: "sessionKey=x", organizationHint: "max-org")

    let response = try await transport.fetchUsage(session: session)

    #expect(response.data == usageBody)
    #expect(response.receivedAt == epoch)
    #expect(sender.paths == ["/api/organizations/max-org/usage"])
}

@Test
func transportFallsBackToBootstrapDiscoveryWhenHintedOrg404s() async throws {
    let sender = StubSender(routes: [
        "/api/organizations/stale-org/usage": .init(status: 404, body: Data("not found".utf8)),
        "/api/bootstrap": .init(status: 200, body: bootstrapBody),
        "/api/organizations/max-org/usage": .init(status: 200, body: usageBody),
    ])
    let transport = ClaudeWebHTTPTransport(sender: sender, userAgent: "UA", now: { epoch })
    let session = ClaudeWebSession(cookieHeader: "sessionKey=x", organizationHint: "stale-org")

    let response = try await transport.fetchUsage(session: session)

    #expect(response.data == usageBody)
    #expect(sender.paths == [
        "/api/organizations/stale-org/usage",
        "/api/bootstrap",
        "/api/organizations/max-org/usage",
    ])
}

@Test
func transportDiscoversOrgWhenNoHintPresent() async throws {
    let sender = StubSender(routes: [
        "/api/bootstrap": .init(status: 200, body: bootstrapBody),
        "/api/organizations/max-org/usage": .init(status: 200, body: usageBody),
    ])
    let transport = ClaudeWebHTTPTransport(sender: sender, userAgent: "UA", now: { epoch })
    let session = ClaudeWebSession(cookieHeader: "sessionKey=x", organizationHint: nil)

    let response = try await transport.fetchUsage(session: session)

    #expect(response.data == usageBody)
    #expect(sender.paths == ["/api/bootstrap", "/api/organizations/max-org/usage"])
}

@Test(arguments: [401, 403, 302])
func transportMapsAuthFailuresToSessionExpired(_ status: Int) async throws {
    let sender = StubSender(routes: [
        "/api/organizations/max-org/usage": .init(status: status, body: Data()),
    ])
    let transport = ClaudeWebHTTPTransport(sender: sender, userAgent: "UA", now: { epoch })
    let session = ClaudeWebSession(cookieHeader: "sessionKey=x", organizationHint: "max-org")

    await #expect(throws: ClaudeWebTransportError.sessionExpired) {
        try await transport.fetchUsage(session: session)
    }
}

@Test
func transportMapsCloudflareChallengeHTMLToSessionExpired() async throws {
    let sender = StubSender(routes: [
        "/api/organizations/max-org/usage": .init(
            status: 200,
            body: Data("<!DOCTYPE html><title>Just a moment...</title>".utf8)
        ),
    ])
    let transport = ClaudeWebHTTPTransport(sender: sender, userAgent: "UA", now: { epoch })
    let session = ClaudeWebSession(cookieHeader: "sessionKey=x", organizationHint: "max-org")

    await #expect(throws: ClaudeWebTransportError.sessionExpired) {
        try await transport.fetchUsage(session: session)
    }
}

@Test
func transportThrowsParseFailureWhenBootstrapHasNoSubscriptionOrg() async throws {
    let sender = StubSender(routes: [
        "/api/bootstrap": .init(
            status: 200,
            body: Data(#"{"account":{"memberships":[{"organization":{"uuid":"api-org","capabilities":["api"]}}]}}"#.utf8)
        ),
    ])
    let transport = ClaudeWebHTTPTransport(sender: sender, userAgent: "UA", now: { epoch })
    let session = ClaudeWebSession(cookieHeader: "sessionKey=x", organizationHint: nil)

    await #expect(throws: ClaudeWebTransportError.parseFailure) {
        try await transport.fetchUsage(session: session)
    }
}

@Test
func transportAttachesCookieUserAgentAndOriginHeaders() async throws {
    let sender = StubSender(routes: [
        "/api/organizations/max-org/usage": .init(status: 200, body: usageBody),
    ])
    let transport = ClaudeWebHTTPTransport(sender: sender, userAgent: "TestChrome/1", now: { epoch })
    let session = ClaudeWebSession(cookieHeader: "sessionKey=secret", organizationHint: "max-org")

    _ = try await transport.fetchUsage(session: session)

    let request = try #require(sender.requests.first)
    #expect(request.value(forHTTPHeaderField: "Cookie") == "sessionKey=secret")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "TestChrome/1")
    #expect(request.value(forHTTPHeaderField: "Origin") == "https://claude.ai")
}

@Test
func organizationSelectionPicksSubscriptionOrgFromObservedBootstrapFixture() throws {
    let data = try fixtureData("claude-web-bootstrap.json")
    // The claude_max/chat membership wins over the api-only org.
    #expect(ClaudeWebHTTPTransport.organizationID(fromBootstrap: data)
        == "00000000-0000-4000-8000-0000000000b2")
}

@Test
func observedWebUsageFixtureParsesWithTheSharedClaudeParser() throws {
    // The claude.ai web endpoint returns the same schema as the OAuth API, so
    // ClaudeUsageParser consumes it unchanged.
    let usage = try ClaudeUsageParser().parse(try fixtureData("claude-web-usage.json"))
    #expect(usage.fiveHour.percentRemaining == 95)
    #expect(usage.weekly.percentRemaining == 59)
}

@Test
func allowsOnlyExactHostHTTPSClaudeURLs() {
    #expect(ClaudeWebHTTPTransport.isAllowedRequestURL(URL(string: "https://claude.ai/api/bootstrap")!))
    #expect(!ClaudeWebHTTPTransport.isAllowedRequestURL(URL(string: "http://claude.ai/api/bootstrap")!))
    #expect(!ClaudeWebHTTPTransport.isAllowedRequestURL(URL(string: "https://evil.claude.ai/api")!))
    #expect(!ClaudeWebHTTPTransport.isAllowedRequestURL(URL(string: "https://claude.ai.evil.test/api")!))
    #expect(!ClaudeWebHTTPTransport.isAllowedRequestURL(URL(string: "https://api.anthropic.com/api")!))
}

@Test
func looksSignedOutIgnoresLoginSubstringsInsideJSONBodies() {
    // A large JSON payload may legitimately contain "/login" or
    // "/auth/authorize" URLs; those must not be misread as signed-out.
    let json = #"{"account":{"links":{"login":"/login","authorize":"/auth/authorize"}}}"#
    #expect(!ClaudeWebHTTPTransport.looksSignedOut(json))
    #expect(ClaudeWebHTTPTransport.looksSignedOut("<!DOCTYPE html><title>Just a moment...</title>"))
    #expect(ClaudeWebHTTPTransport.looksSignedOut("<html><body>redirecting to /auth/authorize</body></html>"))
}

@Test
func chromeUserAgentReadsInstalledVersionAndFallsBack() throws {
    #expect(ChromeUserAgent.make(version: "150.0.7871.182")
        .contains("Chrome/150.0.7871.182 Safari/537.36"))

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chrome-ua-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let plistURL = directory.appendingPathComponent("Info.plist")
    let plist: [String: Any] = ["CFBundleShortVersionString": "151.2.3.4"]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: plistURL)

    #expect(ChromeUserAgent.installedVersion(infoPlistURL: plistURL) == "151.2.3.4")
    #expect(ChromeUserAgent.installedVersion(
        infoPlistURL: directory.appendingPathComponent("missing.plist")
    ) == nil)

    #expect(ChromeUserAgent.current(infoPlistURLs: [
        directory.appendingPathComponent("missing.plist"), plistURL,
    ]).contains("Chrome/151.2.3.4"))
}

private func fixtureData(_ name: String) throws -> Data {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: packageRoot
        .appendingPathComponent("Tests/Fixtures").appendingPathComponent(name))
}

private struct StubResponse {
    let status: Int
    let body: Data
}

private final class StubSender: HTTPTransport, @unchecked Sendable {
    private let routes: [String: StubResponse]
    private(set) var requests: [URLRequest] = []

    init(routes: [String: StubResponse]) { self.routes = routes }

    var paths: [String] { requests.compactMap { $0.url?.path } }

    // fetchUsage awaits each request sequentially, so no concurrent sends race here.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        guard let route = routes[path] else {
            return (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 599, httpVersion: nil, headerFields: nil)!)
        }
        return (route.body, HTTPURLResponse(
            url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: nil)!)
    }
}
