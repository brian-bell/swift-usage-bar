# AGENTS.md

Context for AI coding agents working in this repository. `CLAUDE.md` is a symlink to this file.

## What this project is

**AIUsageBar** is a native macOS menu bar app (SwiftUI `MenuBarExtra`) that displays **percent remaining** for four subscription rate-limit windows: Claude (5-hour and weekly) and ChatGPT/Codex (5-hour and weekly). The menu bar label renders visible providers as a compact two-line stack, one provider per row (e.g. `Cl 62/81` over `Cx 72/90` — `Cl` is Claude, `Cx` is Codex, formatted as `fiveHour/weekly` percent remaining, `~` prefix when stale, `--/--` when no data; a lone visible provider renders as a single compact row, and `AI Usage` is shown when all providers are hidden). The dropdown shows progress bars, reset countdowns, a Refresh-now button with last-updated label, and inline settings.

Data access is strictly **read-only**: the app borrows existing CLI state and never writes to credential stores or refreshes OAuth tokens. When data can't be fetched, providers degrade to a greyed "stale" state instead of erroring.

- **Claude (primary path — OAuth usage API)**: **runs for every fetch, background and interactive** — the mode difference lives in the Keychain read: `.background` sets `kSecUseAuthenticationUIFail`, so an ACL that would prompt fails silently (`errSecInteractionNotAllowed` → statusline-cache fallback) and an automatic poll can never present a Keychain dialog; only a manual Refresh-now can prompt. It reads Claude Code's OAuth credential from the macOS Keychain (service `Claude Code-credentials`, matched by service only — the account attribute is omitted), falling back read-only to `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json` when the Keychain can't produce a usable credential (some Claude Code 2.1.x versions keep only `mcpOAuth` state in the Keychain item and the real credential in that file; an empty `CLAUDE_CONFIG_DIR` counts as unset). A *present* file's verdict wins over the Keychain's stale reason; an absent or unreadable file keeps the Keychain's reason, so keychain-only machines behave exactly as before. Either source decodes `claudeAiOauth.accessToken` + `expiresAt` (epoch **milliseconds**), and the app calls `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer` and `anthropic-beta: oauth-2025-04-20`. An expired token short-circuits with no network call. The response's `five_hour`/`seven_day` `utilization` floats are percent used; `resets_at` is ISO 8601 with 6-digit fractional seconds (the parser normalizes fraction lengths `ISO8601DateFormatter` can't handle). A window that saw no recent usage lapses to an explicit `null` (e.g. `five_hour` after an idle night): the parser treats a null or missing window as 100% remaining with an unknown reset, but a body with neither window key (an error payload, `{}`) still fails as a parse failure. The parser also surfaces the model-scoped **Fable** weekly window when present — the entry in the response's `limits` array whose `scope.model.display_name` is `Fable` (its `percent` is percent used) — as an optional third window shown under Claude in the dropdown only (not the menu bar title, tone, or threshold notifications); a Fable entry with an unparseable/absent `resets_at` still renders with an unknown reset rather than being dropped. The app never refreshes the token — a machine with no recent Claude Code activity degrades to `.tokenExpired` stale by design (tokens live < 24 h).
- **Claude (fallback — statusline cache)**: Claude Code's statusline JSON in a local cache file (`${XDG_CACHE_HOME:-~/.cache}/ai-usage-bar/claude-status.json`, overridable via `AI_USAGE_BAR_CLAUDE_STATUS_JSON`) is the fallback whenever the API path can't produce fresh data (silently denied background Keychain read, expired token, network error, parse failure): a fresh cache still yields fresh data, and when both paths fail the API's failure reason is surfaced with the best available last-known usage (cache's over the caller's). The cache is written by `scripts/claude-statusline-cache`, a passthrough wrapper the user configures as their Claude Code statusline command (it tees stdin to the cache, then forwards to `ccstatusline`). Because multiple concurrent Claude Code sessions all run the wrapper — and idle sessions keep re-rendering with rate limits from their last API response — the wrapper only overwrites the cache when the incoming payload is at least as fresh, compared lexicographically on (weekly resets_at, weekly used, five-hour resets_at, five-hour used). The compare-and-replace runs under an exclusive `flock` on `claude-status.json.lock` (a persistent empty file next to the cache) so concurrent writers can't race the decision; if the guard itself can't run it falls open to writing, except that a payload without usable rate limits never replaces one with them. Both `used_percentage` and `resets_at` are accepted as int or float (Claude Code emits float percentages like `7.000000000000001`; the Swift decoder rounds to whole percent). On startup the wrapper reaps its own temp files older than an hour — strands left behind when a render is SIGKILLed (e.g. a statusline timeout). Cache older than 3× the poll interval is treated as stale.
- **Codex**: reads the Codex CLI credential from the macOS Keychain (service `Codex Auth`, account `cli|<first 8 bytes of sha256(canonical CODEX_HOME) as hex>`), checks JWT `exp` for expiry (expired token → no network call), then calls `GET https://chatgpt.com/backend-api/wham/usage` with the bearer token.

## Repository state

All eight implementation phases (0–7) of `docs/PLAN.md` are complete and merged to `main` (PRs #1–#8, July 2026). Development happened on stacked `flow/phase-*` branches, some of which may still exist in `/Users/brian/dev/mac-ai-usage-bar-worktrees/`. The GitHub remote is `brian-bell/swift-usage-bar`.

## Build, test, run

There is no Makefile or CI config; SwiftPM and shell scripts are the whole build system. Toolchain: Swift 6 (6.3.3 via full Xcode 26.6, selected with `xcode-select`; the project was CommandLineTools-only until July 2026), target macOS 14+.

| Command | Purpose |
|---|---|
| `swift build` | Debug build; must be clean under Swift 6 strict concurrency |
| `swift test --enable-swift-testing` | Build **and execute** the Swift Testing suites (needs full Xcode selected; see note below) |
| `scripts/run-swift-tests` | Full harness: build + execute tests, failing if the toolchain compiled the suites without actually running them |
| `scripts/bundle.sh` | Release build → assemble `AIUsageBar.app` → codesign (ad-hoc, or `CODESIGN_IDENTITY`) → verify |
| `scripts/bundle.sh --verify [APP_PATH]` | Verify an existing bundle (plist keys, executable, signature) |
| `Tests/Scripts/bundle-script-test.sh` | Shell tests for the bundle script |
| `Tests/Scripts/claude-statusline-cache-test.sh` | Shell tests for the statusline cache wrapper |
| `scripts/setup-statusline` | Idempotently wire the cache wrapper into `statusLine` in Claude Code settings, preserving any existing statusline command in a passthrough shim |
| `Tests/Scripts/setup-statusline-test.sh` | Shell tests for the statusline setup script |
| `scripts/make-signing-cert` | Create + import a local CA-signed code-signing identity (stable designated requirement) for `CODESIGN_IDENTITY` |
| `Tests/Scripts/make-signing-cert-test.sh` | Shell tests for the signing-cert script (dry-run only, no keychain writes) |

Note: `Package.swift` carries `unsafeFlags` on the test targets pointing at `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` because a CommandLineTools-only install exposes Swift Testing there but ships no `XCTest.framework`; the flags are harmless under full Xcode. Tests use Swift Testing (`@Test`/`#expect`), not XCTest.

**Test-execution note:** this machine has full Xcode selected (`xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`), so `swift test --enable-swift-testing` genuinely executes the suites. On a CommandLineTools-only toolchain it compiles and links the test bundle but exits after `Build complete!` without executing anything (there is no runner to host the bundle) — `scripts/run-swift-tests` guards against that failure mode by requiring a `Test run with N tests` line in the output, and tells you to select full Xcode if it's missing. The first real execution of the suites (July 2026) surfaced 4 latent test failures, tracked (and fixed) via issue #17.

The app bundle is `AIUsageBar.app` (identifier `dev.brianbell.AIUsageBar`, `LSUIElement=true` so no Dock icon), signed for personal local use — no notarization or distribution. `bundle.sh` picks its signing identity in this order: an explicit `CODESIGN_IDENTITY`, else the first valid **"Apple Development"** identity in the keychain (preferred: its signature carries a genuine TeamIdentifier, so Keychain "Always Allow" grants record a stable `teamid:` partition entry and rebuilds stop prompting), else ad-hoc. A bad identity fails the signing step (`codesign signing failed for identity: …`) and the staging directory is cleaned up on any exit. When rebuilding or relaunching the user's login app, do not silently accept the ad-hoc fallback: run plain `scripts/bundle.sh` and verify with `codesign -dvvv AIUsageBar.app 2>&1` that `Signature=adhoc` is absent and a `TeamIdentifier` is set. Machines without an Apple Development identity can create a local one with `scripts/make-signing-cert` (set `CODESIGN_IDENTITY` to its name); that gives a stable designated requirement but no TeamIdentifier — macOS partition lists then pin each build's cdhash, costing one keychain prompt per provider per rebuild, and AMFI SIGKILLs any attempt to claim a team identifier without an Apple-issued chain (verified July 2026; do not re-attempt `--team-identifier`). `security find-identity -v -p codesigning` lists valid identities; treat the post-build `codesign -dvvv` output as authoritative.

## Package layout

```
Package: AIUsageBar
├── Sources/UsageCore/            library target — ALL logic, fully unit-testable, UI-free
│   ├── UsageCore.swift           domain models, providers, credential access, poller,
│   │                             notifier, parsers, formatters (single flat file)
│   ├── DropdownViewModel.swift   pure view model for the dropdown rows
│   └── SettingsStore.swift       UserDefaults-backed settings
├── Sources/AIUsageBarApp/        thin executable target — SwiftUI shell + system adapters
│   ├── AIUsageBarApp.swift       @main MenuBarExtra scene
│   ├── UsageBarShellModel.swift  @Observable shell model + live DI wiring (`.live()`)
│   ├── MenuBarContentView.swift  dropdown UI (rows, refresh, settings, quit)
│   ├── NotificationSupport.swift UNUserNotificationCenter adapter + wake-event stream
│   └── LaunchAtLoginService.swift SMAppService.mainApp adapter
├── Tests/UsageCoreTests/         Swift Testing suites for all core logic
├── Tests/AIUsageBarAppTests/     shell model, notification sender, launch-at-login tests
├── Tests/Fixtures/               sanitized captured payloads (claude-statusline.json,
│                                 claude-usage.json, codex-usage.json)
├── Tests/Scripts/                shell tests for scripts/
└── scripts/                      bundle.sh, run-swift-tests, claude-statusline-cache,
                                  setup-statusline
```

Note the plan's aspirational subdirectory layout (`Models/`, `Providers/`, …) was flattened in practice: `UsageCore.swift` is one ~1700-line file.

## Key types and seams

All seams are protocols with injectable fakes; production adapters are thin leaves.

- `UsageWindow` / `ProviderUsage` / `ProviderState` (`.fresh` / `.stale(last:reason:)` / `.hidden`) — core domain. Providers never throw upward; they always return a `ProviderState`. Vendor "% used" is converted to percent remaining, clamped 0–100.
- `UsageProvider` — `fetch(previous:mode:) async -> ProviderState` (with a `fetch(previous:)` convenience defaulting to `.background`). Implementations: `ClaudeUsageProvider` (via `ClaudeCredentialReading` + `HTTPTransport`, falling back to `ClaudeStatuslineCacheReading`), `CodexUsageProvider` (via `CodexCredentialReading` + `HTTPTransport`). HTTP 401 → `.tokenExpired`; other non-200/transport errors → `.networkError`; undecodable body → `.parseFailure` — always keeping last-known data. `ClaudeUsageProvider` tries the API on every fetch (threading `mode` to the credential read) and falls back to the statusline cache: a fresh cache wins over any API failure; when both fail the API's reason is surfaced and the cache's last-known usage is preferred over the caller's `previous`.
- `CredentialAccessMode` (`.interactive` / `.background`) — threads poller → provider → credential reader → keychain query. For both providers, `.background` (the default everywhere) sets `kSecUseAuthenticationUIFail` on the `SecItemCopyMatching` query so a background poll never presents a Keychain prompt: if the item's ACL would require confirmation, the read fails with `errSecInteractionNotAllowed` and the provider degrades silently (for Claude, to the statusline cache). Only `refreshNow()` uses `.interactive`, so prompts are reserved for user-initiated refreshes.
- `CredentialStore` — read-only by design: the protocol exposes only `read(_:mode:) -> Data?` (plus a `read(_:)` convenience defaulting to `.background`). Two implementations: `KeychainCredentialStore` wraps `SecItemCopyMatching`, and `ClaudeCredentialsFileStore` reads `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json` (absent file → `nil`, unreadable → `.unavailable`; `mode` is ignored since file reads can't prompt) — wired as `ClaudeCredentialReader`'s `fallbackStore` in `.live()`. There are no write/delete calls anywhere, and tests enforce this. **Do not add a write surface.**
- `UsagePoller` (actor) — polls every 2 minutes by default (min 1 s), plus on wake (`AsyncStream<Void>` seam wired to `NSWorkspace.didWakeNotification`) and on manual refresh. Automatic polls (start/timer/wake) use `.background` credential access; `refreshNow()` uses `.interactive`, and a manual refresh that coalesces onto an in-flight cycle upgrades the pending poll to `.interactive` so it isn't downgraded to a silent read. Providers fetch concurrently; one failing doesn't block the other. Uses generation counters + a `PollLifecycle` guard so stale results from a cancelled cycle are never applied. Hidden providers are skipped entirely.
- `AppState` (`@MainActor @Observable`) — provider states, hidden set, last-attempted vs. last-successful refresh times (a failed poll updates "attempted" but not "as of").
- `ThresholdNotifier` (actor) — fires once per (provider, window, threshold, reset-cycle) when percent remaining crosses below the threshold (default 20%, configurable); re-arms on new reset cycle; retries after failed delivery; stale providers never notify.
- `UsageClock` — injectable now/sleep for deterministic poller tests.
- Formatters are pure functions: `MenuBarTitleFormatter`, `CountdownFormatter` (relative under 24 h, weekday+time beyond, "resetting..." when past), `tone(for:)` (normal / warning below threshold / critical below 5%, driven by the minimum of a provider's two windows).
- `SettingsStore` — UserDefaults keys under `settings.*`: poll interval, threshold percent, per-provider visibility, launch-at-login flag.

## Conventions and gotchas

- **TDD** (red–green–refactor) with Swift Testing; every behavior in `UsageCore` has a test. Views contain no logic — they render `AppState`/view models and call intents on the shell model.
- Swift 6 strict concurrency throughout: value types are `Sendable`, `UsagePoller`/`ThresholdNotifier` are actors, `AppState` is main-actor.
- Never commit real credentials or unsanitized captured payloads; fixtures in `Tests/Fixtures/` are sanitized. `docs/endpoints.md` records the discovered endpoint/keychain contracts and the evidence behind them.
- Do not add OAuth refresh, credential writes, or calls that could mutate CLI state — read-only access is a hard product constraint (see `docs/PLAN.md` non-goals).
- Feature branches only; never commit or push directly to `main`.
