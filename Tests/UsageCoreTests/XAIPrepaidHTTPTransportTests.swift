import Foundation
import Testing
import UsageCore

@Test
func xaiPrepaidHTTPTransportGETsManagementHostWithBearer() async throws {
    let teamID = "00000000-0000-4000-8000-000000000001"
    let endpoint = XAIPrepaidHTTPTransport.endpoint(teamID: teamID)
    let sender = RecordingHTTPTransport(
        response: (Data("{}".utf8), try httpResponse(url: endpoint, statusCode: 200))
    )
    let transport = XAIPrepaidHTTPTransport(sender: sender)

    _ = try await transport.fetchBalance(
        credential: XAIManagementCredential(key: "xai-mgmt-test", teamID: teamID)
    )

    let request = try #require(sender.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString
        == "https://management-api.x.ai/v1/billing/teams/\(teamID)/prepaid/balance")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer xai-mgmt-test")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("AIUsageBar/") == true)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(request.value(forHTTPHeaderField: "Origin") == nil)
    #expect(request.value(forHTTPHeaderField: "Referer") == nil)
}

@Test
func xaiPrepaidHTTPTransportPinsManagementHostOnly() {
    let url = XAIPrepaidHTTPTransport.endpoint(teamID: "00000000-0000-4000-8000-000000000001")
        .absoluteString
    #expect(url.hasPrefix("https://management-api.x.ai/"))
    #expect(!url.contains("api.x.ai/v1/api-key"))
    #expect(!url.contains("console.x.ai"))
    #expect(!url.contains("grok.com"))
    #expect(!url.contains("cli-chat-proxy.grok.com"))
}

@Test
func xaiPrepaidHTTPTransportReturnsBodyAndInjectedReceivedAtOn2xx() async throws {
    let frozenNow = Date(timeIntervalSince1970: 1_783_000_000)
    let teamID = "00000000-0000-4000-8000-000000000001"
    let body = Data("{}".utf8)
    let sender = RecordingHTTPTransport(
        response: (body, try httpResponse(
            url: XAIPrepaidHTTPTransport.endpoint(teamID: teamID),
            statusCode: 200
        ))
    )
    let transport = XAIPrepaidHTTPTransport(sender: sender, now: { frozenNow })

    let response = try await transport.fetchBalance(
        credential: XAIManagementCredential(key: "k", teamID: teamID)
    )

    #expect(response.data == body)
    #expect(response.receivedAt == frozenNow)
}

@Test(arguments: [401, 403])
func xaiPrepaidHTTPTransportThrowsNotAuthenticatedOnAuthFailure(statusCode: Int) async throws {
    let teamID = "00000000-0000-4000-8000-000000000001"
    let sender = RecordingHTTPTransport(
        response: (Data(), try httpResponse(
            url: XAIPrepaidHTTPTransport.endpoint(teamID: teamID),
            statusCode: statusCode
        ))
    )
    let transport = XAIPrepaidHTTPTransport(sender: sender)

    await #expect(throws: XAIPrepaidTransportError.notAuthenticated) {
        _ = try await transport.fetchBalance(
            credential: XAIManagementCredential(key: "bad", teamID: teamID)
        )
    }
}

@Test
func xaiPrepaidHTTPTransportThrowsPrepaidUnavailableOn404() async throws {
    let teamID = "00000000-0000-4000-8000-000000000001"
    let sender = RecordingHTTPTransport(
        response: (Data(), try httpResponse(
            url: XAIPrepaidHTTPTransport.endpoint(teamID: teamID),
            statusCode: 404
        ))
    )
    let transport = XAIPrepaidHTTPTransport(sender: sender)

    await #expect(throws: XAIPrepaidTransportError.prepaidUnavailable) {
        _ = try await transport.fetchBalance(
            credential: XAIManagementCredential(key: "k", teamID: teamID)
        )
    }
}

@Test
func xaiPrepaidHTTPTransportThrowsOnOtherNon2xx() async throws {
    let teamID = "00000000-0000-4000-8000-000000000001"
    let sender = RecordingHTTPTransport(
        response: (Data(), try httpResponse(
            url: XAIPrepaidHTTPTransport.endpoint(teamID: teamID),
            statusCode: 500
        ))
    )
    let transport = XAIPrepaidHTTPTransport(sender: sender)

    await #expect(throws: URLError(.badServerResponse)) {
        _ = try await transport.fetchBalance(
            credential: XAIManagementCredential(key: "k", teamID: teamID)
        )
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
