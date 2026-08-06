# Slice 3 — Real HTTP transport + shell wiring + dropdown + status chain UI + recovery callouts + threshold notifications

Drill-down of `docs/PLAN-minimax-slices.md` Slice 3. Slice 1 added the
provider shape (hidden by default, every `switch` exhaustive). Slice 2 added
the fixture-backed parser, credential reader, `MiniMaxTransporting` seam, and
`MiniMaxUsageProvider` exercised with fakes. This slice makes MiniMax live in
the running app and pins the remaining UI/notification tests so the demo is
"menu bar shows live MiniMax data with full dropdown and status UI".

## Goal

- A real `MiniMaxHTTPTransport: MiniMaxTransporting` that issues
  `GET https://api.minimax.io/v1/token_plan/remains` with
  `Authorization: Bearer <key>` via the shared `HTTPTransport` seam
  (default `URLSessionHTTPTransport`). No User-Agent games, no cookies, no
  custom redirect policy — plain API-key endpoint, not Cloudflare-fronted.
- `UsageBarShellModel.live()` constructs `MiniMaxUsageProvider` with the real
  transport, `OpenCodeAuthFileCredentialReader()` at the default path, and
  adds `.miniMax` to the poller's provider set. No process lifecycle —
  `stop()`/`shutdown()` need nothing new from this provider.
- Remaining UI / notification pins that Slice 1 scaffolding and Slice 2
  provider tests did not fully cover:
  - Dropdown 5h + weekly rows with countdowns for a fresh MiniMax state
    (Slice 1 already pins the shape; this slice pins the countdown values).
  - Status view model: single-step chain rendering for Live and every stale
    reason, recovery callouts for `.tokenExpired` (and re-pin
    `.credentialUnavailable` if wording drifts), auto-expand-when-stale
    includes MiniMax.
  - Menu bar four-visible-providers two-row partition (image layout already
    pinned in Slice 1 — add a `MenuBarTitleFormatter.segments` four-provider
    pin if missing).
  - `ThresholdNotifier` fires for a MiniMax window (proves the generic path
    picks up `ProviderID.miniMax` via `notificationDisplayName`).
  - Settings staged-on preview drops retained MiniMax state/source/chain/
    last-updated (existing `providerStatusViewModel(stagedVisibility:)`
    contract, MiniMax-specific pin).
- `AGENTS.md` / `CLAUDE.md` updated: MiniMax is now wired into `.live()`;
  drop the "fixture-backed only / not in `.live()` yet" wording.
- `swift build` clean under Swift 6 strict concurrency; full suite executes
  via `scripts/run-swift-tests`.

## Non-goals (deferred)

- No bundle / codesign / manual smoke — Slice 4 (`scripts/bundle.sh`,
  relaunch, enable MiniMax, rename `auth.json`, threshold notification by
  hand).
- No China-region hosts, no browser-cookie coding_plan endpoint, no env-var
  key sources, no key refresh — parent-plan non-goals.
- No process-lifecycle hooks on MiniMax (`UsageProviderStopping` /
  `UsageProviderShuttingDown` stay unimplemented; Codex owns those).
- No new Settings field for the MiniMax key — credential is always the
  OpenCode auth.json entry; the disclosure caption already says so.
- No changes to poller interval, threshold default, or notification
  delivery plumbing — generic path only needs a MiniMax evaluate call.
- No parser / credential-reader behavior changes — Slice 2 owns those;
  transport only delivers bytes + `receivedAt`.

## Starting point (what Slice 1 + 2 already shipped)

Do **not** re-implement these. Verify they still hold; only extend where
the acceptance criteria still have a gap.

| Already shipped | Where |
|---|---|
| `ProviderID.miniMax`, symbol `Mx`, two-window display, default-hidden | `UsageCore.swift`, `SettingsStore` |
| `ProviderDataSource.minimaxTokenPlanAPI` + single-step chain | `ProviderDataSource.swift` |
| Recovery callouts + chain caption + status summaries for MiniMax | `ProviderStatusViewModel.swift` |
| Dropdown display name, `showsFiveHourWindow == true`, stale messages | `DropdownViewModel.swift` |
| Parser, credential reader, `MiniMaxTransporting`, fixture-backed provider | `MiniMax.swift` |
| Fixtures + parser/reader/provider tests | `Tests/Fixtures/`, `Tests/UsageCoreTests/MiniMax*` |
| Endpoint contract | `docs/endpoints.md` § MiniMax |
| Dropdown shape test (`dropdownRowsShowTwoWindowsForFreshMiniMax`) | `DropdownViewModelTests.swift` |
| Status recovery for `.credentialUnavailable` | `ProviderStatusViewModelTests.swift` |
| Four-provider image partition | `MenuBarLabelImageTests.menuBarLabelImagePartitionsFourProvidersAcrossTwoRows` |
| Status summary matrix includes MiniMax for every `StaleReason` | `ProviderStatusViewModelTests.swift` |

The **only production code paths still missing** are the real HTTP
transport and the `.live()` wiring. Everything else in this slice is
test coverage + docs.

---

## File-by-file change list

### 1. `Sources/UsageCore/MiniMax.swift` — add `MiniMaxHTTPTransport`

Append after `MiniMaxTransporting` (before `MiniMaxUsageProvider`), matching
how Claude/Codex keep the HTTP adapter next to the provider that consumes it.

```swift
public struct MiniMaxHTTPTransport: MiniMaxTransporting {
    public static let endpoint = URL(string: "https://api.minimax.io/v1/token_plan/remains")!

    private let sender: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        sender: any HTTPTransport = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sender = sender
        self.now = now
    }

    public func fetchTokenPlan(credential: MiniMaxCredential) async throws -> MiniMaxTokenPlanResponse {
        let (data, response) = try await sender.send(Self.request(for: credential))
        // Non-2xx is a transport-level failure. Auth rejection for this
        // endpoint is HTTP 200 + `base_resp.status_code == 1004` (see
        // docs/endpoints.md); the parser owns that mapping. Do not map
        // 401 → `.tokenExpired` here — MiniMax's evidenced auth failure
        // is body-shaped, and reusing Claude/Codex's status-code helper
        // would invent a second auth path without evidence.
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return MiniMaxTokenPlanResponse(data: data, receivedAt: now())
    }

    private static func request(for credential: MiniMaxCredential) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AIUsageBar/\(UsageCore.version)", forHTTPHeaderField: "User-Agent")
        return request
    }
}
```

Design notes (pin these in the transport tests):

1. **Shared `HTTPTransport` only.** Inject `URLSessionHTTPTransport` by
   default so unit tests can pass a recording fake without touching the
   network. Do **not** invent a dedicated `URLSession` the way OpenCode
   Go / Claude web do — those need cookie isolation and redirect guards;
   MiniMax does not.
2. **Headers.** `Authorization: Bearer <key>`, `Content-Type:
   application/json` (matches the parent plan / `docs/endpoints.md`), and
   the same `User-Agent: AIUsageBar/<version>` Claude and Codex already
   send. No `Origin`/`Referer`/`Sec-Fetch-*`, no cookies.
3. **Non-2xx → throw.** The provider's generic `catch` maps any thrown
   error that is not `AuthFailure.rejectedKey` or
   `UsageParsingError.parseFailure` to `.networkError`. Throwing
   `URLError(.badServerResponse)` (or a small dedicated error) is enough;
   do **not** call `staleReason(forHTTPStatusCode:)` from the transport —
   that helper is private to `UsageCore.swift` and is the wrong model for
   MiniMax (401 is not the evidenced auth path).
4. **`receivedAt` from the injected clock**, not from response headers.
   Parity with how the fake transport in Slice 2 tests stamps
   `MiniMaxTokenPlanResponse.receivedAt`, and with OpenCode Go's
   response-time clock.
5. **Never log, persist, or put the key in any report.** The Bearer
   header is built in memory and discarded with the request. Tests must
   assert the header is set correctly on the outbound request without
   ever printing the key in failure messages (compare on a known test
   key only).
6. **Host is fixed.** Only `api.minimax.io`. No `www.minimax.io` fallback,
   no China-region host, no redirect-following to a different host
   beyond whatever `URLSession` does by default for same-origin hops.
   (If a future capture shows auth redirects, revisit — today the
   evidenced failure is HTTP 200 + body 1004.)

`MiniMaxUsageProvider` itself does **not** change. It already depends only
on `MiniMaxTransporting`; swapping the fake for `MiniMaxHTTPTransport` is
a construction-site concern.

### 2. `Sources/AIUsageBarApp/UsageBarShellModel.swift` — wire `.live()`

In `liveProviders(settingsStore:)` add MiniMax next to the other three.
Order in the dictionary does not matter (`ProviderID.allCases` drives UI
order); keep source order Claude → Codex → OpenCode Go → MiniMax for
readability.

```swift
private static func liveProviders(settingsStore: SettingsStore) -> [ProviderID: any UsageProvider] {
    [
        .claude: ClaudeUsageProvider(/* unchanged */),
        .codex: CodexUsageProvider(/* unchanged */),
        .openCodeGo: OpenCodeGoProvider(/* unchanged */),
        .miniMax: MiniMaxUsageProvider(
            credentialReader: OpenCodeAuthFileCredentialReader(),
            transport: MiniMaxHTTPTransport()
        ),
    ]
}
```

Notes:

- `OpenCodeAuthFileCredentialReader()` uses the default init (honors
  `XDG_DATA_HOME`, else `~/.local/share/opencode/auth.json`). Do **not**
  inject a custom path from Settings — there is no Settings field for it.
- `settingsStore` is unused by MiniMax today (no workspace override). Keep
  the parameter as-is; do not force a dummy read.
- MiniMax does **not** conform to `UsageProviderStopping` /
  `UsageProviderShuttingDown`. Poller stop/shutdown already no-ops
  providers that don't conform — verify no new cast or registry is
  required (Codex is the only conformer today).
- Visibility stays default-hidden via `SettingsStore`; wiring the provider
  does **not** make it appear in the menu bar until the user enables it.
  The poller skips hidden providers entirely, so a default install still
  never hits the MiniMax endpoint.

### 3. `docs/endpoints.md` — transport footnote only

Slice 2 already recorded the contract. Append one bullet under MiniMax if
not already present:

```markdown
- Transport: shared `HTTPTransport` (`URLSessionHTTPTransport` in production)
  via `MiniMaxHTTPTransport`. Single GET, Bearer auth, `Content-Type:
  application/json`, `User-Agent: AIUsageBar/<version>`. Non-2xx throws and
  the provider surfaces `.networkError`. Auth rejection is body-shaped
  (HTTP 200 + `base_resp.status_code == 1004`) and is owned by the parser,
  not the transport. No cookie jar, no custom redirect filter, no host
  allow-list beyond the fixed endpoint URL.
```

Do not rewrite the rest of the section.

### 4. `AGENTS.md` (and the `CLAUDE.md` symlink)

Two wording updates so agents stop treating MiniMax as fixture-only:

1. Opening paragraph: drop "MiniMax is not yet wired into
   `UsageBarShellModel.live()` (fixture-backed provider + transport seam
   only — real HTTP lands next)". Replace with the same shape as OpenCode
   Go — hidden by default, live when enabled.
2. MiniMax bullet: replace "The real HTTP implementation … is not wired
   yet — tests use a fake transport" / "Not in `.live()` yet" with the
   live path: `MiniMaxHTTPTransport` → shared `HTTPTransport`, constructed
   in `.live()` with `OpenCodeAuthFileCredentialReader()`. Keep the
   failure-mapping and single-step-chain text.

No other AGENTS.md sections need MiniMax edits (package layout,
`ProviderDataSource`, `MiniMaxCredentialReading` already describe the
Slice 2 surface correctly).

### 5. No view-layer production edits expected

`DropdownViewModel`, `ProviderStatusViewModel`, `MenuBarTitleFormatter`,
`MenuBarLabel`, `AppSettingsView`, `AppSettingsDraft`,
`ThresholdNotifier`, and `NotificationSupport` already handle `.miniMax`
exhaustively from Slice 1. **If a compiler-flagged switch appears during
this slice, it is a regression — fix it, don't expand scope.**

The one place to double-check by reading (not rewriting):

- `ProviderStatusViewModel.recoveryCallout(for:)` MiniMax arms match the
  parent plan copy (already landed; Slice 3 tests pin both
  `.credentialUnavailable` and `.tokenExpired`).
- `chainFailureSummary(for:)` routes `.minimaxTokenPlanAPI` +
  `.networkError` → `"Network error"`, `.tokenExpired`/`.sessionExpired`
  → `"Key rejected"`, `.credentialUnavailable` → `"No credential found"`.
- `DropdownViewModel` monthly placeholder stays OpenCode-Go-only;
  MiniMax never grows a monthly row.

---

## Test additions

### 6. `Tests/UsageCoreTests/MiniMaxHTTPTransportTests.swift` (new)

Recording `HTTPTransport` fake (mirror the pattern used by Claude/Codex
transport tests — capture the `URLRequest`, return canned
`(Data, HTTPURLResponse)`).

| Test | Pins |
|---|---|
| `miniMaxHTTPTransportGETsFixedEndpointWithBearerAndJSONContentType` | Outbound request: method `GET`, URL exactly `https://api.minimax.io/v1/token_plan/remains`, `Authorization == "Bearer sk-test"`, `Content-Type == application/json`, `User-Agent` begins with `AIUsageBar/`. |
| `miniMaxHTTPTransportReturnsBodyAndInjectedReceivedAtOn2xx` | 200 + fixture bytes → `MiniMaxTokenPlanResponse(data: fixture, receivedAt: frozenNow)`. |
| `miniMaxHTTPTransportAcceptsAny2xx` | 204 (or 201) still returns the body + `receivedAt` (guard is `200..<300`, not `== 200`). |
| `miniMaxHTTPTransportThrowsOnNon2xx` | 401, 403, 500 → throws; provider-level mapping to `.networkError` is already covered by `miniMaxProviderIsStaleNetworkErrorOnTransportError`. |
| `miniMaxHTTPTransportPropagatesSenderErrors` | Fake throws `URLError(.timedOut)` → same error surfaces (no swallow). |
| `miniMaxHTTPTransportDoesNotInspectBodyForAuthFailure` | 200 + auth-failure fixture bytes are returned **unparsed** as `data`; the transport must not throw `AuthFailure.rejectedKey`. (Parser ownership pin.) |

Do **not** hit the live network. Do **not** put a real key in the test
file — use `sk-test`.

### 7. `Tests/UsageCoreTests/MiniMaxUsageProviderTests.swift` — one integration pin (optional but recommended)

Add a single test that constructs the provider with `MiniMaxHTTPTransport`
backed by the recording fake (not `FakeMiniMaxTransport`), so the real
adapter is exercised through `fetchReport` once:

| Test | Pins |
|---|---|
| `miniMaxProviderFreshPathThroughRealHTTPTransportAdapter` | Recording sender returns 200 + `minimax-token-plan.json`; credential reader returns `sk-test`; provider → `.fresh` with fixture usage, chain `[.used]`, source `.minimaxTokenPlanAPI`. |

Keeps the Slice 2 fake-transport suite as the exhaustive matrix; this is
the one "adapter is wired right" smoke.

### 8. `Tests/UsageCoreTests/DropdownViewModelTests.swift` — countdown pin

Slice 1's `dropdownRowsShowTwoWindowsForFreshMiniMax` only asserts
`fiveHour != nil` and `monthly == nil`. Add:

| Test | Pins |
|---|---|
| `dropdownRowsExposeMiniMaxFiveHourAndWeeklyCountdowns` | Fresh MiniMax with known `resetsAt` values (e.g. +90 min / +3 days from `referenceNow`) → fiveHour title `"5h"`, percent label, countdown via `CountdownFormatter` (`"resets in 1h 30m"` / weekday form); weekly title `"Weekly"` likewise. No guidance/stale rows. Proves US2 end-to-end at the view-model layer. |

Reuse the existing `deterministicCalendar()` / `Locale(identifier:
"en_US_POSIX")` helpers already in that file.

### 9. `Tests/UsageCoreTests/ProviderStatusViewModelTests.swift` — chain + recovery + auto-expand

| Test | Pins |
|---|---|
| `providerStatusShowsMiniMaxLiveChain` | Fresh MiniMax + chain `[.used]` + source `.minimaxTokenPlanAPI` + `lastUpdatedAt` → row text shaped `Live · MiniMax token plan API · updated …`; single step `Used …` with green indicator; `recoveryCallout == nil`; caption is the OpenCode-key caption. |
| `providerStatusShowsMiniMaxTokenExpiredRecoveryCallout` | Stale `.tokenExpired` + failed step → method `"MiniMax key rejected"`; step phrase `"Key rejected"`; recovery callout exactly the plan copy ("The MiniMax key was rejected. Re-authenticate the MiniMax provider in OpenCode, then choose Refresh Now from the menu bar." with the standard "Showing last-known data. " prefix). |
| `providerStatusShowsMiniMaxNetworkAndParseRecoveryCallouts` | Parameterized (or two tests) for `.networkError` / `.parseFailure` → generic callouts shared with other providers (no MiniMax-specific wording). |
| `providerStatusAutoExpandsStaleMiniMax` | `expandedProviders(remembering: [])` includes `.miniMax` when its state is stale, and does **not** include it when fresh/hidden/checking. If `ProviderChainViewModelTests` already covers the generic rule with other providers, a one-line MiniMax case there is enough — do not duplicate the whole suite. |

Re-read `providerStatusShowsMiniMaxRecoveryCalloutAndChainCaption` (Slice
1). Keep it; the new `.tokenExpired` test is the missing arm the slice
doc calls out.

### 10. `Tests/UsageCoreTests/MenuBarTitleFormatterTests.swift` — four-visible segments

`MenuBarLabelImageTests` already pins the **image partition**. Add the
**formatter** pin the slice doc names:

| Test | Pins |
|---|---|
| `menuBarTitleFormatterEmitsFourSegmentsInProviderOrderWhenAllVisible` | States for Claude, Codex, OpenCode Go, MiniMax all `.fresh` → `segments` count `4`, order matches `ProviderID.allCases` filter (Claude, Codex, OpenCode Go, MiniMax), values use each provider's display shape (`nn/nn`, `nn`, `nn/nn/nn`, `nn/nn`). |

Do **not** re-test the image split algorithm here — that lives in
`MenuBarLabelImageTests.menuBarLabelImagePartitionsFourProvidersAcrossTwoRows`
and already includes MiniMax.

### 11. `Tests/UsageCoreTests/ThresholdNotifierTests.swift` — MiniMax window

| Test | Pins |
|---|---|
| `thresholdNotifierSendsForMiniMaxWindow` | Previous MiniMax five-hour 25% → current 18% at threshold 20, same `resetsAt` → exactly one `UsageThresholdNotification` with `provider == .miniMax`, `window == .fiveHour`, `percentRemaining == 18`, `threshold == 20`. Title begins with `"MiniMax five-hour usage below 20%"`. |
| `usageThresholdNotificationDisplayTextForMiniMax` (optional, tiny) | Construct `UsageThresholdNotification(provider: .miniMax, …)` → title/body use `"MiniMax"` (proves `notificationDisplayName` arm). |

No notifier implementation change is expected — this is the "generic path
picks it up" proof the parent plan asks for.

### 12. `Tests/AIUsageBarAppTests/UsageBarShellModelTests.swift` — staged-on + live wiring

| Test | Pins |
|---|---|
| `stagedVisibilityDoesNotResurrectMiniMaxChainWhenStagedBackOn` | Mirror `stagedVisibilityDoesNotResurrectTheChainRecordedBeforeAProviderWasTurnedOff` but for `.miniMax`: apply a fresh MiniMax refresh result with source `.minimaxTokenPlanAPI` and chain `[.used]`, hide via `setProvider(.miniMax, visible: false)`, then `providerStatusViewModel(stagedVisibility: [.miniMax: true])` → indicator `.checking`, no age, chain steps all `Standing by` (single step for MiniMax's one-element `dataSourceChain`), no resurrected green `Used` step. |
| `liveProvidersIncludesMiniMax` | **Only if a testable seam exists without booting the real app.** Prefer: extract nothing new; instead add a focused pure test that constructing `MiniMaxUsageProvider(credentialReader: OpenCodeAuthFileCredentialReader(fileURL:), transport: MiniMaxHTTPTransport(sender:))` type-checks and that `ProviderID.miniMax` is in `ProviderID.allCases`. If the suite already has no `liveProviders` unit test for Claude/Codex/OpenCode Go, **do not invent one just for MiniMax** — the wiring is a one-line dictionary entry verified by code review + Slice 4 manual smoke. |

Default-hidden behavior is already pinned in `SettingsStoreTests`; do not
re-test it.

### 13. Docs-only verification (no new test file)

- `git grep -n "not yet wired\|Not in \.live()\|fixture-backed provider + transport seam only" AGENTS.md CLAUDE.md`
  returns no matches after the AGENTS.md edit.
- `git grep -nE "api\.minimaxi\.com|coding_plan/remains"` stays confined
  to `docs/endpoints.md` rejected-alternatives (and plans) — never in
  `Sources/`.

---

## Order of operations (TDD-friendly)

Each step ends with `swift build` green (and where marked,
`scripts/run-swift-tests`). Prefer small commits on `flow/minimax-slice-3`.

1. **Transport (red → green)**
   - Write `MiniMaxHTTPTransportTests.swift` against
     `MiniMaxHTTPTransport` (compile error).
   - Implement `MiniMaxHTTPTransport` in `MiniMax.swift`.
   - Build + the new transport tests green.
   - Optional: add `miniMaxProviderFreshPathThroughRealHTTPTransportAdapter`.

2. **Shell wiring**
   - Add `.miniMax: MiniMaxUsageProvider(...)` to
     `liveProviders(settingsStore:)`.
   - `swift build` green. No behavioral test required beyond existing
     suite (provider stays hidden by default, so nothing fetches yet in
     a default install).

3. **Dropdown countdown pin**
   - Add `dropdownRowsExposeMiniMaxFiveHourAndWeeklyCountdowns`.
   - Expect green with no production change; if red, fix
     `DropdownViewModel` only as needed (should already work).

4. **Status view model pins**
   - Add Live-chain, `.tokenExpired` recovery, network/parse recovery,
     and auto-expand MiniMax tests.
   - Expect green with no production change; copy drift is the only
     likely failure — update either the test or the callout to match
     `docs/PLAN-minimax.md` (plan copy wins).

5. **Menu bar four-segment pin**
   - Add `menuBarTitleFormatterEmitsFourSegmentsInProviderOrderWhenAllVisible`.
   - Expect green; formatter already general.

6. **ThresholdNotifier MiniMax pin**
   - Add `thresholdNotifierSendsForMiniMaxWindow` (+ optional display-text
     test).
   - Expect green; `notificationDisplayName` already returns `"MiniMax"`.

7. **Staged-on MiniMax pin**
   - Add `stagedVisibilityDoesNotResurrectMiniMaxChainWhenStagedBackOn`.
   - Expect green; `providerStatusViewModel(stagedVisibility:)` already
     drops retained state for any provider.

8. **Docs**
   - Endpoints transport footnote.
   - AGENTS.md live-wiring wording.

Final verification: `scripts/run-swift-tests` (must print
`Test run with N tests` and pass). `swift build` clean under Swift 6
strict concurrency.

---

## Verification checklist (mirrors slice acceptance criteria)

- [ ] `swift build` clean under Swift 6 strict concurrency.
- [ ] `scripts/run-swift-tests` executes and passes (full suite, not just
      builds — see `AGENTS.md` "Test-execution note").
- [ ] `MiniMaxHTTPTransport` issues the fixed GET with Bearer + JSON
      content type; non-2xx throws; body auth-failure is not interpreted
      by the transport.
- [ ] `UsageBarShellModel.liveProviders` includes `.miniMax` constructed
      with `OpenCodeAuthFileCredentialReader()` + `MiniMaxHTTPTransport()`.
- [ ] Dropdown tests pass for MiniMax 5h + weekly rows + countdowns.
- [ ] Status view model tests pass: Live chain, per-reason phrasing,
      recovery callouts (`.credentialUnavailable`, `.tokenExpired`,
      generic network/parse), auto-expand-stale includes MiniMax.
- [ ] Menu bar formatter test: four visible providers → four segments in
      stable order; image partition test (Slice 1) still passes.
- [ ] `ThresholdNotifier` test fires for a MiniMax window; notification
      title uses `"MiniMax"`.
- [ ] Staged-on settings preview drops retained MiniMax state/source/
      chain/last-updated.
- [ ] No `UsageProviderStopping` / `UsageProviderShuttingDown` conformance
      added for MiniMax.
- [ ] No key field in Settings; no key logged, persisted, or carried in
      `ProviderFetchReport` / UI labels.
- [ ] `AGENTS.md` no longer claims MiniMax is unwired / fixture-only.
- [ ] No China-region host, coding_plan cookie endpoint, or env-var key
      source in `Sources/`.
- [ ] Bundle / manual smoke left for Slice 4.

---

## Risks and follow-ups

- **HTTP status vs body auth.** MiniMax's evidenced auth failure is HTTP
  200 + `base_resp.status_code == 1004`. A future API change that starts
  returning 401/403 for bad keys would currently surface as
  `.networkError` (transport throws → provider generic catch). That is
  acceptable until a new capture says otherwise — do **not** pre-emptively
  special-case 401 in the transport.
- **Default-hidden means `.live()` wiring is invisible until enabled.**
  A green unit suite does not prove the endpoint works on a real key;
  that is Slice 4's manual smoke (enable → `Checking…` → `Live · MiniMax
  token plan API`). Do not expand Slice 3 into HITL.
- **Four-provider menu bar width.** Parent plan flags this as a product
  risk, not a pre-build. Slice 3 only pins the partition invariant; if
  two-and-two is too wide in practice, Slice 4 / a later decision can
  drop MiniMax to weekly-only in the title — out of scope here.
- **`staleReason(forHTTPStatusCode:)` stays unused by MiniMax.** It is
  `private` to `UsageCore.swift` and models Claude/Codex OAuth 401. Do
  not make it `internal` just to share it; the MiniMax transport's
  throw-on-non-2xx is the correct seam.
- **Key material in test failure output.** Recording-transport
  assertions should compare full header values against the known
  `sk-test` fixture key only. Never interpolate a credential read from
  disk into an `#expect` message.
- **Slice 4 dependencies.** Slice 4 needs this branch merged (or stacked)
  so `scripts/bundle.sh` picks up `liveProviders` MiniMax. No further
  code from Slice 3 is required for the manual checklist beyond what is
  listed above.
- **Concurrent enable + first poll.** Enabling MiniMax in Settings
  applies visibility on OK and the next poll (or Refresh Now) fetches.
  Existing poller / staged-visibility behavior already covers this for
  OpenCode Go; MiniMax rides the same path. No new coalescing logic.

---

## Mapping back to parent artifacts

| Source | Consumed here |
|---|---|
| `PLAN-minimax-slices.md` Slice 3 | Entire scope |
| `PLAN-minimax.md` Phase 4 (real transport half) | §1 `MiniMaxHTTPTransport` |
| `PLAN-minimax.md` Phase 5 | §2 shell wiring + §8–12 tests |
| `PLAN-minimax.md` recovery callout copy | §9 status tests (production copy already in Slice 1) |
| `docs/endpoints.md` MiniMax | §3 transport footnote only |
| Slice 1 UI scaffolding | Verified, not rewritten |
| Slice 2 provider/parser/reader | Consumed unchanged via `MiniMaxTransporting` |
