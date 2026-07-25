import Foundation

// MARK: - Session

/// A read-only claude.ai browser session borrowed from Chrome's cookie store.
///
/// Carries the assembled `Cookie` header (never persisted or logged) plus the
/// organization hint decoded from the `lastActiveOrg` cookie, which lets the
/// transport skip discovery on the common path.
public struct ClaudeWebSession: Sendable, Equatable {
    public let cookieHeader: String
    public let organizationHint: String?

    public init(cookieHeader: String, organizationHint: String?) {
        self.cookieHeader = cookieHeader
        self.organizationHint = organizationHint
    }
}

public protocol ClaudeWebSessionReading: Sendable {
    func readSession(mode: CredentialAccessMode) throws -> ClaudeWebSession?
}

/// Optional richer interface for sources that can offer more than one coherent
/// browser session (for example, separate Chrome profiles).
public protocol ClaudeWebSessionCandidateReading: ClaudeWebSessionReading {
    func readSessions(mode: CredentialAccessMode) throws -> [ClaudeWebSession]
}

public protocol ChromeClaudeWebCookieReading: Sendable {
    func readCookies() throws -> [ChromeCookieRecord]
}

extension ChromeCookieDatabaseReader: ChromeClaudeWebCookieReading {}

/// Optional richer interface for cookie stores that retain profile boundaries.
public protocol ChromeClaudeWebCookieProfileReading: ChromeClaudeWebCookieReading {
    func readCookieProfiles() throws -> [[ChromeCookieRecord]]
}

extension ChromeCookieDatabaseReader: ChromeClaudeWebCookieProfileReading {}

/// Reads the read-only claude.ai session cookies from Chrome. Requires a
/// decryptable `sessionKey`; opportunistically forwards `lastActiveOrg`,
/// `cf_clearance`, and `__cf_bm` so requests survive Cloudflare's bot check.
/// Safe Storage is only consulted when a `sessionKey` cookie exists, so a
/// machine that never signed into claude.ai in Chrome never prompts.
public struct ChromeClaudeWebSessionReader: ClaudeWebSessionCandidateReading {
    public typealias Decrypt = @Sendable (Data, Data) -> String?

    /// Emitted in this order so the header is deterministic; `sessionKey` leads.
    public static let cookieNames = ["sessionKey", "lastActiveOrg", "cf_clearance", "__cf_bm"]

    private let cookieReader: any ChromeClaudeWebCookieReading
    private let safeStorageReader: any ChromeSafeStorageReading
    private let decrypt: Decrypt

    public init(
        cookieReader: any ChromeClaudeWebCookieReading = ChromeCookieDatabaseReader(
            host: "claude.ai",
            cookieNames: ChromeClaudeWebSessionReader.cookieNames
        ),
        safeStorageReader: any ChromeSafeStorageReading = ChromeSafeStorageReader(),
        decrypt: @escaping Decrypt = { encrypted, password in
            ChromeCookieDecryptor.decrypt(
                encrypted,
                password: password,
                hostCandidates: [".claude.ai", "claude.ai"]
            )
        }
    ) {
        self.cookieReader = cookieReader
        self.safeStorageReader = safeStorageReader
        self.decrypt = decrypt
    }

    public func readSession(mode: CredentialAccessMode) throws -> ClaudeWebSession? {
        try readSessions(mode: mode).first
    }

    public func readSessions(mode: CredentialAccessMode) throws -> [ClaudeWebSession] {
        let profiles: [[ChromeCookieRecord]]
        if let profileReader = cookieReader as? any ChromeClaudeWebCookieProfileReading {
            profiles = try profileReader.readCookieProfiles()
        } else {
            profiles = [try cookieReader.readCookies()]
        }

        guard profiles.contains(where: { $0.contains(where: { $0.name == "sessionKey" }) }),
              let password = try safeStorageReader.readPassword(mode: mode)
        else { return [] }

        return profiles.compactMap { profile in
            session(from: profile, password: password)
        }
    }

    private func session(from records: [ChromeCookieRecord], password: Data) -> ClaudeWebSession? {
        var decrypted: [String: String] = [:]
        for record in records where Self.cookieNames.contains(record.name) {
            guard let value = decrypt(record.encryptedValue, password),
                  !value.isEmpty,
                  !value.contains(";"), !value.contains("\r"), !value.contains("\n")
            else { continue }
            decrypted[record.name] = value
        }

        guard decrypted["sessionKey"] != nil else { return nil }

        let pairs = Self.cookieNames.compactMap { name in
            decrypted[name].map { "\(name)=\($0)" }
        }
        let organizationHint = decrypted["lastActiveOrg"].flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeWebSession(
            cookieHeader: pairs.joined(separator: "; "),
            organizationHint: organizationHint
        )
    }
}

// MARK: - Transport

public struct ClaudeWebPageResponse: Sendable, Equatable {
    public let data: Data
    public let receivedAt: Date

    public init(data: Data, receivedAt: Date) {
        self.data = data
        self.receivedAt = receivedAt
    }
}

public enum ClaudeWebTransportError: Error, Equatable, Sendable {
    case sessionExpired
    case network
    case parseFailure
    /// A hinted organization returned 404; an internal signal that triggers
    /// bootstrap discovery rather than a user-visible failure.
    case notFound
}

public protocol ClaudeWebTransporting: Sendable {
    func fetchUsage(session: ClaudeWebSession) async throws -> ClaudeWebPageResponse
}

/// Builds a Chrome-shaped User-Agent. Cloudflare binds the `cf_clearance`
/// cookie to the exact UA that solved its challenge, so the value must match
/// the user's installed Chrome build or the borrowed clearance is rejected.
public enum ChromeUserAgent {
    static let fallbackVersion = "150.0.0.0"

    public static func current(
        infoPlistURLs: [URL] = standardInfoPlistURLs()
    ) -> String {
        make(version: infoPlistURLs.lazy.compactMap { installedVersion(infoPlistURL: $0) }.first ?? fallbackVersion)
    }

    static func standardInfoPlistURLs(fileManager: FileManager = .default) -> [URL] {
        let chromeInfoPlist = "Google Chrome.app/Contents/Info.plist"
        return [
            URL(fileURLWithPath: "/Applications").appendingPathComponent(chromeInfoPlist),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(chromeInfoPlist),
        ]
    }

    static func make(version: String) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/\(version) Safari/537.36"
    }

    static func installedVersion(infoPlistURL: URL) -> String? {
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String,
              !version.isEmpty
        else { return nil }
        return version
    }
}

/// Locked-down claude.ai transport. Reuses the borrowed cookie against exactly
/// two endpoints — `/api/organizations/<org>/usage` and `/api/bootstrap` — over
/// an ephemeral session with a browser-shaped User-Agent. Org resolution tries
/// the `lastActiveOrg` hint first (one request on the common path) and only
/// falls back to bootstrap discovery when the hinted org 404s or is absent.
public struct ClaudeWebHTTPTransport: ClaudeWebTransporting {
    private static let host = "claude.ai"
    private let sender: any HTTPTransport
    private let userAgent: String
    private let now: @Sendable () -> Date

    public init(
        sender: any HTTPTransport = ClaudeWebURLSessionSender(),
        userAgent: String = ChromeUserAgent.current(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sender = sender
        self.userAgent = userAgent
        self.now = now
    }

    public func fetchUsage(session: ClaudeWebSession) async throws -> ClaudeWebPageResponse {
        if let hint = Self.normalizedOrganizationID(session.organizationHint) {
            do {
                return try await requestUsage(organizationID: hint, session: session)
            } catch ClaudeWebTransportError.notFound {
                // Hinted org no longer valid; fall through to discovery.
            }
        }
        let organizationID = try await discoverOrganizationID(session: session)
        do {
            return try await requestUsage(organizationID: organizationID, session: session)
        } catch ClaudeWebTransportError.notFound {
            throw ClaudeWebTransportError.parseFailure
        }
    }

    private func discoverOrganizationID(session: ClaudeWebSession) async throws -> String {
        let url = URL(string: "https://\(Self.host)/api/bootstrap")!
        let (data, status, signedOut) = try await perform(url: url, session: session)
        if signedOut { throw ClaudeWebTransportError.sessionExpired }
        guard status == 200 else { throw ClaudeWebTransportError.network }
        guard let organizationID = Self.organizationID(fromBootstrap: data) else {
            throw ClaudeWebTransportError.parseFailure
        }
        return organizationID
    }

    private func requestUsage(
        organizationID: String,
        session: ClaudeWebSession
    ) async throws -> ClaudeWebPageResponse {
        guard let url = URL(string: "https://\(Self.host)/api/organizations/\(organizationID)/usage") else {
            throw ClaudeWebTransportError.network
        }
        let (data, status, signedOut) = try await perform(url: url, session: session)
        if signedOut { throw ClaudeWebTransportError.sessionExpired }
        if status == 404 { throw ClaudeWebTransportError.notFound }
        guard status == 200 else { throw ClaudeWebTransportError.network }
        return ClaudeWebPageResponse(data: data, receivedAt: now())
    }

    /// Returns (body, statusCode, looksSignedOut). Maps auth failures and
    /// redirects to a signed-out signal so callers surface `.sessionExpired`.
    private func perform(
        url: URL,
        session: ClaudeWebSession
    ) async throws -> (Data, Int, Bool) {
        guard Self.isAllowedRequestURL(url) else { throw ClaudeWebTransportError.network }
        do {
            let (data, response) = try await sender.send(request(url: url, session: session))
            let status = response.statusCode
            if status == 401 || status == 403 || (300..<400).contains(status) {
                return (data, status, true)
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            return (data, status, Self.looksSignedOut(text))
        } catch let error as ClaudeWebTransportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClaudeWebTransportError.network
        }
    }

    private func request(url: URL, session: ClaudeWebSession) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://\(Self.host)", forHTTPHeaderField: "Origin")
        request.setValue("https://\(Self.host)/settings/usage", forHTTPHeaderField: "Referer")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        return request
    }

    public static func isAllowedRequestURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == host
    }

    /// Accepts only path-safe organization identifiers (alphanumerics plus
    /// `-`/`_`) so a malformed value can never alter the request path.
    static func normalizedOrganizationID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    static func organizationID(fromBootstrap data: Data) -> String? {
        guard let bootstrap = try? JSONDecoder().decode(ClaudeBootstrapResponse.self, from: data) else {
            return nil
        }
        let memberships = bootstrap.account?.memberships ?? []
        let preferred = memberships.first { membership in
            let capabilities = membership.organization?.capabilities ?? []
            return capabilities.contains("claude_max") || capabilities.contains("chat")
        }
        return normalizedOrganizationID(preferred?.organization?.uuid)
    }

    /// Only meaningful for HTTP 200 bodies: auth failures already arrive as
    /// 3xx/401/403 (handled by status). A signed-out or challenged 200 is an
    /// HTML page, never the usage JSON, so match markers that cannot appear in
    /// that JSON — the Cloudflare interstitial or an HTML login shell.
    static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("just a moment")
            || (lower.contains("<html") && lower.contains("/auth/authorize"))
    }
}

private struct ClaudeBootstrapResponse: Decodable {
    let account: Account?

    struct Account: Decodable {
        let memberships: [Membership]?
    }

    struct Membership: Decodable {
        let organization: Organization?
    }

    struct Organization: Decodable {
        let uuid: String?
        let capabilities: [String]?
    }
}

/// Ephemeral URLSession for claude.ai: no shared cookie jar, no cache, and a
/// redirect guard that refuses any host-changing hop so the borrowed cookie is
/// never replayed off-origin.
public final class ClaudeWebURLSessionSender: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(
            configuration: configuration,
            delegate: ClaudeWebRedirectGuard(),
            delegateQueue: nil
        )
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeWebTransportError.network
        }
        return (data, http)
    }
}

private final class ClaudeWebRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let source = task.originalRequest?.url,
              let destination = request.url,
              ClaudeWebHTTPTransport.isAllowedRequestURL(source),
              ClaudeWebHTTPTransport.isAllowedRequestURL(destination),
              source.host?.caseInsensitiveCompare(destination.host ?? "") == .orderedSame
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
