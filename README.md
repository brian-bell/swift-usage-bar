# AIUsageBar

A native macOS menu bar app that shows how much of your **Claude** and **ChatGPT/Codex** subscription rate limits you have left — always visible, at a glance.

The menu bar shows percent **remaining** (fuel-gauge semantics) for each provider's 5-hour and weekly windows as a compact two-line stack, e.g. `Cl 62/81` over `Cx 72/90` (`Cl` Claude, `Cx` Codex, `fiveHour/weekly`). The dropdown adds progress bars, exact percentages, reset countdowns, a Refresh-now button with last-updated time, and inline settings.

Access is strictly **read-only**: the app borrows state your CLIs already maintain. It never writes to the Keychain, never refreshes OAuth tokens, and degrades to a greyed "stale" display when data is unavailable.

## Features

- All four rate-limit windows visible in the menu bar at all times; stale values marked with `~`, missing data as `--/--`
- Dropdown with per-window progress bars and reset countdowns ("resets in 2h 14m", or weekday + time when more than a day out)
- Polls every 2 minutes (configurable: 1/2/5/10 min), plus on Mac wake and on manual refresh
- Notification when a window drops below a threshold (default 20%, configurable) — fired once per window per reset cycle
- Per-provider show/hide toggles, launch-at-login, all settings inline in the dropdown
- Menu-bar-only app (`LSUIElement`): no Dock icon

## How it gets the data

| Provider | Source |
|---|---|
| Claude | Background polls read only the statusline JSON cached locally by `scripts/claude-statusline-cache`. Clicking **Refresh now** additionally reads Claude Code's Keychain credential (read-only) and calls `GET https://api.anthropic.com/api/oauth/usage`, falling back to the cache if the API is unavailable |
| Codex | Codex CLI's Keychain credential (read-only) → `GET https://chatgpt.com/backend-api/wham/usage` |

The Claude OAuth API (and the Keychain read it requires) is reserved for manual refreshes so background polls never trigger a Keychain prompt or spend API calls. The app never refreshes OAuth tokens, so a manual refresh depends on Claude Code keeping its token fresh; between refreshes (or on a machine with no recent Claude Code activity) the row relies on the statusline cache, then degrades to a greyed stale display.

See `docs/endpoints.md` for the discovered contracts and evidence.

## Requirements

- macOS 14+
- Swift 6 toolchain to build (developed with CommandLineTools-only Swift 6.3)
- [Claude Code](https://claude.com/claude-code) logged in, with the statusline cache wrapper below configured for automatic Claude updates (manual refreshes work without it)
- [Codex CLI](https://github.com/openai/codex) logged in via ChatGPT, for Codex numbers

## Install

```sh
git clone https://github.com/brian-bell/swift-usage-bar.git
cd swift-usage-bar
./scripts/bundle.sh          # builds, signs (ad-hoc by default), and verifies ./AIUsageBar.app
open AIUsageBar.app
```

To avoid repeated Keychain prompts after every rebuild (see below), sign with a stable
identity instead of ad-hoc:

```sh
CODESIGN_IDENTITY="AIUsageBar Signing" ./scripts/bundle.sh
```

Enable "Launch at login" from the dropdown settings if you want it to persist across restarts (macOS may ask you to approve it in System Settings › Login Items).

On the first manual refresh macOS will ask whether AIUsageBar may read the `Claude Code-credentials` (and `Codex Auth`) Keychain items — click **Always Allow**. If you only click Allow, the prompt returns on a later manual refresh; if you deny, the Claude row falls back to the statusline cache. The Claude credential is only read when you click **Refresh now**, never during background polls.

An ad-hoc signature pins the Keychain grant to the exact binary hash, so **every rebuild re-triggers the prompt**. To make the grant survive rebuilds, sign with a stable code-signing certificate:

1. Create a self-signed cert once in **Keychain Access › Certificate Assistant › Create a Certificate…** — Identity Type *Self-Signed Root*, Certificate Type *Code Signing* (e.g. named `AIUsageBar Signing`). It does not need to be trusted for Gatekeeper; `codesign` only needs its private key.
2. Build with `CODESIGN_IDENTITY="AIUsageBar Signing" ./scripts/bundle.sh`. The signature's designated requirement is then pinned to the certificate rather than the binary hash, so it stays constant across rebuilds.
3. Click **Always Allow** once for each item — the grant now persists until the certificate changes.

### Claude statusline cache setup

Between manual refreshes, Claude usage comes from a local cache written by your Claude Code statusline — without it, the Claude row only updates when you click **Refresh now** (which fetches live from the OAuth usage API, using the cache as its fallback). Run the installer to wire it up:

```sh
scripts/setup-statusline
```

It rewrites `statusLine.command` in `~/.claude/settings.json` (respecting `CLAUDE_CONFIG_DIR`) to run `scripts/claude-statusline-cache`, which tees the statusline JSON to `${XDG_CACHE_HOME:-~/.cache}/ai-usage-bar/claude-status.json` before rendering. With several Claude Code sessions open at once, the wrapper keeps whichever session's rate-limit data is freshest — idle sessions re-rendering stale numbers can't overwrite it. Your existing statusline keeps rendering exactly as before: the previous command is preserved in a passthrough shim at `~/.claude/ai-usage-bar/statusline-passthrough.sh` that the wrapper forwards to (if none was configured, the statusline stays blank). The original `settings.json` is backed up to `settings.json.ai-usage-bar-backup` on first run, and rerunning the script is a no-op. To undo, restore the backup or set `statusLine.command` back to the shim's contents.

If you'd rather configure it by hand: set `statusLine.command` to `scripts/claude-statusline-cache` (override the forwarded binary with `CCSTATUSLINE_BIN`, the cache path with `AI_USAGE_BAR_CLAUDE_STATUS_JSON`). Until the cache exists, the Claude row shows a stale hint.

## Develop

```sh
swift build                        # debug build (clean under Swift 6 strict concurrency)
swift test --enable-swift-testing  # build the Swift Testing suites
scripts/run-swift-tests            # full local harness
scripts/bundle.sh --verify         # verify an existing AIUsageBar.app
```

Note: on a CommandLineTools-only install, `swift test` builds but does not execute the suites (no XCTest runner ships with CLT); executing them requires full Xcode. `scripts/run-swift-tests` adds linkage and smoke checks to compensate.

All logic lives in the `UsageCore` library target and is unit-tested with Swift Testing; `AIUsageBarApp` is a thin SwiftUI shell. See `AGENTS.md` for the architecture tour and `docs/PLAN.md` for the original phased plan.

## License

MIT — see [LICENSE](LICENSE).
