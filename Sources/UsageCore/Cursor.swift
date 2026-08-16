import Foundation
import SQLite3

public struct CursorSessionCredential: Sendable, Equatable {
    public let accessToken: String
    public let cookieValue: String
    public let expiresAt: Date

    public init(accessToken: String, cookieValue: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.cookieValue = cookieValue
        self.expiresAt = expiresAt
    }
}

public enum CursorCredentialReadResult: Equatable, Sendable {
    case fresh(CursorSessionCredential)
    case stale(reason: StaleReason)
}

public protocol CursorCredentialReading: Sendable {
    func read(mode: CredentialAccessMode, now: Date) throws -> CursorCredentialReadResult
}

public extension CursorCredentialReading {
    func read(mode: CredentialAccessMode) throws -> CursorCredentialReadResult {
        try read(mode: mode, now: Date())
    }
}

public struct CursorIDECredentialReader: CursorCredentialReading {
    public static let accessTokenKey = "cursorAuth/accessToken"

    private let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(
            databaseURL: homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Cursor", isDirectory: true)
                .appendingPathComponent("User", isDirectory: true)
                .appendingPathComponent("globalStorage", isDirectory: true)
                .appendingPathComponent("state.vscdb")
        )
    }

    public func read(mode _: CredentialAccessMode, now: Date) throws -> CursorCredentialReadResult {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .stale(reason: .credentialUnavailable)
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            return .stale(reason: .credentialUnavailable)
        }
        defer { sqlite3_close(database) }

        let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .stale(reason: .credentialUnavailable)
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return .stale(reason: .credentialUnavailable)
        }

        guard let bytes = sqlite3_column_text(statement, 0) else {
            return .stale(reason: .credentialUnavailable)
        }
        let accessToken = String(cString: bytes)
        guard !accessToken.isEmpty else {
            return .stale(reason: .credentialUnavailable)
        }

        do {
            let credential = try CursorSessionCredential.derived(from: accessToken)
            if credential.expiresAt <= now {
                return .stale(reason: .tokenExpired)
            }
            return .fresh(credential)
        } catch {
            return .stale(reason: .parseFailure)
        }
    }
}

extension CursorSessionCredential {
    enum DerivationError: Error {
        case invalidToken
    }

    static func derived(from accessToken: String) throws -> CursorSessionCredential {
        let claims = try JWTClaims.parse(accessToken)
        guard let subject = claims.subject, !subject.isEmpty, let expiresAt = claims.expiresAt else {
            throw DerivationError.invalidToken
        }

        let userID: String
        if let separator = subject.lastIndex(of: "|") {
            userID = String(subject[subject.index(after: separator)...])
        } else {
            userID = subject
        }
        guard !userID.isEmpty else {
            throw DerivationError.invalidToken
        }

        return CursorSessionCredential(
            accessToken: accessToken,
            cookieValue: "\(userID)%3A%3A\(accessToken)",
            expiresAt: expiresAt
        )
    }
}

private struct JWTClaims {
    let subject: String?
    let expiresAt: Date?

    static func parse(_ jwt: String) throws -> JWTClaims {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            throw CursorSessionCredential.DerivationError.invalidToken
        }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }

        guard let data = Data(base64Encoded: payload),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CursorSessionCredential.DerivationError.invalidToken
        }

        let subject = json["sub"] as? String
        let expiresAt: Date?
        if let exp = json["exp"] as? Double {
            expiresAt = Date(timeIntervalSince1970: exp)
        } else if let exp = json["exp"] as? Int {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(exp))
        } else {
            expiresAt = nil
        }
        return JWTClaims(subject: subject, expiresAt: expiresAt)
    }
}

public struct CursorUsageSummaryResponse: Sendable, Equatable {
    public let data: Data
    public let receivedAt: Date

    public init(data: Data, receivedAt: Date) {
        self.data = data
        self.receivedAt = receivedAt
    }
}

public enum CursorUsageTransportError: Error, Equatable, Sendable {
    case notAuthenticated
}

public struct CursorUsageSummaryParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> ProviderUsage {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageParsingError.parseFailure
        }

        guard let plan = response.individualUsage?.plan, let apiPercentUsed = plan.apiPercentUsed else {
            throw UsageParsingError.parseFailure
        }

        let resetsAt = Self.parseReset(response.billingCycleEnd)
        let otherModels = try Self.window(usedPercentage: apiPercentUsed, resetsAt: resetsAt)
        let cursorModels: UsageWindow
        if let autoPercentUsed = plan.autoPercentUsed {
            cursorModels = try Self.window(usedPercentage: autoPercentUsed, resetsAt: resetsAt)
        } else {
            cursorModels = UsageWindow(percentRemaining: nil, resetsAt: nil)
        }

        return ProviderUsage(
            fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
            weekly: cursorModels,
            monthly: otherModels
        )
    }

    private static func window(usedPercentage: Double, resetsAt: Date?) throws -> UsageWindow {
        guard usedPercentage.isFinite else {
            throw UsageParsingError.parseFailure
        }
        return UsageWindow(
            percentRemaining: percentRemaining(fromUsedPercentage: usedPercentage),
            resetsAt: resetsAt
        )
    }

    /// Same conversion as `UsageCore.percentRemaining(fromUsedPercentage:)`:
    /// clamp, then `100 - Int(used.rounded())`.
    private static func percentRemaining(fromUsedPercentage usedPercentage: Double) -> Int {
        if usedPercentage <= 0 {
            return 100
        }
        if usedPercentage >= 100 {
            return 0
        }
        return 100 - Int(usedPercentage.rounded())
    }

    private static func parseReset(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else {
            return nil
        }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private struct Response: Decodable {
        let billingCycleEnd: String?
        let individualUsage: IndividualUsage?
    }

    private struct IndividualUsage: Decodable {
        let plan: PlanUsage?
    }

    private struct PlanUsage: Decodable {
        let apiPercentUsed: Double?
        let autoPercentUsed: Double?
    }
}

public protocol CursorUsageTransporting: Sendable {
    func fetchUsageSummary(credential: CursorSessionCredential) async throws -> CursorUsageSummaryResponse
}

public struct CursorUsageHTTPTransport: CursorUsageTransporting {
    public static let endpoint = URL(string: "https://cursor.com/api/usage-summary")!

    private let sender: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        sender: any HTTPTransport = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sender = sender
        self.now = now
    }

    public func fetchUsageSummary(credential: CursorSessionCredential) async throws -> CursorUsageSummaryResponse {
        let (data, response) = try await sender.send(Self.request(for: credential))
        if response.statusCode == 401 {
            throw CursorUsageTransportError.notAuthenticated
        }
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return CursorUsageSummaryResponse(data: data, receivedAt: now())
    }

    private static func request(for credential: CursorSessionCredential) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(
            "WorkosCursorSessionToken=\(credential.cookieValue)",
            forHTTPHeaderField: "Cookie"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard/spending", forHTTPHeaderField: "Referer")
        request.setValue("AIUsageBar/\(UsageCore.version)", forHTTPHeaderField: "User-Agent")
        return request
    }
}

public struct CursorUsageProvider: UsageProvider {
    private let credentialReader: any CursorCredentialReading
    private let transport: any CursorUsageTransporting
    private let parser: CursorUsageSummaryParser
    private let now: @Sendable () -> Date

    public init(
        credentialReader: any CursorCredentialReading,
        transport: any CursorUsageTransporting,
        parser: CursorUsageSummaryParser = CursorUsageSummaryParser(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialReader = credentialReader
        self.transport = transport
        self.parser = parser
        self.now = now
    }

    public func fetch(previous: ProviderUsage?, mode: CredentialAccessMode) async -> ProviderState {
        await fetchReport(previous: previous, mode: mode).state
    }

    public func fetchReport(
        previous: ProviderUsage?,
        mode: CredentialAccessMode
    ) async -> ProviderFetchReport {
        let credential: CursorSessionCredential
        do {
            switch try credentialReader.read(mode: mode, now: now()) {
            case let .fresh(fresh):
                credential = fresh
            case let .stale(reason):
                return ProviderFetchReport(
                    state: .stale(last: previous, reason: reason),
                    chain: [ProviderDataSourceStep(.cursorUsageSummary, .failed(reason))]
                )
            }
        } catch {
            return ProviderFetchReport(
                state: .stale(last: previous, reason: .credentialUnavailable),
                chain: [ProviderDataSourceStep(
                    .cursorUsageSummary,
                    .failed(.credentialUnavailable)
                )]
            )
        }

        let state: ProviderState
        do {
            let response = try await transport.fetchUsageSummary(credential: credential)
            let usage = try parser.parse(response.data)
            state = .fresh(usage, asOf: response.receivedAt)
        } catch CursorUsageTransportError.notAuthenticated {
            state = .stale(last: previous, reason: .tokenExpired)
        } catch UsageParsingError.parseFailure {
            state = .stale(last: previous, reason: .parseFailure)
        } catch {
            state = .stale(last: previous, reason: .networkError)
        }

        let step = ProviderDataSourceStep.singlePath(.cursorUsageSummary, state: state)
        return ProviderFetchReport(state: state, chain: [step])
    }
}
