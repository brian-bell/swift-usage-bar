# AGENTS.md

Context for AI coding agents working in this repository. `CLAUDE.md` is a symlink to this file.

## What this project is

**AIUsageBar** is a native macOS menu bar app (SwiftUI `MenuBarExtra`) that displays **percent remaining** for four subscription rate-limit windows: Claude (5-hour and weekly) and ChatGPT/Codex (5-hour and weekly). The menu bar title shows all visible providers at a glance (e.g. `* 62/81  # 72/90` — `*` is Claude, `#` is Codex, formatted as `fiveHour/weekly` percent remaining, `~` prefix when stale, `--/--` when no data). The dropdown shows progress bars, reset countdowns, a Refresh-now button with last-updated label, and inline settings.

Data access is strictly **read-only**: the app borrows existing CLI state and never writes to credential stores or refreshes OAuth tokens. When data can't be fetched, providers degrade to a greyed "stale" state instead of erroring.

- **Claude**: reads Claude Code's statusline JSON from a local cache file (`${XDG_CACHE_HOME:-~/.cache}/ai-usage-bar/claude-status.json`, overridable via `AI_USAGE_BAR_CLAUDE_STATUS_JSON`). The cache is written by `scripts/claude-statusline-cache`, a passthrough wrapper the user configures as their Claude Code statusline command (it tees stdin to the cache, then forwards to `ccstatusline`). No network call is made for Claude — the live usage endpoint returned HTTP 429 during discovery (see `docs/endpoints.md`). Cache older than 3× the poll interval is treated as stale.
- **Codex**: reads the Codex CLI credential from the macOS Keychain (service `Codex Auth`, account `cli|<first 8 bytes of sha256(canonical CODEX_HOME) as hex>`), checks JWT `exp` for expiry (expired token → no network call), then calls `GET https://chatgpt.com/backend-api/wham/usage` with the bearer token.

## Repository state

All eight implementation phases (0–7) of `docs/PLAN.md` are complete and merged to `main` (PRs #1–#8, July 2026). Development happened on stacked `flow/phase-*` branches, some of which may still exist in `/Users/brian/dev/mac-ai-usage-bar-worktrees/`. The GitHub remote is `brian-bell/swift-usage-bar`.

## Build, test, run

There is no Makefile or CI config; SwiftPM and shell scripts are the whole build system. Toolchain: Swift 6 (developed on 6.3.3, CommandLineTools-only), target macOS 14+.

| Command | Purpose |
|---|---|
| `swift build` | Debug build; must be clean under Swift 6 strict concurrency |
| `swift test --enable-swift-testing` | Build the Swift Testing suites (see caveat below) |
| `scripts/run-swift-tests` | Full harness: build + test build + linkage check + UsageCore smoke compile |
| `scripts/bundle.sh` | Release build → assemble `AIUsageBar.app` → ad-hoc codesign → verify |
| `scripts/bundle.sh --verify [APP_PATH]` | Verify an existing bundle (plist keys, executable, signature) |
| `Tests/Scripts/bundle-script-test.sh` | Shell tests for the bundle script |
| `Tests/Scripts/claude-statusline-cache-test.sh` | Shell tests for the statusline cache wrapper |

Note: `Package.swift` carries `unsafeFlags` on the test targets pointing at `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` because a CommandLineTools-only install exposes Swift Testing there but ships no `XCTest.framework`. Tests use Swift Testing (`@Test`/`#expect`), not XCTest.

**Test-execution caveat:** on a CommandLineTools-only machine (no full Xcode), `swift test --enable-swift-testing` compiles and links the test bundle but exits after `Build complete!` without executing tests — there is no XCTest runner to host the bundle. `scripts/run-swift-tests` compensates by verifying the built test bundle links the expected Swift Testing symbols and by smoke-compiling a program against `UsageCore`. To actually execute the suites, run `swift test` on a machine with full Xcode installed. Don't mistake a green `swift test` here for executed tests.

The app bundle is `AIUsageBar.app` (identifier `dev.brianbell.AIUsageBar`, `LSUIElement=true` so no Dock icon), ad-hoc signed for personal local use — no notarization or distribution.

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
├── Tests/Fixtures/               sanitized captured payloads (claude-statusline.json, codex-usage.json)
├── Tests/Scripts/                shell tests for scripts/
└── scripts/                      bundle.sh, run-swift-tests, claude-statusline-cache
```

Note the plan's aspirational subdirectory layout (`Models/`, `Providers/`, …) was flattened in practice: `UsageCore.swift` is one ~1400-line file.

## Key types and seams

All seams are protocols with injectable fakes; production adapters are thin leaves.

- `UsageWindow` / `ProviderUsage` / `ProviderState` (`.fresh` / `.stale(last:reason:)` / `.hidden`) — core domain. Providers never throw upward; they always return a `ProviderState`. Vendor "% used" is converted to percent remaining, clamped 0–100.
- `UsageProvider` — `fetch(previous:) async -> ProviderState`. Implementations: `ClaudeUsageProvider` (via `ClaudeStatuslineCacheReading`), `CodexUsageProvider` (via `CodexCredentialReading` + `HTTPTransport`). HTTP 401 → `.tokenExpired`; other non-200/transport errors → `.networkError`; undecodable body → `.parseFailure` — always keeping last-known data.
- `CredentialStore` — read-only by design: the protocol exposes only `read(_:) -> Data?`. `KeychainCredentialStore` wraps `SecItemCopyMatching`; there are no write/delete calls anywhere, and tests enforce this. **Do not add a write surface.**
- `UsagePoller` (actor) — polls every 2 minutes by default (min 1 s), plus on wake (`AsyncStream<Void>` seam wired to `NSWorkspace.didWakeNotification`) and on manual refresh. Providers fetch concurrently; one failing doesn't block the other. Uses generation counters + a `PollLifecycle` guard so stale results from a cancelled cycle are never applied. Hidden providers are skipped entirely.
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
