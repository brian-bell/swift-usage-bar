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

    await #expect(throws: (any Error).self) {
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
    let fixture = try fixtureData("minimax-token-plan-auth-failure.json")
    let sender = RecordingHTTPTransport(
        response: (fixture, try httpResponse(url: MiniMaxHTTPTransport.endpoint, statusCode: 200))
    )
    let transport = MiniMaxHTTPTransport(sender: sender)

    let response = try await transport.fetchTokenPlan(credential: MiniMaxCredential(key: "sk-test"))

    #expect(response.data == fixture)
    // Specifically: no `MiniMaxTokenPlanParser.AuthFailure.rejectedKey` is thrown by the transport.
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
