import Foundation
import Testing
import UsageCore

@Test
func codexUsageProviderBuildsUsageRequestAndReturnsFreshUsage() async throws {
    let asOf = Date(timeIntervalSince1970: 1_783_000_120)
    let credential = CodexCredential(
        accessToken: "access-token",
        accountID: "account-123",
        expiresAt: Date(timeIntervalSince1970: 1_783_006_145)
    )
    let transport = FakeHTTPTransport(response: (
        try fixtureData("codex-usage.json"),
        try httpResponse(statusCode: 200)
    ))
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(result: .fresh(credential)),
        transport: transport,
        now: { asOf }
    )

    let state = await provider.fetch(previous: nil)
    let request = try #require(transport.requests.first)

    #expect(state == .fresh(ProviderUsage(
        fiveHour: UsageWindow(
            percentRemaining: 88,
            resetsAt: Date(timeIntervalSince1970: 1_783_006_145)
        ),
        weekly: UsageWindow(
            percentRemaining: 56,
            resetsAt: Date(timeIntervalSince1970: 1_783_388_608)
        )
    ), asOf: asOf))
    #expect(transport.requests.count == 1)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
    #expect(request.value(forHTTPHeaderField: "User-Agent")?.isEmpty == false)
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-123")
}

@Test
func codexUsageProviderOmitsAccountHeaderWhenCredentialHasNoAccountID() async throws {
    let transport = FakeHTTPTransport(response: (
        try fixtureData("codex-usage.json"),
        try httpResponse(statusCode: 200)
    ))
    let provider = CodexUsageProvider(
        credentialReader: FakeCodexCredentialReader(result: .fresh(CodexCredential(
            accessToken: "access-token",
            accountID: nil,
            expiresAt: Date(timeIntervalSince1970: 1_783_006_145)
        ))),
        transport: transport,
        now: { Date(timeIntervalSince1970: 1_783_000_120) }
    )

    _ = await provider.fetch(previous: nil)
    let request = try #require(transport.requests.first)

    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
}

private final class FakeCodexCredentialReader: CodexCredentialReading, @unchecked Sendable {
    private let result: CodexCredentialReadResult

    init(result: CodexCredentialReadResult) {
        self.result = result
    }

    func read() throws -> CodexCredentialReadResult {
        result
    }
}

private final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let response: (Data, HTTPURLResponse)
    private(set) var requests: [URLRequest] = []

    init(response: (Data, HTTPURLResponse)) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return response
    }
}

private func httpResponse(statusCode: Int) throws -> HTTPURLResponse {
    let url = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))

    return try #require(HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    ))
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
