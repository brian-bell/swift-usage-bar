# Slice 2 — Parser + credential reader + provider (fixture-backed)

Drill-down of `docs/PLAN-minimax-slices.md` Slice 2. Slice 1 added the
provider shape without a live implementation; this slice adds the parser,
credential reader, and a fixture-backed provider so the read pipeline is
complete end-to-end without a real HTTP transport. Slice 3 wires the real
transport and surfaces the dropdown / status / notifications UI.

## Goal

- A new `Sources/UsageCore/MiniMax.swift` (one file per provider
  subsystem, matching `OpenCodeGo.swift` and `CodexAppServer.swift`)
  containing:
   - `MiniMaxTokenPlanParser` for the live API response shape (and the
     sanitized fixture), mapping percent-remaining + epoch-ms reset into
     `ProviderUsage`. Throws a typed `AuthFailure.rejectedKey` for a
     rejected-key body (`base_resp.status_code == 1004`) so the provider
     can route it to `.tokenExpired`; every other failure is
     `UsageParsingError.parseFailure`.
  - `MiniMaxCredentialReading` protocol + `OpenCodeAuthFileCredentialReader`
    implementation that reads the `minimax-coding-plan` key from
    `${XDG_DATA_HOME:-~/.local/share}/opencode/auth.json` (empty var
    counts as unset, matching `CLAUDE_CONFIG_DIR`) and returns either
    a `MiniMaxCredential` or a `.credentialUnavailable` verdict. Accepts
    `mode` but ignores it (file reads can't prompt). Strictly read-only
    — no write API surface at all (test posture enforced).
  - `MiniMaxTransporting` protocol + `MiniMaxUsageProvider` implementing
    `UsageProvider` with `fetchReport` as the real entry point and
    `fetch` expressed through it (parity with the three existing
    providers). The provider is exercised end-to-end via a fake
    transport + fake credential reader; the real transport lands in
    Slice 3.
- New fixtures `Tests/Fixtures/minimax-token-plan.json` (sanitized live
  capture, both `general` and `video` entries — proves `video` is
  ignored) and `Tests/Fixtures/minimax-token-plan-auth-failure.json`
  (HTTP 200 with `base_resp.status_code == 1004`).
- A MiniMax section appended to `docs/endpoints.md` recording the
  endpoint contract + evidence.

## Non-goals (deferred)

- No real HTTP transport — Slice 3 implements `MiniMaxTransporting` on
  top of the shared `HTTPTransport`.
- No `UsageBarShellModel.live()` wiring — Slice 3.
- No dropdown / status copy changes — Slice 3. The unreachable-stub
  copy added in Slice 1 stays.
- No threshold notifier test for a MiniMax window — Slice 3.
- No settings-staging test for MiniMax — Slice 3.
- No four-visible-providers menu-bar formatter test — Slice 3.
- No bundle / manual smoke — Slice 4.

---

## File-by-file change list

### 1. `Sources/UsageCore/MiniMax.swift` (new file)

Sections, in the order the file uses them.

#### 1a. Credential value type + read result (top of file)

```swift
public struct MiniMaxCredential: Sendable, Equatable {
    public let key: String
    public init(key: String) { self.key = key }
}

public enum MiniMaxCredentialReadResult: Equatable, Sendable {
    case fresh(MiniMaxCredential)
    case stale(reason: StaleReason)
}
```

The credential struct never appears in `ProviderFetchReport`,
`ProviderDataSource`, or any UI label — it is consumed inside the
provider's `fetchReport` and never escapes.

#### 1b. Credential reading protocol

```swift
public protocol MiniMaxCredentialReading: Sendable {
    func read(mode: CredentialAccessMode) throws -> MiniMaxCredentialReadResult
}

public extension MiniMaxCredentialReading {
    func read() throws -> MiniMaxCredentialReadResult {
        try read(mode: .background)
    }
}
```

`mode` is accepted for parity with `CodexCredentialReading` /
`ClaudeCredentialReading` but ignored — file reads cannot prompt.

#### 1c. `OpenCodeAuthFileCredentialReader`

```swift
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
        } catch CocoaError.fileReadNoSuchFile {
            return .stale(reason: .credentialUnavailable)
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
```

Notes:

- The entry's `type` field is OpenCode's bookkeeping; it is
  intentionally **not** consulted. `type != "api"` still uses the key
  (per `docs/PLAN-minimax.md` "Credential source" + the slice doc's
  acceptance criteria). A test pins this.
- `MiniMaxCredential.key` is the only field. No expiry check is
  possible (the key is opaque `sk-…`, no JWT segments), so the only
  credential-side failure mode is `.credentialUnavailable`.
- The reader is a struct with exactly one public method (`read(mode:)`)
  inherited from the protocol. There is no public write API. A test
  pins the protocol surface is *exactly* `read(mode:)` — same posture
  `credentialStoreProtocolRequiresOnlyReadAccess` uses for
  `CredentialStore` in `Tests/UsageCoreTests/CredentialStoreTests.swift`.

#### 1d. Transport response shape + parser error type

```swift
public struct MiniMaxTokenPlanResponse: Sendable, Equatable {
    public let data: Data
    public let receivedAt: Date

    public init(data: Data, receivedAt: Date) {
        self.data = data
        self.receivedAt = receivedAt
    }
}
```

The parser is dumb about why a parse failed; a 1004 auth body is
detected *during* parsing and surfaced by the provider via the typed
error:

```swift
extension MiniMaxTokenPlanParser {
    /// The API rejected the subscription key (`base_resp.status_code == 1004`).
    public enum AuthFailure: Error, Equatable, Sendable {
        case rejectedKey
    }
}
```

#### 1e. `MiniMaxTokenPlanParser`

```swift
public struct MiniMaxTokenPlanParser: Sendable {
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
```

`FailableDecodable` is `private` to `UsageCore.swift`, so we mirror it
locally — same `Decodable`-lossy pattern as Claude's
`FailableDecodable<ClaudeUsageLimit>`. The parser uses
`compactMap(\.value)` inline; the helper types are `private`.

The `Response.init(from:)` is the only place the decoder is allowed
to throw: it catches the sibling-entry decode failure and converts it
to an empty array, so the outer `JSONDecoder().decode(Response.self,
...)` call sees a successful decode and the 1004 check + general-entry
lookup proceed normally.

#### 1f. `MiniMaxTransporting` protocol

```swift
public protocol MiniMaxTransporting: Sendable {
    func fetchTokenPlan(credential: MiniMaxCredential) async throws -> MiniMaxTokenPlanResponse
}
```

The provider depends only on this seam. Slice 3 implements it on top
of the shared `HTTPTransport` (no User-Agent games, no cookies, no
redirect concerns beyond the transport's defaults — this is a plain
API-key endpoint, not Cloudflare-fronted claude.ai). Slice 2 only
tests against a fake.

#### 1g. `MiniMaxUsageProvider`

```swift
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
```

The chain has exactly one step, so the step's failure reason *equals*
the surfaced `StaleReason`. The test for this invariant
(`miniMaxProviderChainStepFailureEqualsSurfacedReason`) pins it
explicitly against the surfaced reason — the AGENTS.md invariant for
multi-step providers doesn't apply here, but pinning the single-step
tautology is the test the slice doc specifically asks for.

The provider never throws upward and preserves last-known usage on
every failure path (parity with Claude, Codex, OpenCode Go).

---

## Test additions

### 2. `Tests/Fixtures/minimax-token-plan.json` (new)

Sanitized live capture (the original capture had both `general` and
`video` entries; the parser test asserts `video` is ignored). Real
percent values (`100` and `99` from the live capture) are kept. The
fixture is committed pretty-printed, exactly like
`Tests/Fixtures/claude-usage.json` and `Tests/Fixtures/codex-usage.json`.

The key is not in this fixture — it lives in `auth.json`, which the
credential reader test creates per-test in a temp directory.

### 3. `Tests/Fixtures/minimax-token-plan-auth-failure.json` (new)

```json
{
  "model_remains": [],
  "base_resp": { "status_code": 1004, "status_msg": "login fail" }
}
```

`model_remains` is intentionally empty: the parser must short-circuit
on `base_resp` *before* looking for a `general` entry.

### 4. `Tests/UsageCoreTests/MiniMaxTokenPlanParserTests.swift` (new)

Fixture-loading helper and `epochSeconds` mirror the
`ClaudeUsageParserTests.swift` style.

| Test | Pins |
|---|---|
| `miniMaxParserParsesSanitizedFixture` | Happy path from fixture: `100`/`99` percent; `end_time: 1786046400000` → epoch seconds `1_786_046_400`. |
| `miniMaxParserIgnoresVideoEntryAndSelectsGeneral` | `[general, video]` decodes; `general` wins (`video` ignored). |
| `miniMaxParserThrowsAuthFailureOn1004` | `status_code == 1004` → `AuthFailure.rejectedKey`; the provider test maps that to `.tokenExpired`. |
| `miniMaxParserFailsOnOtherNonZeroStatusCode` | `status_code == 7` → `parseFailure`. |
| `miniMaxParserConvertsEpochMillisecondsToResetsAt` | `1_786_046_400_000` ms → `1_786_046_400` seconds (proves the `/ 1000` conversion). |
| `miniMaxParserToleratesMalformedSiblingEntries` | `[validGeneral, badVideo]` decodes; the bad entry drops to `nil`, `general` wins. |
| `miniMaxParserRejectsPercentOutOfRange` | `150`, `-5`, `Double.nan`, `Double.infinity` → `parseFailure`. |
| `miniMaxParserAcceptsUnknownResetWithValidPercent` | `end_time: null`, valid percent → percent kept, `resetsAt == nil` (Fable rule, no speculation). |
| `miniMaxParserFailsOnMissingGeneralEntry` | `[video]` only or empty `model_remains` → `parseFailure`. |
| `miniMaxParserFailsOnUndecodableBody` | `not json`, `{}` → `parseFailure`. |
| `miniMaxParserFailsOnMissingPercentFields` | `general` entry with missing `current_interval_remaining_percent` → `parseFailure` (no null-window speculation — there is no evidenced "window lapses to null" behavior for MiniMax, unlike Claude). |

### 5. `Tests/UsageCoreTests/OpenCodeAuthFileCredentialReaderTests.swift` (new)

Pattern mirrors `Tests/UsageCoreTests/CredentialsFileStoreTests.swift`
(temp directory + injected `fileURL`).

| Test | Pins |
|---|---|
| `openCodeAuthFileReaderReturnsKeyFromPresentFile` | `{ "<entryKey>": { "key": "sk-test" } }` → `.fresh(MiniMaxCredential(key: "sk-test"))`. |
| `openCodeAuthFileReaderIsCredentialUnavailableWhenFileIsAbsent` | Empty directory → `.stale(reason: .credentialUnavailable)`. |
| `openCodeAuthFileReaderIsCredentialUnavailableWhenJSONIsMalformed` | `not json` → `.stale(reason: .credentialUnavailable)`. |
| `openCodeAuthFileReaderIsCredentialUnavailableWhenEntryMissing` | `{}` → `.stale(reason: .credentialUnavailable)`. |
| `openCodeAuthFileReaderIsCredentialUnavailableWhenKeyIsEmpty` | `{ "<entryKey>": { "key": "" } }` → `.stale(reason: .credentialUnavailable)`. |
| `openCodeAuthFileReaderIgnoresNonAPITypes` | `{ "<entryKey>": { "type": "oauth", "key": "sk-test" } }` → key still used (proves `type` is intentionally ignored). |
| `openCodeAuthFileReaderDefaultsHonorXDGDataHome` | `XDG_DATA_HOME=<temp>` + `auth.json` at `<temp>/opencode/auth.json` → key returned. |
| `openCodeAuthFileReaderDefaultsFallBackToHome` | No env → resolves to `~/.local/share/opencode/auth.json`; uses an injected home with the file present. |
| `openCodeAuthFileReaderDefaultsTreatEmptyXDGDataHomeAsUnset` | `XDG_DATA_HOME=""` → falls back to home (`CLAUDE_CONFIG_DIR` rule). |
| `openCodeAuthFileReaderAcceptsButIgnoresMode` | `.background` and `.interactive` both succeed when the file is present; neither reads the file twice (the impl ignores mode). |
| `miniMaxCredentialReadingProtocolExposesOnlyRead` | A struct conforming to `MiniMaxCredentialReading` with only a `read(mode:)` implementation satisfies the protocol — no other method is required. Mirrors `credentialStoreProtocolRequiresOnlyReadAccess`. |

### 6. `Tests/UsageCoreTests/MiniMaxUsageProviderTests.swift` (new)

A fake transport (actor or struct with a captured request) and a fake
credential reader mirror `RecordingOpenCodeSessionReader` /
`StubOpenCodeGoTransport` from `OpenCodeGoProviderTests.swift`.

| Test | Pins |
|---|---|
| `miniMaxProviderReturnsFreshUsageOnSuccess` | Fake reader returns `.fresh(credential)`; fake transport serves the sanitized fixture → `.fresh(usage)` with `asOf` from the transport; chain `[.used]`. |
| `miniMaxProviderIsStaleCredentialUnavailableWhenReaderReturnsAbsent` | Reader → `.stale(reason: .credentialUnavailable)` → provider surfaces `.credentialUnavailable`, preserves `previous`. |
| `miniMaxProviderIsStaleCredentialUnavailableWhenReaderThrows` | Reader throws → same mapping (transport never called). |
| `miniMaxProviderIsStaleTokenExpiredOn1004` | Transport serves the auth-failure fixture → parser throws `AuthFailure.rejectedKey` → provider surfaces `.tokenExpired`. |
| `miniMaxProviderIsStaleParseFailureOnMalformedBody` | Transport serves `not json` → `.parseFailure`. |
| `miniMaxProviderIsStaleNetworkErrorOnTransportError` | Transport throws → `.networkError`. |
| `miniMaxProviderPreservesLastKnownUsageOnEveryStaleMapping` | Repeat the stale cases with `previous != nil` and assert the surfaced `last:` is `previous`. |
| `miniMaxProviderReportsSingleStepUsedOnSuccess` | `fetchReport(...).chain` has exactly one step, `.used`; `source == .minimaxTokenPlanAPI`. |
| `miniMaxProviderReportsSingleStepFailedOnEveryStaleMapping` | Each stale path produces a single step with `.failed(<reason>)`. |
| `miniMaxProviderChainStepFailureEqualsSurfacedReason` | Pins the *invariant* (not just the per-step outcomes): for a one-step chain, the step's `failed` reason and the surfaced `StaleReason` are equal. (Test posture matches the AGENTS.md description — the slice doc specifically asks for this test.) |

### 7. `docs/endpoints.md` — append a MiniMax section

After the OpenCode Go section:

```markdown
## MiniMax (coding/token plan)

- Auth source: read-only access to `${XDG_DATA_HOME:-~/.local/share}/opencode/auth.json`, key `minimax-coding-plan`, field `key` (a 125-char opaque `sk-…` token; no JWT segments, so no local expiry pre-check is possible). The reader ignores the entry's `type` field (OpenCode bookkeeping) and only requires a non-empty `key`. The file is read once per fetch; never written, never logged.
- Endpoint: `GET https://api.minimax.io/v1/token_plan/remains` with `Authorization: Bearer <key>` and `Content-Type: application/json`. The `www.minimax.io` host serves the same payload; the app uses `api.minimax.io`. China-region hosts (`api.minimaxi.com`) are deliberately unsupported.
- Auth-failure semantics: HTTP 200 + `base_resp.status_code == 1004` (login fail) means the key was rejected → maps to `.tokenExpired`. HTTP status alone cannot distinguish success from auth failure — the body must be inspected.
- Response shape (sanitized fixture: `Tests/Fixtures/minimax-token-plan.json`):
  `model_remains` is an array keyed by `model_name`. The coding/token plan is the `"general"` entry (its 5h interval is exactly 18,000,000 ms; its weekly window is exactly 7 days). The `"video"` entry is a separate daily video quota and is ignored.
  Each `general` entry's `current_interval_remaining_percent` / `current_weekly_remaining_percent` are **percent remaining**, used directly. `end_time` (ms) → fiveHour reset; `weekly_end_time` (ms) → weekly reset.
- Approved narrow exception: AIUsageBar never refreshes the key — a machine whose OpenCode session is gone degrades to `.tokenExpired` by design.

### Rejected alternatives

- `https://api.minimax.io/v1/api/openplatform/coding_plan/remains` — requires a browser cookie session (returns 1004 with an API key per MiniMax-AI/MiniMax-M2#88). Not used.
- China-region hosts (`api.minimaxi.com`) — no evidence, no user. Not used.
- Reading the key from env vars, `~/.claude/settings.json`, the macOS Keychain, or browser cookies — no evidence supports a single source beyond `~/.local/share/opencode/auth.json`.
```

---

## Order of operations (TDD-friendly)

Each step ends with `swift build` (and where marked,
`scripts/run-swift-tests`) green. Commit after each step.

1. **Fixtures** — add `Tests/Fixtures/minimax-token-plan.json` and
   `Tests/Fixtures/minimax-token-plan-auth-failure.json`. No code
   change. `git add` only.
2. **Parser** — add `MiniMaxTokenPlanResponse`, `AuthFailure`,
   `MiniMaxTokenPlanParser`, and the local `FailableDecodable` mirror
   to `Sources/UsageCore/MiniMax.swift`. Write
   `Tests/UsageCoreTests/MiniMaxTokenPlanParserTests.swift` red-first
   (compile error → tests fail → implementation makes them pass).
   Build green.
3. **Credential reader** — add `MiniMaxCredential`,
   `MiniMaxCredentialReadResult`, `MiniMaxCredentialReading`, and
   `OpenCodeAuthFileCredentialReader` to
   `Sources/UsageCore/MiniMax.swift`. Write
   `Tests/UsageCoreTests/OpenCodeAuthFileCredentialReaderTests.swift`
   (red-first, including the no-write-API test). Build green.
4. **Transport seam + provider** — add `MiniMaxTransporting` and
   `MiniMaxUsageProvider` to `Sources/UsageCore/MiniMax.swift`. Write
   `Tests/UsageCoreTests/MiniMaxUsageProviderTests.swift` red-first.
   Build green.
5. **Endpoint doc** — append the MiniMax section to `docs/endpoints.md`.
   No code change.

Final verification: `scripts/run-swift-tests` passes.

---

## Verification checklist (mirrors slice acceptance criteria)

- [ ] `swift build` clean under Swift 6 strict concurrency.
- [ ] `scripts/run-swift-tests` executes and passes (full suite, not
      just builds — see `AGENTS.md` "Test-execution note").
- [ ] `Tests/UsageCoreTests/MiniMaxTokenPlanParserTests.swift` covers
      happy path, video-only failure, 1004 → auth failure, epoch-ms
      conversion, malformed sibling tolerance, percent out-of-range
      rejection, unknown reset, missing `general` entry, undecodable
      body, missing percent fields.
- [ ] `Tests/UsageCoreTests/OpenCodeAuthFileCredentialReaderTests.swift`
      covers present, absent, malformed JSON, entry missing, empty key,
      non-`api` `type` still uses the key, `XDG_DATA_HOME` honored with
      empty-as-unset, `mode` accepted-and-ignored.
- [ ] No write API on the credential reader (test posture enforced).
- [ ] `Tests/UsageCoreTests/MiniMaxUsageProviderTests.swift` covers
      fresh path, each stale mapping, previous-usage preservation,
      single-step chain contents, and the
      step-failure-equals-surfaced-reason invariant pinned explicitly.
- [ ] Fixtures are sanitized; no real key in version control.
- [ ] `git grep -nE "case \.claude|case \.codex|case \.openCodeGo"` shows
      no newly flagged switches — Slice 1 already handled every one.
- [ ] `UsageBarShellModel.liveProviders` returns no entry for `.miniMax`
      (verify with `git diff` — should be empty).
- [ ] No new package dependency, no script edit, no `docs/endpoints.md`
      change beyond the new section.

---

## Risks and follow-ups

- **`FailableDecodable` visibility.** `FailableDecodable` in
  `UsageCore.swift` is `private` to that file, so we mirror it locally
  in `MiniMax.swift` with the same lossy-`Decodable` pattern. This is
  the same approach the Claude precedent takes (it works because
  `ClaudeUsageResponse` and `FailableDecodable` live in the same file).
- **Percent granularity.** The API returns integer percent. The parser
  rounds via `Int(... .rounded())` for symmetry with the Claude
  statusline parser, but the live capture's `100`/`99` is already
  integer. Slice 4's manual smoke confirms a partially consumed window
  reports a changing integer (the capture was taken nearly idle).
- **1004 routing.** The parser throws `AuthFailure.rejectedKey` for
  `status_code == 1004`; the provider's `catch …AuthFailure.rejectedKey`
  arm routes it to `.tokenExpired`. Other non-zero status codes stay
  `.parseFailure` until evidence shows another auth-shaped code.
- **Endpoint doc drift.** Slice 3's real transport + shell wiring
  re-reads this section; if Slice 3 needs to add anything (User-Agent,
  retry policy), it lands there, not here.
- **`MiniMaxCredential` field set.** Only `key` today; if a future
  slice needs more (e.g. an explicit `expiresAt` from a new endpoint
  shape), this is the type to grow. Slice 2 keeps it minimal.
- **Slice 3 dependencies.** Nothing in Slice 3 depends on internal
  symbols added here except `MiniMaxUsageProvider.init` (Slice 3 will
  construct it with the real transport). The provider is otherwise
  opaque from `UsageBarShellModel.live()`'s perspective.
