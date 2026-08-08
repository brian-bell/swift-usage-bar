# AGENTS.md

Context for AI coding agents. `CLAUDE.md` is a symlink to this file.

Details live at their source, not here: endpoint/credential contracts and the
evidence behind them in `docs/endpoints.md`, mechanism rationale in doc
comments at the implementing types, behavior in the tests. When this file and
the code disagree, the code and its tests win.

## What this is

**AIUsageBar**: a native macOS menu bar app (SwiftUI `MenuBarExtra`, macOS
14+) showing **percent remaining** for Claude, Codex, OpenCode Go, and
MiniMax. Providers borrow existing local state read-only (Keychain, Chrome
cookies, OpenCode's `auth.json`, a statusline cache file) and degrade to a
greyed "stale" state instead of erroring. Per-provider retrieval order and
fallbacks: `ProviderID.dataSourceChain` in
`Sources/UsageCore/ProviderDataSource.swift` and `docs/endpoints.md`.

## Build, test, run

No Makefile or CI; SwiftPM + shell scripts are the whole build system. Swift 6
strict concurrency must stay clean.

| Command | Purpose |
|---|---|
| `swift build` | Debug build |
| `scripts/run-swift-tests` | Build **and execute** every suite. Use this, not bare `swift test`: a CommandLineTools-only toolchain compiles the suites but silently skips execution, and the hosted UI suite must run in its own process — the script handles both |
| `scripts/bundle.sh` | Release build → `AIUsageBar.app` → codesign → verify (`--verify` checks an existing bundle) |
| `Tests/Scripts/*-test.sh` | Shell tests for the corresponding `scripts/` entries |
| `scripts/setup-statusline` | Wire the statusline cache wrapper into Claude Code settings |
| `scripts/make-signing-cert` | Local signing identity for machines without an Apple Development one |

Signing: when rebuilding the installed app, run plain `scripts/bundle.sh` and
confirm `codesign -dvvv` shows a `TeamIdentifier` and no `Signature=adhoc`.
Identity selection and its keychain-prompt consequences are documented in
`scripts/bundle.sh` and `scripts/make-signing-cert`.

## Layout

- `Sources/UsageCore/` — all logic: domain models, providers, parsers, poller,
  notifier, formatters, view models, settings store. UI-free; every seam is a
  protocol with injectable fakes.
- `Sources/AIUsageBarApp/` — thin SwiftUI shell + system adapters. Views
  contain no logic; they render state and call intents on the shell model.
- `Tests/UsageCoreTests/`, `Tests/AIUsageBarAppTests/` — Swift Testing
  (`@Test`/`#expect`, not XCTest).
- `Tests/Fixtures/` — sanitized captured payloads backing the parsers.
- `scripts/`, `Tests/Scripts/` — shell scripts and their tests.

UI tests are reads-only accessibility checks of hosted roots and must use the
fake shell-model wiring from `Tests/AIUsageBarAppTests/Support/`, never
`UsageBarShellModel.live()`. See `docs/ui-test-harness.md`.

## Hard rules

- **Read-only data access is a product constraint**: no credential writes,
  OAuth/key refresh, or anything that could mutate CLI state (see
  `docs/PLAN.md` non-goals). Sole approved exception: invoking OpenAI's signed
  Codex desktop `app-server` for `initialize` / `initialized` /
  `account/rateLimits/read` — no other RPC.
- Background polls must never present a prompt; only a manual Refresh-now may
  (`CredentialAccessMode` threads this from poller to credential readers).
- **TDD** with Swift Testing; every `UsageCore` behavior has a test.
- Parser and credential-source changes must be backed by a sanitized fixture
  in `Tests/Fixtures/` captured from a real payload. No speculative fallbacks,
  alias keys, extra hosts or regions, or browsers beyond Chrome without a new
  product decision (rejected alternatives are recorded in `docs/endpoints.md`).
- Never commit real credentials or unsanitized captures.
- Feature branches only; never commit or push directly to `main`.
