import Foundation
import Testing
import UsageCore

@Test
func miniMaxHTTPTransportGETsFixedEndpointWithBearerAndJSONContentType() async throws {
    let body = Data("{}".utf8)
    let sender = RecordingHTTPTransport(
        response: (body, try httpResponse(url: MiniMaxHTTPTransport.endpoint, statusCode: 200))
    )
    let transport = MiniMaxHTTPTransport(sender: sender)

    _ = try await transport.fetchTokenPlan(credential: MiniMaxCredential(key: "sk-test"))

    let request = try #require(sender.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://api.minimax.io/v1/token_plan/remains")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("AIUsageBar/") == true)
    // This endpoint is a plain API key — no Cloudflare, no browser session,
    // no mobile-style headers. Asserting the absence keeps the contract
    // honest: a future "let's also send Origin/Referer" change has to
    // update these tests. (The Sec-Fetch-* family is implied by the
    // absence of those — adding Cookie and Origin already would send
    // means adding Sec-Fetch-* is the next likely step.)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(request.value(forHTTPHeaderField: "Origin") == nil)
    #expect(request.value(forHTTPHeaderField: "Referer") == nil)
}

@Test
func miniMaxHTTPTransportReturnsBodyAndInjectedReceivedAtOn2xx() async throws {
    let frozenNow = Date(timeIntervalSince1970: 1_783_000_000)
    let body = Data("{}".utf8)
    let sender = RecordingHTTPTransport(
        response: (body, try httpResponse(url: MiniMaxHTTPTransport.endpoint, statusCode: 200))
    )
    let transport = MiniMaxHTTPTransport(sender: sender, now: { frozenNow })

    let response = try await transport.fetchTokenPlan(credential: MiniMaxCredential(key: "sk-test"))

    #expect(response.data == body)
    #expect(response.receivedAt == frozenNow)
}

@Test
func miniMaxHTTPTransportAcceptsAny2xx() async throws {
    // Transport-level only: any 2xx (including 204 No Content) is the
    // HTTP layer's contract — the bytes are handed to the parser, which
    // will then surface `.parseFailure` for a body the parser can't read.
    // What we pin here is purely that the HTTP guard is `200..<300`,
    // not `== 200`.
    let frozenNow = Date(timeIntervalSince1970: 1_783_000_000)
    let body = Data("{}".utf8)
    let sender = RecordingHTTPTransport(
        response: (body, try httpResponse(url: MiniMaxHTTPTransport.endpoint, statusCode: 204))
    )
    let transport = MiniMaxHTTPTransport(sender: sender, now: { frozenNow })

    let response = try await transport.fetchTokenPlan(credential: MiniMaxCredential(key: "sk-test"))

    #expect(response.data == body)
    #expect(response.receivedAt == frozenNow)
}

@Test(arguments: [401, 403, 500])
func miniMaxHTTPTransportThrowsOnNon2xx(statusCode: Int) async throws {
    let sender = RecordingHTTPTransport(
        response: (Data(), try httpResponse(url: MiniMaxHTTPTransport.endpoint, statusCode: statusCode))
    )
    let transport = MiniMaxHTTPTransport(sender: sender)

    // The transport throws `URLError(.badServerResponse)` for every
    // non-2xx; the provider's generic catch then maps that to
    // `.networkError`. Pinning the exact error keeps a regression to
    // `URLError(.cannotConnectToHost)` or a custom error type from
    // silently slipping through.
    await #expect(throws: URLError(.badServerResponse)) {
        _ = try await transport.fetchTokenPlan(credential: MiniMaxCredential(key: "sk-test"))
    }
}

@Test
func miniMaxHTTPTransportPropagatesSenderErrors() async {
    let sender = RecordingHTTPTransport(error: URLError(.timedOut))
    let transport = MiniMaxHTTPTransport(sender: sender)

    await #expect(throws: URLError(.timedOut)) {
        _ = try await transport.fetchTokenPlan(credential: MiniMaxCredential(key: "sk-test"))
    }
}

@Test
func miniMaxHTTPTransportDoesNotInspectBodyForAuthFailure() async throws {
    // MiniMax's auth failure is body-shaped (HTTP 200 + base_resp.status_code == 1004);
    // the transport must hand the bytes to the parser, not interpret them itself.
    // Piping the bytes through the provider's generic parse failure mapping
    // additionally proves the transport does not throw the parser's
    // `AuthFailure.rejectedKey` token either — if it did, the run-time test
    // would fail with a throw that the test's `await` framework would
    // surface, not the silent `data` return.
    let fixture = try fixtureData("minimax-token-plan-auth-failure.json")
    let sender = RecordingHTTPTransport(
        response: (fixture, try httpResponse(url: MiniMaxHTTPTransport.endpoint, statusCode: 200))
    )
    let transport = MiniMaxHTTPTransport(sender: sender)

    let response = try await transport.fetchTokenPlan(credential: MiniMaxCredential(key: "sk-test"))

    #expect(response.data == fixture)
}

@Test
func miniMaxHTTPTransportBodyForAuthFailureRoundTripsThroughTheParser() async throws {
    // Companion to the body-not-inspected test: feed the auth-failure
    // fixture back through the provider's parser and assert the response
    // bytes are the same ones the parser sees. Pins both halves of the
    // ownership split — the transport never invents a `rejectedKey`
    // decision, and the parser receives the unmodified body.
    let fixture = try fixtureData("minimax-token-plan-auth-failure.json")
    let sender = RecordingHTTPTransport(
        response: (fixture, try httpResponse(url: MiniMaxHTTPTransport.endpoint, statusCode: 200))
    )
    let transport = MiniMaxHTTPTransport(sender: sender)

    let response = try await transport.fetchTokenPlan(credential: MiniMaxCredential(key: "sk-test"))

    do {
        _ = try MiniMaxTokenPlanParser().parse(response.data)
        Issue.record("Auth-failure fixture should throw AuthFailure.rejectedKey")
    } catch MiniMaxTokenPlanParser.AuthFailure.rejectedKey {
        // Expected: the parser — not the transport — catches the 1004.
    } catch {
        Issue.record("Unexpected error type from the parser: \(error)")
    }
}

private final class RecordingHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let response: (Data, HTTPURLResponse)?
    private let error: (any Error)?
    private(set) var requests: [URLRequest] = []

    init(response: (Data, HTTPURLResponse)) {
        self.response = response
        self.error = nil
    }

    init(error: any Error) {
        self.response = nil
        self.error = error
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let error {
            throw error
        }
        return response!
    }
}

private func httpResponse(url: URL, statusCode: Int) throws -> HTTPURLResponse {
    try #require(
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
    )
}

private func fixtureData(_ name: String) throws -> Data {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtureURL = packageRoot
        .appendingPathComponent("Tests")
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)

    return try Data(contentsOf: fixtureURL)
}
