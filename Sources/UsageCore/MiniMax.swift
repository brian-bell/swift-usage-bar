import Foundation

public struct MiniMaxCredential: Sendable, Equatable {
    public let key: String
    public init(key: String) { self.key = key }
}

public enum MiniMaxCredentialReadResult: Equatable, Sendable {
    case fresh(MiniMaxCredential)
    case stale(reason: StaleReason)
}

public protocol MiniMaxCredentialReading: Sendable {
    func read(mode: CredentialAccessMode) throws -> MiniMaxCredentialReadResult
}

public extension MiniMaxCredentialReading {
    func read() throws -> MiniMaxCredentialReadResult {
        try read(mode: .background)
    }
}

public struct OpenCodeAuthFileCredentialReader: MiniMaxCredentialReading {
    public static let entryKey = "minimax-coding-plan"

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

    public func read(mode _: CredentialAccessMode) throws -> MiniMaxCredentialReadResult {
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
        return .fresh(MiniMaxCredential(key: key))
    }
}

public struct MiniMaxTokenPlanResponse: Sendable, Equatable {
    public let data: Data
    public let receivedAt: Date

    public init(data: Data, receivedAt: Date) {
        self.data = data
        self.receivedAt = receivedAt
    }
}

public struct MiniMaxTokenPlanParser: Sendable {
    /// The API rejected the subscription key (`base_resp.status_code == 1004`).
    public enum AuthFailure: Error, Equatable, Sendable {
        case rejectedKey
    }

    public init() {}

    /// Returns parsed usage. Throws `AuthFailure.rejectedKey` when the body
    /// signals the key was rejected. Throws `UsageParsingError.parseFailure`
    /// for every other unparseable body.
    public func parse(_ data: Data) throws -> ProviderUsage {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageParsingError.parseFailure
        }

        if response.baseResp.statusCode == 1004 {
            throw AuthFailure.rejectedKey
        }
        guard response.baseResp.statusCode == 0 else {
            throw UsageParsingError.parseFailure
        }

        let general = response.modelRemains
            .compactMap(\.value)
            .first { $0.modelName == "general" }
        guard let general else {
            throw UsageParsingError.parseFailure
        }

        let fiveHour = try Self.window(
            percentRemaining: general.currentIntervalRemainingPercent,
            endTimeMilliseconds: general.endTime
        )
        let weekly = try Self.window(
            percentRemaining: general.currentWeeklyRemainingPercent,
            endTimeMilliseconds: general.weeklyEndTime
        )

        return ProviderUsage(fiveHour: fiveHour, weekly: weekly, monthly: nil)
    }

    private static func window(
        percentRemaining: Double?,
        endTimeMilliseconds: Int64?
    ) throws -> UsageWindow {
        guard let percentRemaining,
              percentRemaining.isFinite,
              (0...100).contains(percentRemaining)
        else {
            throw UsageParsingError.parseFailure
        }

        let resetsAt: Date?
        if let endTimeMilliseconds {
            resetsAt = Date(timeIntervalSince1970: TimeInterval(endTimeMilliseconds) / 1000)
        } else {
            resetsAt = nil
        }

        return UsageWindow(
            percentRemaining: Int(percentRemaining.rounded()),
            resetsAt: resetsAt
        )
    }

    private struct Response: Decodable {
        let modelRemains: [FailableDecodable<Entry>]
        let baseResp: BaseResp

        enum CodingKeys: String, CodingKey {
            case modelRemains = "model_remains"
            case baseResp = "base_resp"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Lossy: a malformed sibling entry must not poison a valid
            // `general` entry (matches the Claude `limits` precedent).
            modelRemains = (try? container.decodeIfPresent(
                [FailableDecodable<Entry>].self,
                forKey: .modelRemains
            )) ?? []
            baseResp = try container.decode(BaseResp.self, forKey: .baseResp)
        }
    }

    private struct Entry: Decodable {
        let modelName: String
        let endTime: Int64?
        let currentIntervalRemainingPercent: Double?
        let weeklyEndTime: Int64?
        let currentWeeklyRemainingPercent: Double?

        enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case endTime = "end_time"
            case currentIntervalRemainingPercent = "current_interval_remaining_percent"
            case weeklyEndTime = "weekly_end_time"
            case currentWeeklyRemainingPercent = "current_weekly_remaining_percent"
        }
    }

    private struct BaseResp: Decodable {
        let statusCode: Int

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
        }
    }
}

/// Local mirror of `UsageCore.FailableDecodable` (which is `private` to
/// `UsageCore.swift`). Decodes each array element independently so a
/// malformed sibling entry drops to `nil` instead of throwing out of
/// the enclosing container.
private struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

public protocol MiniMaxTransporting: Sendable {
    func fetchTokenPlan(credential: MiniMaxCredential) async throws -> MiniMaxTokenPlanResponse
}

public struct MiniMaxUsageProvider: UsageProvider {
    private let credentialReader: any MiniMaxCredentialReading
    private let transport: any MiniMaxTransporting
    private let parser: MiniMaxTokenPlanParser

    public init(
        credentialReader: any MiniMaxCredentialReading,
        transport: any MiniMaxTransporting,
        parser: MiniMaxTokenPlanParser = MiniMaxTokenPlanParser()
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
        let credential: MiniMaxCredential
        do {
            switch try credentialReader.read(mode: mode) {
            case let .fresh(fresh):
                credential = fresh
            case let .stale(reason):
                return ProviderFetchReport(
                    state: .stale(last: previous, reason: reason),
                    chain: [ProviderDataSourceStep(.minimaxTokenPlanAPI, .failed(reason))]
                )
            }
        } catch {
            return ProviderFetchReport(
                state: .stale(last: previous, reason: .credentialUnavailable),
                chain: [ProviderDataSourceStep(
                    .minimaxTokenPlanAPI,
                    .failed(.credentialUnavailable)
                )]
            )
        }

        let state: ProviderState
        do {
            let response = try await transport.fetchTokenPlan(credential: credential)
            let usage = try parser.parse(response.data)
            state = .fresh(usage, asOf: response.receivedAt)
        } catch MiniMaxTokenPlanParser.AuthFailure.rejectedKey {
            state = .stale(last: previous, reason: .tokenExpired)
        } catch UsageParsingError.parseFailure {
            state = .stale(last: previous, reason: .parseFailure)
        } catch {
            state = .stale(last: previous, reason: .networkError)
        }

        let step = ProviderDataSourceStep.singlePath(.minimaxTokenPlanAPI, state: state)
        return ProviderFetchReport(state: state, chain: [step])
    }
}
