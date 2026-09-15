import Foundation

public struct KimiOpenPlatformCredential: Sendable, Equatable {
    public let key: String
    public init(key: String) { self.key = key }
}

public enum KimiOpenPlatformCredentialReadResult: Equatable, Sendable {
    case fresh(KimiOpenPlatformCredential)
    case stale(reason: StaleReason)
}

public protocol KimiOpenPlatformCredentialReading: Sendable {
    func read(mode: CredentialAccessMode) throws -> KimiOpenPlatformCredentialReadResult
}

public extension KimiOpenPlatformCredentialReading {
    func read() throws -> KimiOpenPlatformCredentialReadResult {
        try read(mode: .background)
    }
}

/// Read-only OpenCode `auth.json` entry `moonshotai` — the official Kimi
/// Open Platform provider id. The China twin (`moonshotai-cn`) and Kimi
/// Code (`kimi-for-coding`) are different products and are not read.
public struct MoonshotAuthFileCredentialReader: KimiOpenPlatformCredentialReading {
    public static let entryKey = "moonshotai"

    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// Resolves the OpenCode auth file the way OpenCode itself does:
    /// `$XDG_DATA_HOME` when set and non-empty, else
    /// `~/.local/share/opencode/auth.json`.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let dataDirectory: URL
        if let path = environment["XDG_DATA_HOME"], !path.isEmpty {
            dataDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            dataDirectory = homeDirectory
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        self.init(
            fileURL: dataDirectory
                .appendingPathComponent("opencode", isDirectory: true)
                .appendingPathComponent("auth.json")
        )
    }

    public func read(mode _: CredentialAccessMode) throws -> KimiOpenPlatformCredentialReadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .stale(reason: .credentialUnavailable)
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .stale(reason: .credentialUnavailable)
        }
        guard let dictionary = root as? [String: Any],
              let entry = dictionary[Self.entryKey] as? [String: Any],
              let key = entry["key"] as? String,
              !key.isEmpty
        else {
            return .stale(reason: .credentialUnavailable)
        }
        return .fresh(KimiOpenPlatformCredential(key: key))
    }
}

public struct KimiOpenPlatformBalanceResponse: Sendable, Equatable {
    public let data: Data
    public let receivedAt: Date

    public init(data: Data, receivedAt: Date) {
        self.data = data
        self.receivedAt = receivedAt
    }
}

/// Extracts the official remaining-balance meter. The type it returns is
/// numeric-only (`CreditBalance`); `voucher_balance`, `cash_balance`,
/// `scode`, and any payment metadata stay in the raw body.
public struct KimiOpenPlatformBalanceParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> CreditBalance {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageParsingError.parseFailure
        }

        guard response.code == 0, response.status else {
            throw UsageParsingError.parseFailure
        }
        guard response.data.availableBalance.isFinite else {
            throw UsageParsingError.parseFailure
        }

        return CreditBalance(balanceUSD: response.data.availableBalance)
    }

    private struct Response: Decodable {
        let code: Int
        let status: Bool
        let data: BalanceData
    }

    private struct BalanceData: Decodable {
        let availableBalance: Double

        enum CodingKeys: String, CodingKey {
            case availableBalance = "available_balance"
        }
    }
}

public enum KimiOpenPlatformTransportError: Error, Equatable, Sendable {
    /// Official OpenAPI: HTTP 401 is an invalid or missing API key.
    case notAuthenticated
}

public protocol KimiOpenPlatformTransporting: Sendable {
    func fetchBalance(
        credential: KimiOpenPlatformCredential
    ) async throws -> KimiOpenPlatformBalanceResponse
}

public struct KimiOpenPlatformHTTPTransport: KimiOpenPlatformTransporting {
    public static let endpoint = URL(string: "https://api.moonshot.ai/v1/users/me/balance")!

    private let sender: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        sender: any HTTPTransport = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sender = sender
        self.now = now
    }

    public func fetchBalance(
        credential: KimiOpenPlatformCredential
    ) async throws -> KimiOpenPlatformBalanceResponse {
        let (data, response) = try await sender.send(Self.request(for: credential))
        if response.statusCode == 401 {
            throw KimiOpenPlatformTransportError.notAuthenticated
        }
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return KimiOpenPlatformBalanceResponse(data: data, receivedAt: now())
    }

    private static func request(for credential: KimiOpenPlatformCredential) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsageBar/\(UsageCore.version)", forHTTPHeaderField: "User-Agent")
        return request
    }
}

/// Kimi Open Platform remaining-balance provider. Percent windows stay
/// unavailable so the dollar snapshot stays out of tone and thresholds.
public struct KimiOpenPlatformUsageProvider: UsageProvider {
    private let credentialReader: any KimiOpenPlatformCredentialReading
    private let transport: any KimiOpenPlatformTransporting
    private let parser: KimiOpenPlatformBalanceParser

    public init(
        credentialReader: any KimiOpenPlatformCredentialReading,
        transport: any KimiOpenPlatformTransporting,
        parser: KimiOpenPlatformBalanceParser = KimiOpenPlatformBalanceParser()
    ) {
        self.credentialReader = credentialReader
        self.transport = transport
        self.parser = parser
    }

    public func fetch(previous: ProviderUsage?, mode: CredentialAccessMode) async -> ProviderState {
        await fetchReport(previous: previous, mode: mode).state
    }

    public func fetchReport(
        previous: ProviderUsage?,
        mode: CredentialAccessMode
    ) async -> ProviderFetchReport {
        let credential: KimiOpenPlatformCredential
        do {
            switch try credentialReader.read(mode: mode) {
            case let .fresh(fresh):
                credential = fresh
            case let .stale(reason):
                return ProviderFetchReport(
                    state: .stale(last: previous, reason: reason),
                    chain: [ProviderDataSourceStep(.kimiOpenPlatformBalance, .failed(reason))]
                )
            }
        } catch {
            return ProviderFetchReport(
                state: .stale(last: previous, reason: .credentialUnavailable),
                chain: [ProviderDataSourceStep(
                    .kimiOpenPlatformBalance,
                    .failed(.credentialUnavailable)
                )]
            )
        }

        let state: ProviderState
        do {
            let response = try await transport.fetchBalance(credential: credential)
            let credits = try parser.parse(response.data)
            state = .fresh(Self.usage(for: credits), asOf: response.receivedAt)
        } catch KimiOpenPlatformTransportError.notAuthenticated {
            state = .stale(last: previous, reason: .tokenExpired)
        } catch UsageParsingError.parseFailure {
            state = .stale(last: previous, reason: .parseFailure)
        } catch {
            state = .stale(last: previous, reason: .networkError)
        }

        let step = ProviderDataSourceStep.singlePath(.kimiOpenPlatformBalance, state: state)
        return ProviderFetchReport(state: state, chain: [step])
    }

    private static func usage(for credits: CreditBalance) -> ProviderUsage {
        ProviderUsage(
            fiveHour: UsageWindow(percentRemaining: nil, resetsAt: nil),
            weekly: UsageWindow(percentRemaining: nil, resetsAt: nil),
            credits: credits
        )
    }
}
