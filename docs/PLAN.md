# Implementation Plan: `mac-ai-usage-bar`

> Status: **historical** — all phases (0–7) were implemented and merged to `main` via PRs #1–#8 (July 2026). This document is kept as the original design record; the code is the source of truth where they differ (e.g. `UsageCore` ended up as flat source files rather than the subdirectory layout sketched below, and the menu bar symbols shipped as `*`/`#` rather than `✳`/`⬡`).

## Goal

A native SwiftUI menu bar app that always displays **percent remaining** for four rate-limit windows — Claude Max (5h, weekly) and ChatGPT/Codex (5h, weekly) — with a dropdown showing progress bars, reset countdowns, last-updated/refresh, and inline settings. Claude statusline-cache consumption, read-only Codex credential borrowing, 2-minute polling, threshold notifications, ad-hoc-signed local `.app` with launch-at-login.

## Non-goals

- No OAuth refresh or any write to credential stores (expired/missing Codex token or missing/stale Claude statusline cache → greyed "stale" state).
- No usage history/sparkline (v2).
- No API-billing tracking, no notarization/Homebrew, no multi-account support.

## Current observations

- The Phase 0 worktree now contains the initial Swift package skeleton, sanitized discovery fixtures, endpoint notes, and the Claude statusline cache wrapper. Later phases should build on this package rather than reinitializing the repository.
- Claude Code credentials confirmed in Keychain (service `Claude Code-credentials`), but the live usage endpoint returned HTTP 429 during Phase 0. Claude usage now comes from Claude Code's statusline JSON via `scripts/claude-statusline-cache`; the app reads the cached `rate_limits` payload instead of calling the private endpoint.
- Codex auth migrated from `~/.codex/auth.json` to Keychain (backup file `~/.codex/auth.json.file-backed-backup` present). **Codex CLI is open source (`openai/codex`)** — its Rust source is the authoritative reference for both the Keychain entry name and the usage/rate-limit endpoint.
- Toolchain: Swift 6.3.3, macOS 26.5. Target macOS 14+.

## Design decisions (agreed in interview)

| Decision | Choice |
|---|---|
| Data meaning | Subscription rate-limit windows (Claude Max + ChatGPT/Codex), not API billing |
| Data source | Claude Code statusline `rate_limits` cache; Codex CLI credentials → Codex usage endpoint |
| Stack | Native Swift/SwiftUI, SPM, `MenuBarExtra` |
| Menu bar display | All four numbers always visible (e.g. `✳ 62/81  ⬡ 72/90`) |
| Semantics | Percent **remaining** (fuel gauge), converting vendor "% used" where needed |
| Dropdown | Bars + exact %, reset countdowns, Refresh now + last-updated, inline settings |
| Refresh | Every 2 minutes + on wake + manual |
| Token/cache expiry | Read-only; degrade gracefully ("open Claude Code / Codex to refresh") |
| Alerts | Notification at threshold (default 20%, configurable), dedup once per window per reset cycle |
| Distribution | Personal local build, ad-hoc signed `.app`, login item |

## Architecture

```
Package: AIUsageBar
├── Sources/UsageCore/          ← library target: ALL logic, fully unit-testable
│   ├── Models/                 UsageWindow, ProviderUsage, ProviderState, UsageSnapshot
│   ├── Credentials/            CredentialStore (protocol), KeychainCredentialStore,
│   │                           CodexCredentialParser
│   ├── Statusline/             ClaudeStatuslineCacheReader
│   ├── Providers/              UsageProvider (protocol), ClaudeStatuslineProvider, CodexUsageProvider
│   ├── Polling/                UsagePoller (Clock-injected), AppState (observable store)
│   ├── Alerts/                 ThresholdNotifier (NotificationSending protocol)
│   └── Formatting/             MenuBarTitleFormatter, CountdownFormatter, StatusColor
├── Sources/AIUsageBarApp/      ← thin executable target: MenuBarExtra, views, DI wiring
├── Tests/UsageCoreTests/       ← Swift Testing, fixtures in Tests/Fixtures/*.json
└── scripts/bundle.sh           ← .app assembly + ad-hoc codesign
```

Seams for testability: `CredentialStore`, `StatuslineCacheStore`, `HTTPTransport` (wraps URLSession), `Clock`, `NotificationSending`, `SettingsStore`. Views contain no logic — they render `AppState` and call intents on it.

Key domain types:

```swift
struct UsageWindow { let percentRemaining: Int; let resetsAt: Date? }
struct ProviderUsage { let fiveHour: UsageWindow; let weekly: UsageWindow }
enum ProviderState { case fresh(ProviderUsage, asOf: Date)
                     case stale(last: ProviderUsage?, reason: StaleReason)  // .tokenExpired, .networkError, .parseFailure
                     case hidden }
```

---

## Phase 0 — Discovery & scaffolding

Manual/spike work that de-risks everything downstream. No production code except the package skeleton.

### 0.1 Repo + package skeleton + harness (first TDD slice)

- `git init`, `main` branch, then immediately branch `feat/scaffold` (never commit to main).
- `Package.swift` with the three targets above.
- **Red:** `@Test func harnessWorks() { #expect(UsageCore.version == "0.1.0") }` — fails to compile (no `UsageCore.version`).
- **Green:** add the constant. Run `swift test --enable-swift-testing` to build the Swift Testing bundle, then `scripts/run-swift-tests` to prove the `harnessWorks()` symbol is linked and the built `UsageCore.version` smoke assertion executes.

### 0.2 Capture Claude credential shape + statusline fallback

- Read the Keychain entry via `security find-generic-password -s "Claude Code-credentials" -w` (one targeted read, with permission), note the JSON schema (access token field, `expiresAt`), **do not commit the values**.
- Confirm the direct usage endpoint Claude Code uses (`GET https://api.anthropic.com/api/oauth/usage` with Bearer token + the `anthropic-beta` OAuth header) and record the live-call outcome in `docs/endpoints.md`. If it returns HTTP 429, do **not** fabricate `Tests/Fixtures/claude-usage.json`.
- Use `scripts/claude-statusline-cache` as the accepted Phase 0 fallback: it tees Claude Code's statusline JSON to a local cache file and forwards stdin to `ccstatusline`.
- Commit a sanitized statusline fixture as `Tests/Fixtures/claude-statusline.json`, preserving the `rate_limits` schema that downstream parsing will consume.

### 0.3 Pin down Codex auth + endpoint from source

- Read `openai/codex` source (GitHub) to find: the Keychain service/account name it uses on macOS, the JWT layout (for expiry detection), and the endpoint/headers it queries for rate-limit status.
- One targeted Keychain read to confirm, one `curl` to capture `Tests/Fixtures/codex-usage.json` (sanitized).

**Exit criteria:** sanitized Claude statusline and Codex usage fixtures committed; a `docs/endpoints.md` noting Claude's direct endpoint failure, the statusline fallback/cache path, Codex URL, headers, auth, and expiry-detection method. `scripts/claude-statusline-cache` and its integration test must be committed. `swift build && swift test` must pass; on CommandLineTools-only installs where SwiftPM builds but does not launch Swift Testing bundles, `scripts/run-swift-tests` must also pass to prove the Swift Testing harness is linked and `UsageCore.version` is executable through the built module.

**Stop condition:** if the Codex endpoint can't be called successfully from `curl` (e.g. Codex requires request signing we can't replicate), stop and report. For Claude, a 429 from the direct endpoint is acceptable only if the statusline-cache fallback and sanitized `claude-statusline.json` fixture are in place. Do not fabricate direct API fixtures.

---

## Phase 1 — Domain models & parsing (pure logic, fixture-driven)

### 1.1 Claude statusline fixture → `ProviderUsage`

- **Red:** `claudeParserMapsFixture()` — parse `claude-statusline.json`, expect `fiveHour.percentRemaining == 100 - rate_limits.five_hour.used_percentage`, `weekly.percentRemaining == 100 - rate_limits.seven_day.used_percentage`, and correct `resetsAt` dates from Unix epoch seconds. Fails: parser doesn't exist.
- **Green:** `ClaudeStatuslineParser` with `Decodable` models matching the captured statusline schema.
- **Refactor:** extract shared "utilization → percent remaining, clamped 0...100" helper.

### 1.2 Claude parser edge cases

- **Red:** tests for missing weekly field, utilization > 100, malformed JSON → expect `.parseFailure` error (soft-fail, never crash), clamping to 0.
- **Green:** defensive decoding with `throws` + clamping.

### 1.3 Codex response → `ProviderUsage`

- Same red/green/refactor shape against `codex-usage.json`, including whatever unit Codex reports (if it reports "percent left" natively, the test pins the no-conversion path — semantics stay "remaining" either way).

### 1.4 Countdown formatting

- **Red:** `CountdownFormatter` tests: `resetsAt` 2h14m ahead of injected `now` → `"resets in 2h 14m"`; weekly reset 3 days out → `"resets Thu 9:00 AM"` (relative under 24h, absolute weekday beyond); past date → `"resetting…"`.
- **Green:** pure function taking `(Date, now: Date, calendar: Calendar)` — fully deterministic, no `Date()` inside.

### 1.5 Menu bar title formatting

- **Red:** `MenuBarTitleFormatter` tests: two fresh providers → `"✳ 62/81  ⬡ 72/90"`; one provider hidden → only the other; provider stale → its numbers wrapped in stale marker (e.g. `"✳ ~62/81"`); no data ever → `"✳ --/--"`.
- **Green:** pure `format([ProviderID: ProviderState]) -> AttributedString`.

### 1.6 Status color

- **Red:** `StatusColor` tests: remaining ≥ threshold → normal, < threshold → warning, < 5 → critical; color derives from the *minimum* of a provider's two windows.
- **Green:** trivial pure function.

**Exit criteria:** `swift test` green; all Phase-1 logic has zero imports beyond Foundation.

---

## Phase 2 — Credential access (read-only)

### 2.1 Claude statusline cache reading

- **Red:** `ClaudeStatuslineCacheReader` test with an injected file path: existing fresh fixture returns data; missing file returns `.stale(.networkError)` with a hint to configure Claude Code statusline; stale mtime returns stale with last-known data when parse succeeds.
- **Green:** reader over `Data` and file attributes, no Keychain dependency.

### 2.2 Codex credential parsing

- **Red:** same for Codex's stored JSON; expiry read from the JWT `exp` claim (test with a hand-built dummy JWT — base64 JSON, no signature check needed since we only *read* expiry).
- **Green:** minimal JWT payload decoder (split on `.`, base64url-decode segment 1).

### 2.3 Keychain adapter

- **Red:** unit tests against `CredentialStore` protocol using an in-memory fake: Codex provider asks store for `.codex` → gets blob → parser path; store returns nil → `.stale(.tokenExpired)` path upstream.
- **Green:** `KeychainCredentialStore` implementing the protocol with `SecItemCopyMatching` (kSecClassGenericPassword, service names from Phase 0). The real adapter is a thin ~30-line leaf.
- **Manual verification (not CI):** a tagged `.integration` test, disabled by default, that reads the real entries and asserts non-empty — run once by hand.

**Constraint the code must show:** the adapter has no write/delete calls — enforce with a test that the protocol itself exposes only `read(_:) -> Data?`.

---

## Phase 3 — Providers & networking

### 3.1 Claude statusline provider

- **Red:** `ClaudeStatuslineProvider` test with an injected cache reader: given fixture bytes and fresh file metadata, `fetch()` returns `.fresh` usage; missing/stale/malformed cache returns stale states without network calls.
- **Green:** provider implementation over `ClaudeStatuslineCacheReader`.

### 3.2 HTTP transport seam

- **Red:** `CodexUsageProvider` test with `FakeTransport`: given a stubbed 200 + fixture body, `fetch()` returns `.fresh` usage; asserts the request it built has the right URL, `Authorization: Bearer`, and account headers (pinned from Phase 0).
- **Green:** `HTTPTransport` protocol (`func send(URLRequest) async throws -> (Data, HTTPURLResponse)`) + provider implementation.

### 3.3 Error taxonomy

- **Red:** table-driven tests: 401 → `.stale(.tokenExpired)`; 429/5xx → `.stale(.networkError)` keeping last-known data; body that no longer decodes → `.stale(.parseFailure)`; transport throw (offline) → `.stale(.networkError)`. Expired-before-request token → provider **skips the network call** entirely and returns `.tokenExpired` (never sends a dead token).
- **Green:** map in one place; providers never `throw` upward — they always return a `ProviderState`.

### 3.4 Codex provider

- Same slices as 3.2/3.3 against the Codex endpoint contract.

---

## Phase 4 — Polling engine & app state

### 4.1 Poll loop

- **Red:** with a `TestClock` and fake providers: `UsagePoller.start()` fetches immediately, then again when the clock advances 120s; changing the interval setting reschedules; fetches for the two providers run concurrently and one provider failing doesn't block the other's update.
- **Green:** async loop using injected `Clock.sleep`; `AppState` (`@Observable`) updated on the main actor.

### 4.2 Manual refresh + last-updated

- **Red:** `refreshNow()` triggers immediate fetch and resets the timer phase; `AppState.lastUpdated(provider:)` reflects the fake clock's time of last **successful** fetch (a failed poll updates "last attempt" but not "as of").
- **Green:** implement; refactor poller/state boundary if muddy.

### 4.3 Wake refresh

- **Red:** poller test: feeding a `wakeEvents` async stream one event triggers an immediate poll.
- **Green:** seam is an `AsyncStream<Void>`; the app wires `NSWorkspace.didWakeNotification` to it (wiring itself is manual-verify).

---

## Phase 5 — Threshold notifications

### 5.1 Crossing detection with dedup

- **Red:** `ThresholdNotifier` tests: remaining drops 25→18 with threshold 20 → exactly one notification for that window; subsequent polls at 15, 12 → no repeat; window's `resetsAt` moves forward (new cycle) → armed again; rising back above threshold alone does **not** re-arm within the same cycle; each of the four windows tracked independently; stale providers never notify.
- **Green:** notifier keeps `[WindowID: firedForResetAt]`; emits via `NotificationSending` protocol.

### 5.2 Threshold configurability

- **Red:** changing the threshold setting takes effect on the next evaluation and re-arms sensibly (fired-at-20 doesn't refire when threshold moves 20→30 mid-cycle unless a new crossing occurs).
- **Green:** implement. `UNUserNotificationCenter` adapter is a thin leaf; permission request happens on first enable (manual verify).

---

## Phase 6 — SwiftUI shell (thin, mostly manual verification)

Logic is already tested; these slices are wiring plus view-model tests where decisions exist.

### 6.1 Dropdown view model

- **Red:** `DropdownViewModel` tests: ordering (Claude then OpenAI), rows expose bar fraction/label/countdown strings from `ProviderState` (reusing Phase-1 formatters), stale rows flagged for grey styling, hidden providers omitted.
- **Green:** implement; views become dumb `ForEach`.

### 6.2 Settings store

- **Red:** `SettingsStore` round-trips interval / per-provider visibility / threshold / launch-at-login flag through an injected `UserDefaults(suiteName: test)`.
- **Green:** implement.

### 6.3 App target

- `MenuBarExtra` with formatter-driven label, dropdown with progress bars + countdowns + "Refresh now" + "Updated 3m ago" + inline settings (interval picker, provider toggles, threshold stepper, launch-at-login toggle via `SMAppService.mainApp`, Quit).
- **Verification is manual:** a written checklist (bar renders four numbers; stale grey-out by temporarily renaming a Keychain lookup; refresh works; settings persist across relaunch).

---

## Phase 7 — Bundle, login item, acceptance

### 7.1 `scripts/bundle.sh`

- `swift build -c release` → assemble `AIUsageBar.app` (Info.plist with `LSUIElement=true` so no Dock icon) → `codesign --force -s -`.
- Testable bit: script exits 0 and `codesign -v` passes; script exposes a `--verify` flag for the smoke check.

### 7.2 Login item

- Enable via the settings toggle; manual verify across logout/login.

### 7.3 Acceptance checklist

Manual, documented in `docs/acceptance.md`:
- Fresh boot → numbers within 2 min.
- Wi-Fi off → greyed values, no crash.
- Token deliberately expired (wait, don't mutate) → stale hint text.
- Notification fires crossing 20%.
- CPU ~0% between polls.

---

## Verification commands

| Command | Expectation |
|---|---|
| `swift build` | clean build, no warnings under Swift 6 strict concurrency |
| `swift test --enable-swift-testing` | SwiftPM builds the Swift Testing bundle successfully |
| `scripts/run-swift-tests` | CommandLineTools-safe harness check: builds/tests, confirms `harnessWorks()` is linked, and executes the `UsageCore.version` smoke assertion against the built module |
| `swift test --filter Integration` | manual-only Keychain/live-endpoint checks |
| `./scripts/bundle.sh && codesign -v AIUsageBar.app` | bundle assembles and signature verifies |

Commit after each green slice (`commit` skill), feature branches only.

## Risks & stop conditions

1. **Undocumented endpoints change** — Claude direct endpoint risk is mitigated by consuming Claude Code statusline `rate_limits`; Codex endpoint risk is mitigated by soft-fail parse states and fixtures pinned to observed reality. *Stop* in Phase 0 if Codex is unreachable from `curl`, or if Claude statusline `rate_limits` cannot be captured or represented.
2. **Codex Keychain entry not readable by another process** (ACL prompt or denial) — surfaces in Phase 0/2 integration test. *Stop and report* if macOS blocks cross-process read; fallback candidate: `auth.json.file-backed-backup` staleness makes it a poor source, so this would be a real decision point.
3. **Refresh-token safety** — structurally guaranteed: the `CredentialStore` protocol has no write surface; no OAuth refresh code exists anywhere.
4. **Swift 6 concurrency friction** in the poller — contained by keeping `AppState` main-actor and providers `Sendable` value types.
5. **Notification permission denied** — app must function as pure display; notifier tests cover the "sender unavailable" path.
