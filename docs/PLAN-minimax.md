# Plan: MiniMax token-plan usage in AIUsageBar

Add MiniMax (coding/token plan) as a fourth provider, showing percent remaining
for its 5-hour rolling window and weekly window, following the same read-only,
degrade-to-stale architecture as the existing providers.

## Evidence (captured live, 2026-08-06)

All of this was verified against the real endpoint on this machine using the
existing OpenCode-stored credential; do **not** trust secondhand descriptions of
this API — every third-party writeup examined (ClawHub skill, token_manager doc,
GitHub issue MiniMax-AI/MiniMax-M2#88) describes a schema that does not match
the live response.

### Endpoint

```
GET https://api.minimax.io/v1/token_plan/remains
Authorization: Bearer <subscription key>
Content-Type: application/json
```

- `www.minimax.io` serves the identical payload; use `api.minimax.io`.
- This is the *documented, API-key-authenticated* endpoint. The other endpoint
  floating around (`/v1/api/openplatform/coding_plan/remains`) requires a
  browser cookie session (status 1004 with an API key — MiniMax-M2#88) and is
  **not** part of this plan.
- The key must be the **subscription key** tied to the token plan. The one in
  OpenCode's auth file is exactly that (it authenticates this endpoint today).
- China-region hosts (`api.minimaxi.com`) are a non-goal; no evidence, no user.

### Live response shape (sanitized capture, this machine)

```json
{
  "model_remains": [
    {
      "model_name": "general",
      "start_time": 1786028400000,
      "end_time": 1786046400000,
      "remains_time": 17785246,
      "current_interval_total_count": 0,
      "current_interval_usage_count": 0,
      "current_interval_status": 1,
      "current_interval_remaining_percent": 100,
      "weekly_start_time": 1785715200000,
      "weekly_end_time": 1786320000000,
      "weekly_remains_time": 291385246,
      "current_weekly_total_count": 0,
      "current_weekly_usage_count": 0,
      "current_weekly_status": 1,
      "current_weekly_remaining_percent": 99
    },
    {
      "model_name": "video",
      "...": "24-hour interval; separate video quota — ignored by this app"
    }
  ],
  "base_resp": { "status_code": 0, "status_msg": "success" }
}
```

Semantics pinned by the capture:

- **`model_remains` is an array keyed by `model_name`.** The coding/token plan
  is the `"general"` entry (its interval is exactly 5 h: `end_time −
  start_time = 18,000,000 ms`; its weekly window is exactly 7 days). The
  `"video"` entry is a separate daily video quota — out of scope.
- **`current_interval_remaining_percent` / `current_weekly_remaining_percent`
  are percent *remaining*** — the exact number the app displays. Use them
  directly. Do not derive percent from the `*_count` fields: on the live
  general entry both totals are `0` (unpopulated) while the percent fields are
  authoritative (weekly showed `99` with counts all zero).
- **All times are epoch milliseconds.** `end_time` is the 5-hour reset instant,
  `weekly_end_time` the weekly reset. `remains_time` / `weekly_remains_time`
  are millisecond countdowns to those instants (redundant; prefer the absolute
  times, which need no response-time clock).
- **Auth failures are HTTP 200** with `base_resp.status_code == 1004`
  ("login fail…"). A missing header returns the same. HTTP status alone cannot
  distinguish success from auth failure — the body must be inspected.
- `current_interval_status` / `current_weekly_status` were `1` on the healthy
  capture; semantics unknown. Ignore them until evidence says otherwise (no
  speculative gating, per repo convention).

### Credential source (this machine)

`~/.local/share/opencode/auth.json` → key `"minimax-coding-plan"` →
`{ "type": "api", "key": "sk-…" (125 chars, opaque, not a JWT) }`.

- The key is opaque (`sk-` prefix, no JWT segments), so **no local expiry
  pre-check is possible** — unlike Codex, every fetch goes to the network and
  auth failure is detected from `base_resp`.
- Read-only file read; file reads can never prompt, so `CredentialAccessMode`
  is accepted and ignored (same posture as `ClaudeCredentialsFileStore`).
- OpenCode resolves its data dir as `${XDG_DATA_HOME:-~/.local/share}/opencode`;
  honor `XDG_DATA_HOME` the same way the Claude cache honors `XDG_CACHE_HOME`.
- Non-goals without new evidence: reading `~/.claude/settings.json` env vars
  (MiniMax-via-Claude-Code setups), env-var key sources, keychain, browser
  cookies for platform.minimax.io. Single evidenced source only.

## Product decisions

- **ProviderID `.miniMax`**, menu bar symbol **`Mx`**, display name "MiniMax".
- **Hidden by default** (like OpenCode Go): most users don't have a MiniMax
  plan, and its credential source (OpenCode auth file) is niche. Enabled from
  Settings › Providers.
- **Windows:** required `fiveHour` + `weekly`, both populated from the
  `general` entry. No monthly, no Fable. Both windows therefore participate in
  menu bar title, tone, and threshold notifications automatically — no changes
  to `tone(for:)` or `ThresholdNotifier` are needed.
- Menu bar renders `Mx 100/99` fresh, `~` prefix stale, exactly per existing
  formatter rules. With four visible providers the existing contiguous-segment
  row partitioning must still hold to two rows — verify with new formatter
  tests rather than assuming (the algorithm is general, the tests currently
  only pin up to three).
- **Retrieval chain:** a single step, `.minimaxTokenPlanAPI`
  (`displayName` "MiniMax token plan API", `chainStepName` "MiniMax token plan
  API (OpenCode key)"). `ProviderID.dataSourceChain` = `[.minimaxTokenPlanAPI]`.
- **Recovery callout** (shown while stale, per reason):
  - `.credentialUnavailable` → "No MiniMax key found. Sign in to the
    MiniMax provider in OpenCode (`opencode auth login`) — AIUsageBar borrows
    that key read-only."
  - `.tokenExpired` → "The MiniMax key was rejected. Re-authenticate the
    MiniMax provider in OpenCode."
  - `.networkError` / `.parseFailure` → generic phrasing consistent with the
    other providers.

## Failure mapping

| Condition | StaleReason |
|---|---|
| auth.json absent, unreadable, no `minimax-coding-plan` entry, entry lacks a non-empty `key` | `.credentialUnavailable` |
| HTTP 200 + `base_resp.status_code == 1004` | `.tokenExpired` (key rejected — closest existing reason; no new enum case) |
| HTTP 200 + other non-zero `status_code`, missing `base_resp`, no `general` entry, missing/percent fields out of `0…100`, undecodable body | `.parseFailure` |
| Non-2xx HTTP, transport error, timeout | `.networkError` |

As everywhere else: the provider never throws upward, preserves last-known
usage on failure, and reports the attempted step chain with the failure reason
display-only inside the step.

## Implementation phases (TDD, red–green–refactor throughout)

### Phase 0 — Contract capture (mostly done above)

1. Add sanitized fixture `Tests/Fixtures/minimax-token-plan.json` from the live
   capture (both `general` and `video` entries, so tests prove `video` is
   ignored), plus an auth-failure fixture body (`status_code` 1004).
2. Record the endpoint contract + evidence in `docs/endpoints.md` (URL, auth,
   key source and path, epoch-ms semantics, percent-remaining semantics,
   200-with-1004 auth failure, `www`/`api` host equivalence, rejected
   alternatives and why).

### Phase 1 — Domain plumbing (`Sources/UsageCore/UsageCore.swift` and friends)

1. Add `ProviderID.miniMax` and walk every `switch` over `ProviderID` the
   compiler flags: `symbol` (`Mx`), `notificationDisplayName` ("MiniMax"),
   `remainingDisplay`/`remainingPlaceholder` (two-window display like Claude),
   `dataSourceChain`.
2. `MenuBarTitleFormatter.segments`: an absent state must return `nil` for
   `.miniMax` exactly as it does for `.openCodeGo` (default-hidden providers
   don't render a placeholder before their first report).
3. `ProviderDataSource` / `ProviderDataSourceStep`: add `.minimaxTokenPlanAPI`
   with display/chain names.
4. `SettingsStore`: visibility key `settings.provider.miniMax.visible` (match
    the existing key naming), **default false**.
5. Tests: formatter segments/rows with four visible providers (two-row
   partition invariant), default-hidden behavior, settings default, chain
   declaration order.

### Phase 2 — Parser (fixture-backed)

`MiniMaxTokenPlanParser` in a new `Sources/UsageCore/MiniMax.swift` (follow the
`OpenCodeGo.swift` precedent of one file per provider subsystem):

- Decode `base_resp` first; `status_code == 1004` → typed auth-failure error;
  other non-zero → parse failure.
- Select `model_remains` entry with `model_name == "general"`; absent →
  parse failure. Malformed *other* entries must not poison a valid `general`
  entry (use the existing `FailableDecodable` pattern).
- Map `current_interval_remaining_percent` → `fiveHour.percentRemaining`,
  `end_time` (ms) → `fiveHour.resetsAt`; likewise weekly. Percent must be
  clamped/validated `0…100`; missing or absent percent → parse failure (unlike
  Claude, there is no evidenced "window lapses to null" behavior — do not
  speculate one).
- A missing/unparseable reset time with a valid percent yields an unknown
  reset rather than dropping the window (consistent with the Fable rule).
- Tests: happy path from fixture, video-only response fails, 1004 body maps to
  auth failure, epoch-ms conversion, malformed sibling entry tolerated,
  percent-out-of-range rejected.

### Phase 3 — Credential reader

`OpenCodeAuthFileCredentialReader` (or `MiniMaxCredentialReader`) in
`MiniMax.swift`:

- Injectable file URL; production default
  `${XDG_DATA_HOME:-~/.local/share}/opencode/auth.json` (empty var counts as
  unset, matching the `CLAUDE_CONFIG_DIR` rule).
- Returns the key string or a `.credentialUnavailable`-shaped verdict per the
  failure table. `mode` accepted and ignored. Strictly read-only — no write
  surface, ever; add the same "no write API" test posture as `CredentialStore`.
- The key is never logged, persisted, or carried in any report/label.
- Tests via temp-dir fixture files: present, absent, malformed JSON, entry
  missing, empty key, `type != "api"` (still use the key — `type` is
  OpenCode's bookkeeping; only require a non-empty `key`).

### Phase 4 — Provider

`MiniMaxUsageProvider` implementing `UsageProvider` with `fetchReport` as the
real entry point (and `fetch` expressed through it, like the other three):

- Read credential → on failure, stale `.credentialUnavailable`, chain
  `[failed]`, previous usage preserved.
- One `GET` via the shared `HTTPTransport` with the Bearer header. No
  User-Agent games, no cookies, no redirect concerns beyond the transport's
  defaults (this is a plain API-key endpoint, not Cloudflare-fronted claude.ai).
- Map parser/transport outcomes per the failure table; success reports source
  `.minimaxTokenPlanAPI` and `.fresh(usage, asOf: now)` from the injected
  clock.
- Tests with a fake transport + fake credential reader: fresh path, each stale
  mapping, previous-usage preservation, chain contents, single-step
  chain padding by the view model, and the pinned invariant that a step's
  failure reason equals the surfaced reason here only because the chain has
  one step (write the test against the surfaced reason explicitly).

### Phase 5 — Status view model + app wiring

1. `ProviderStatusViewModel`: row for MiniMax (`Live · MiniMax token plan API ·
   updated N min ago`, `Checking…` before first report, `Off` when hidden),
   single-step chain rendering, per-source failure phrasing (an API endpoint
   *can* legitimately say `Network error`, unlike the statusline cache), and
   the recovery callouts above. Auto-expand-when-stale already generalizes.
2. `AppSettingsView` / `AppSettingsDraft`: MiniMax visibility toggle in the
   Providers tab with its status row and disclosure. **No key field** — the
   pane never exposes secrets; the disclosure's caption points at OpenCode as
   the key source.
3. `UsageBarShellModel.live()`: construct the provider with the real
   transport, credential reader at the default path, and system clock; add to
   the poller's provider set. No process lifecycle — `stop()`/`shutdown()`
   need nothing new from this provider.
4. `DropdownViewModel`: MiniMax section with 5 h and weekly rows +
   countdowns; no provider-specific guidance rows needed (unlike OpenCode Go).
5. Tests: shell-model wiring, dropdown rows, settings staging (staged-on
   preview drops retained state, same as the existing invariant test),
   threshold notification fires for a MiniMax window (proves the generic path
   picked it up).

### Phase 6 — Validation

- `scripts/run-swift-tests` (full suite must actually execute; strict-
  concurrency-clean `swift build`).
- `scripts/bundle.sh` + `codesign -dvvv` per repo signing rules; relaunch and
  manually verify: provider Off by default → enable → `Checking…` → live row,
  menu bar `Mx nn/nn`, dropdown countdowns match `end_time`/`weekly_end_time`,
  and a renamed auth.json degrades to stale `.credentialUnavailable` with the
  recovery callout, restoring on the next interactive refresh after the file
  returns.

## Risks / open questions

- **Percent granularity:** the API returns integer percent; nothing to round,
  but confirm during Phase 6 that a partially-consumed window reports a
  changing integer (the capture was taken nearly idle: 100/99).
- **`general` vs future model buckets:** if MiniMax adds per-model coding
  buckets (Plus/Ultra plans reportedly split them), the `general` selection
  rule may need revisiting — only with a new capture as evidence.
- **Key rotation:** OpenCode rewrites auth.json atomically on re-auth; the
  reader re-reads per fetch, so rotation self-heals on the next poll.
- **Four-provider menu bar width:** if two rows of two segments prove too wide
  in practice, that's a product decision to revisit (e.g. drop to `Mx 99`
  weekly-only) — not something to pre-build.
