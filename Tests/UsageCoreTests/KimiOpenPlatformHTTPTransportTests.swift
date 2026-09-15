import Foundation
import Testing
import UsageCore

@Test
func kimiOpenPlatformHTTPTransportGETsFixedIntlEndpointWithBearer() async throws {
    let body = Data("{}".utf8)
    let sender = RecordingHTTPTransport(
        response: (body, try httpResponse(url: KimiOpenPlatformHTTPTransport.endpoint, statusCode: 200))
    )
    let transport = KimiOpenPlatformHTTPTransport(sender: sender)

    _ = try await transport.fetchBalance(credential: KimiOpenPlatformCredential(key: "sk-test"))

    let request = try #require(sender.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://api.moonshot.ai/v1/users/me/balance")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("AIUsageBar/") == true)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(request.value(forHTTPHeaderField: "Origin") == nil)
    #expect(request.value(forHTTPHeaderField: "Referer") == nil)
}

@Test
func kimiOpenPlatformHTTPTransportDoesNotTargetChinaOrKimiCodeHosts() {
    // Product pin: extra hosts are a new decision, not a silent fallback.
    let url = KimiOpenPlatformHTTPTransport.endpoint.absoluteString
    #expect(url == "https://api.moonshot.ai/v1/users/me/balance")
    #expect(!url.contains("moonshot.cn"))
    #expect(!url.contains("kimi.com"))
    #expect(!url.contains("kimi.ai"))
}

@Test
func kimiOpenPlatformHTTPTransportReturnsBodyAndInjectedReceivedAtOn2xx() async throws {
    let frozenNow = Date(timeIntervalSince1970: 1_783_000_000)
    let body = Data("{}".utf8)
    let sender = RecordingHTTPTransport(
        response: (body, try httpResponse(url: KimiOpenPlatformHTTPTransport.endpoint, statusCode: 200))
    )
    let transport = KimiOpenPlatformHTTPTransport(sender: sender, now: { frozenNow })

    let response = try await transport.fetchBalance(credential: KimiOpenPlatformCredential(key: "sk-test"))

    #expect(response.data == body)
    #expect(response.receivedAt == frozenNow)
}

@Test
func kimiOpenPlatformHTTPTransportAcceptsAny2xx() async throws {
    let frozenNow = Date(timeIntervalSince1970: 1_783_000_000)
    let body = Data("{}".utf8)
    let sender = RecordingHTTPTransport(
        response: (body, try httpResponse(url: KimiOpenPlatformHTTPTransport.endpoint, statusCode: 204))
    )
    let transport = KimiOpenPlatformHTTPTransport(sender: sender, now: { frozenNow })

    let response = try await transport.fetchBalance(credential: KimiOpenPlatformCredential(key: "sk-test"))

    #expect(response.data == body)
    #expect(response.receivedAt == frozenNow)
}

@Test
func kimiOpenPlatformHTTPTransportThrowsNotAuthenticatedOn401() async throws {
    let sender = RecordingHTTPTransport(
        response: (Data(), try httpResponse(url: KimiOpenPlatformHTTPTransport.endpoint, statusCode: 401))
    )
    let transport = KimiOpenPlatformHTTPTransport(sender: sender)

    await #expect(throws: KimiOpenPlatformTransportError.notAuthenticated) {
        _ = try await transport.fetchBalance(credential: KimiOpenPlatformCredential(key: "sk-bad"))
    }
}

@Test(arguments: [403, 500])
func kimiOpenPlatformHTTPTransportThrowsOnOtherNon2xx(statusCode: Int) async throws {
    let sender = RecordingHTTPTransport(
        response: (Data(), try httpResponse(url: KimiOpenPlatformHTTPTransport.endpoint, statusCode: statusCode))
    )
    let transport = KimiOpenPlatformHTTPTransport(sender: sender)

    await #expect(throws: URLError(.badServerResponse)) {
        _ = try await transport.fetchBalance(credential: KimiOpenPlatformCredential(key: "sk-test"))
    }
}

@Test
func kimiOpenPlatformHTTPTransportPropagatesSenderErrors() async {
    let sender = RecordingHTTPTransport(error: URLError(.timedOut))
    let transport = KimiOpenPlatformHTTPTransport(sender: sender)

    await #expect(throws: URLError(.timedOut)) {
        _ = try await transport.fetchBalance(credential: KimiOpenPlatformCredential(key: "sk-test"))
    }
}

@Test
func kimiOpenPlatformHTTPTransportDoesNotInspectSuccessBody() async throws {
    let fixture = try fixtureData("kimi-open-platform-balance.json")
    let sender = RecordingHTTPTransport(
        response: (fixture, try httpResponse(url: KimiOpenPlatformHTTPTransport.endpoint, statusCode: 200))
    )
    let transport = KimiOpenPlatformHTTPTransport(sender: sender)

    let response = try await transport.fetchBalance(credential: KimiOpenPlatformCredential(key: "sk-test"))

    #expect(response.data == fixture)
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
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(
        contentsOf: packageRoot
            .appendingPathComponent("Tests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    )
}
