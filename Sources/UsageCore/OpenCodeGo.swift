import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

public struct OpenCodeSession: Sendable, Equatable {
    public let authenticationCookie: String

    public init(authenticationCookie: String) {
        self.authenticationCookie = authenticationCookie
    }
}

public protocol OpenCodeSessionReading: Sendable {
    func readSession(mode: CredentialAccessMode) throws -> OpenCodeSession?
}

public struct ChromeCookieRecord: Sendable, Equatable {
    public let name: String
    public let encryptedValue: Data

    public init(name: String, encryptedValue: Data) {
        self.name = name
        self.encryptedValue = encryptedValue
    }
}

public protocol ChromeOpenCodeCookieReading: Sendable {
    func readCookies() throws -> [ChromeCookieRecord]
}

public protocol ChromeSafeStorageReading: Sendable {
    func readPassword(mode: CredentialAccessMode) throws -> Data?
}

public struct ChromeOpenCodeSessionReader: OpenCodeSessionReading {
    public typealias Decrypt = @Sendable (Data, Data) -> String?

    private let cookieReader: any ChromeOpenCodeCookieReading
    private let safeStorageReader: any ChromeSafeStorageReading
    private let decrypt: Decrypt

    public init(
        cookieReader: any ChromeOpenCodeCookieReading = ChromeCookieDatabaseReader(),
        safeStorageReader: any ChromeSafeStorageReading = ChromeSafeStorageReader(),
        decrypt: @escaping Decrypt = ChromeCookieDecryptor.decrypt
    ) {
        self.cookieReader = cookieReader
        self.safeStorageReader = safeStorageReader
        self.decrypt = decrypt
    }

    public func readSession(mode: CredentialAccessMode) throws -> OpenCodeSession? {
        let allowedNames = ["__Host-auth", "auth"]
        let records = try cookieReader.readCookies()
            .filter { allowedNames.contains($0.name) }
            .sorted { allowedNames.firstIndex(of: $0.name)! < allowedNames.firstIndex(of: $1.name)! }
        guard !records.isEmpty, let password = try safeStorageReader.readPassword(mode: mode) else {
            return nil
        }
        for record in records {
            guard let value = decrypt(record.encryptedValue, password),
                  !value.isEmpty,
                  !value.contains(";") && !value.contains("\r") && !value.contains("\n")
            else { continue }
            return OpenCodeSession(authenticationCookie: "\(record.name)=\(value)")
        }
        return nil
    }
}

public struct ChromeCookieDatabaseReader: ChromeOpenCodeCookieReading {
    private let chromeRoot: URL

    public init(chromeRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true))
    {
        self.chromeRoot = chromeRoot
    }

    public func readCookies() throws -> [ChromeCookieRecord] {
        let profileURLs = (try? FileManager.default.contentsOfDirectory(
            at: chromeRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            url.lastPathComponent == "Default" || url.lastPathComponent.hasPrefix("Profile ")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        var records: [ChromeCookieRecord] = []
        for profile in profileURLs {
            for relativePath in ["Network/Cookies", "Cookies"] {
                let databaseURL = profile.appendingPathComponent(relativePath)
                guard FileManager.default.fileExists(atPath: databaseURL.path) else { continue }
                records.append(contentsOf: Self.readDatabase(databaseURL))
                break
            }
        }
        return records
    }

    private static func readDatabase(_ url: URL) -> [ChromeCookieRecord] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else { return [] }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT name, encrypted_value FROM cookies
        WHERE host_key = 'opencode.ai' AND name IN ('auth', '__Host-auth')
        ORDER BY CASE name WHEN '__Host-auth' THEN 0 ELSE 1 END
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        var records: [ChromeCookieRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameBytes = sqlite3_column_text(statement, 0),
                  let blob = sqlite3_column_blob(statement, 1)
            else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            records.append(ChromeCookieRecord(
                name: String(cString: nameBytes),
                encryptedValue: Data(bytes: blob, count: count)
            ))
        }
        return records
    }
}

public struct ChromeSafeStorageReader: ChromeSafeStorageReading {
    public init() {}

    public func readPassword(mode: CredentialAccessMode) throws -> Data? {
        _ = chromeLegacyKeychainInteraction.setUserInteractionAllowed(mode == .interactive)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if mode == .background {
            query[kSecUseAuthenticationUI as String] = chromeLegacyKeychainInteraction.authenticationUIFail
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            return nil
        }
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }
}

private protocol ChromeLegacyKeychainInteraction: Sendable {
    func setUserInteractionAllowed(_ allowed: Bool) -> OSStatus
    var authenticationUIFail: CFString { get }
}

private struct SystemChromeLegacyKeychainInteraction: ChromeLegacyKeychainInteraction {
    @available(macOS, deprecated: 10.10)
    func setUserInteractionAllowed(_ allowed: Bool) -> OSStatus {
        SecKeychainSetUserInteractionAllowed(allowed)
    }

    @available(macOS, deprecated: 11.0)
    var authenticationUIFail: CFString { kSecUseAuthenticationUIFail }
}

private let chromeLegacyKeychainInteraction: any ChromeLegacyKeychainInteraction =
    SystemChromeLegacyKeychainInteraction()

public enum ChromeCookieDecryptor {
    public static func decrypt(_ encryptedValue: Data, password: Data) -> String? {
        guard encryptedValue.count > 3,
              encryptedValue.prefix(3) == Data("v10".utf8) || encryptedValue.prefix(3) == Data("v11".utf8)
        else { return nil }
        var key = Data(count: kCCKeySizeAES128)
        let derivationStatus = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                "saltysalt".withCString { salt in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        salt,
                        9,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        kCCKeySizeAES128
                    )
                }
            }
        }
        guard derivationStatus == kCCSuccess else { return nil }

        let ciphertext = encryptedValue.dropFirst(3)
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let plaintextCapacity = plaintext.count
        var outputLength = 0
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let cryptStatus = plaintext.withUnsafeMutableBytes { output in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            input.baseAddress,
                            ciphertext.count,
                            output.baseAddress,
                            plaintextCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard cryptStatus == kCCSuccess else { return nil }
        plaintext.count = outputLength

        let hostDigest = Data(SHA256.hash(data: Data("opencode.ai".utf8)))
        if plaintext.starts(with: hostDigest) {
            plaintext.removeFirst(hostDigest.count)
        }
        return String(data: plaintext, encoding: .utf8)
    }
}

public struct OpenCodeGoPageResponse: Sendable, Equatable {
    public let data: Data
    public let receivedAt: Date

    public init(data: Data, receivedAt: Date) {
        self.data = data
        self.receivedAt = receivedAt
    }
}

public enum OpenCodeGoTransportError: Error, Equatable, Sendable {
    case sessionExpired
    case network
    case parseFailure
}

public protocol OpenCodeGoTransporting: Sendable {
    func discoverWorkspaceIDs(session: OpenCodeSession) async throws -> [String]
    func fetchUsagePage(workspaceID: String, session: OpenCodeSession) async throws -> OpenCodeGoPageResponse
}

public struct OpenCodeGoWorkspaceParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageParsingError.parseFailure
        }
        let regex = try NSRegularExpression(pattern: #"\bid\s*:\s*\"(wrk_[A-Za-z0-9]+)\""#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen: Set<String> = []
        let ids = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
            let id = String(text[matchRange])
            return seen.insert(id).inserted ? id : nil
        }
        guard !ids.isEmpty else { throw UsageParsingError.parseFailure }
        return ids
    }
}

public final class OpenCodeGoHTTPTransport: OpenCodeGoTransporting, @unchecked Sendable {
    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private let session: URLSession
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private let workspaceParser = OpenCodeGoWorkspaceParser()

    public init(timeout: TimeInterval = 15, now: @escaping @Sendable () -> Date = Date.init) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(
            configuration: configuration,
            delegate: OpenCodeRedirectGuard(),
            delegateQueue: nil
        )
        self.timeout = max(1, timeout)
        self.now = now
    }

    public static func isAllowedRequestURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "opencode.ai"
    }

    public func discoverWorkspaceIDs(session openCodeSession: OpenCodeSession) async throws -> [String] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("_server"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: Self.workspacesServerID)]
        guard let url = components.url else { throw OpenCodeGoTransportError.network }
        var request = try request(url: url, openCodeSession: openCodeSession)
        request.setValue(Self.workspacesServerID, forHTTPHeaderField: "X-Server-Id")
        request.setValue("ai-usage-bar-\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(Self.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(Self.baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        let response = try await perform(request)
        do {
            return try workspaceParser.parse(response.data)
        } catch {
            throw OpenCodeGoTransportError.parseFailure
        }
    }

    public func fetchUsagePage(
        workspaceID: String,
        session openCodeSession: OpenCodeSession
    ) async throws -> OpenCodeGoPageResponse {
        guard let normalized = OpenCodeGoWorkspace.normalizedID(from: workspaceID),
              let url = URL(string: "https://opencode.ai/workspace/\(normalized)/go")
        else { throw OpenCodeGoTransportError.network }
        var request = try request(url: url, openCodeSession: openCodeSession)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private func request(url: URL, openCodeSession: OpenCodeSession) throws -> URLRequest {
        guard Self.isAllowedRequestURL(url), Self.isAllowedCookie(openCodeSession.authenticationCookie) else {
            throw OpenCodeGoTransportError.sessionExpired
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(openCodeSession.authenticationCookie, forHTTPHeaderField: "Cookie")
        request.setValue("AIUsageBar/\(UsageCore.version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> OpenCodeGoPageResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OpenCodeGoTransportError.network }
            let text = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 || http.statusCode == 403 ||
                (300..<400).contains(http.statusCode) || Self.looksSignedOut(text)
            {
                throw OpenCodeGoTransportError.sessionExpired
            }
            guard http.statusCode == 200 else { throw OpenCodeGoTransportError.network }
            return OpenCodeGoPageResponse(data: data, receivedAt: now())
        } catch let error as OpenCodeGoTransportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenCodeGoTransportError.network
        }
    }

    static func isAllowedCookie(_ cookie: String) -> Bool {
        cookie.range(
            of: #"^(?:auth|__Host-auth)=[^;\r\n]+$"#,
            options: .regularExpression
        ) != nil
    }

    static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("/auth/authorize") || lower.contains(">sign in<") ||
            lower.contains("actor of type \"public\"")
    }
}

extension OpenCodeGoHTTPTransport {
    static func isAllowedRedirect(from source: URL, to destination: URL) -> Bool {
        isAllowedRequestURL(source) && isAllowedRequestURL(destination) &&
            source.host?.caseInsensitiveCompare(destination.host ?? "") == .orderedSame
    }
}

private final class OpenCodeRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let source = task.originalRequest?.url,
              let destination = request.url,
              OpenCodeGoHTTPTransport.isAllowedRedirect(from: source, to: destination)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public struct OpenCodeGoProvider: UsageProvider {
    private let sessionReader: any OpenCodeSessionReading
    private let transport: any OpenCodeGoTransporting
    private let workspaceOverride: @Sendable () -> String?
    private let parser: OpenCodeGoUsageParser
    private let maximumConcurrentWorkspaceRequests: Int

    public init(
        sessionReader: any OpenCodeSessionReading,
        transport: any OpenCodeGoTransporting,
        workspaceOverride: @escaping @Sendable () -> String?,
        parser: OpenCodeGoUsageParser = OpenCodeGoUsageParser(),
        maximumConcurrentWorkspaceRequests: Int = 4
    ) {
        self.sessionReader = sessionReader
        self.transport = transport
        self.workspaceOverride = workspaceOverride
        self.parser = parser
        self.maximumConcurrentWorkspaceRequests = max(1, maximumConcurrentWorkspaceRequests)
    }

    public func fetch(previous: ProviderUsage?, mode: CredentialAccessMode) async -> ProviderState {
        let session: OpenCodeSession
        do {
            guard let readSession = try sessionReader.readSession(mode: mode) else {
                return .stale(last: previous, reason: .credentialUnavailable)
            }
            session = readSession
        } catch {
            return .stale(last: previous, reason: .credentialUnavailable)
        }

        do {
            if let workspaceID = OpenCodeGoWorkspace.normalizedID(from: workspaceOverride()) {
                let response = try await transport.fetchUsagePage(workspaceID: workspaceID, session: session)
                let usage = try parser.parse(response.data, now: response.receivedAt)
                return .fresh(usage, asOf: response.receivedAt)
            }

            let discovered = try await transport.discoverWorkspaceIDs(session: session)
            let workspaceIDs = Array(Set(discovered.compactMap {
                OpenCodeGoWorkspace.normalizedID(from: $0)
            })).sorted()
            let candidates = await qualifyingCandidates(workspaceIDs: workspaceIDs, session: session)
            if candidates.sessionExpired, candidates.usages.isEmpty {
                return .stale(last: previous, reason: .sessionExpired)
            }
            guard candidates.usages.count == 1 else {
                return .stale(
                    last: previous,
                    reason: candidates.usages.isEmpty ? .credentialUnavailable : .workspaceSelectionRequired
                )
            }
            let selected = candidates.usages[0]
            return .fresh(selected.usage, asOf: selected.asOf)
        } catch OpenCodeGoTransportError.sessionExpired {
            return .stale(last: previous, reason: .sessionExpired)
        } catch OpenCodeGoTransportError.parseFailure, UsageParsingError.parseFailure {
            return .stale(last: previous, reason: .parseFailure)
        } catch {
            return .stale(last: previous, reason: .networkError)
        }
    }

    private struct Candidate: Sendable {
        let usage: ProviderUsage
        let asOf: Date
    }

    private enum CandidateResult: Sendable {
        case usage(Candidate)
        case sessionExpired
        case rejected
    }

    private func qualifyingCandidates(
        workspaceIDs: [String],
        session: OpenCodeSession
    ) async -> (usages: [Candidate], sessionExpired: Bool) {
        guard !workspaceIDs.isEmpty else { return ([], false) }
        let transport = self.transport
        let parser = self.parser
        let limit = maximumConcurrentWorkspaceRequests

        return await withTaskGroup(of: CandidateResult.self) { group in
            var iterator = workspaceIDs.makeIterator()
            for _ in 0..<min(limit, workspaceIDs.count) {
                if let workspaceID = iterator.next() {
                    group.addTask { await Self.fetchCandidate(
                        workspaceID: workspaceID,
                        session: session,
                        transport: transport,
                        parser: parser
                    ) }
                }
            }

            var usages: [Candidate] = []
            var sawSessionExpired = false
            while let result = await group.next() {
                switch result {
                case let .usage(candidate): usages.append(candidate)
                case .sessionExpired: sawSessionExpired = true
                case .rejected: break
                }
                if let workspaceID = iterator.next() {
                    group.addTask { await Self.fetchCandidate(
                        workspaceID: workspaceID,
                        session: session,
                        transport: transport,
                        parser: parser
                    ) }
                }
            }
            return (usages, sawSessionExpired)
        }
    }

    private static func fetchCandidate(
        workspaceID: String,
        session: OpenCodeSession,
        transport: any OpenCodeGoTransporting,
        parser: OpenCodeGoUsageParser
    ) async -> CandidateResult {
        do {
            try Task.checkCancellation()
            let response = try await transport.fetchUsagePage(workspaceID: workspaceID, session: session)
            let usage = try parser.parse(response.data, now: response.receivedAt)
            return .usage(Candidate(usage: usage, asOf: response.receivedAt))
        } catch OpenCodeGoTransportError.sessionExpired {
            return .sessionExpired
        } catch {
            return .rejected
        }
    }
}
