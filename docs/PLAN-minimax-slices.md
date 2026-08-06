# Slices: MiniMax token-plan usage in AIUsageBar

Vertical (tracer-bullet) breakdown of `docs/PLAN-minimax.md`. Each slice is a
thin end-to-end path through every integration layer; the parent plan's
horizontal phases are restructured so every slice is demoable on its own.

User stories (inferred from the plan):

- **US1** — See MiniMax percent remaining in the menu bar.
- **US2** — See MiniMax 5h and weekly windows with reset countdowns in the dropdown.
- **US3** — Enable/disable MiniMax in Settings (off by default).
- **US4** — When MiniMax is stale, see a recovery callout that points at OpenCode.
- **US5** — Receive a threshold notification when a MiniMax window crosses the threshold.
- **US6** — Manually refresh MiniMax from the dropdown.
- **US7** — App degrades gracefully (last-known usage retained) when MiniMax fetch fails.

---

## Slice 1 — Plumbing + hidden-by-default UI scaffold

- **Type:** AFK
- **Blocked by:** None — can start immediately
- **User stories:** US3

### What to build

Additive type/UI plumbing so MiniMax *exists* in the app shape but cannot yet
fetch anything. Concretely:

- `ProviderID.miniMax` case; walk every compiler-flagged `switch`: `symbol`
  (`Mx`), `notificationDisplayName` ("MiniMax"), `remainingDisplay` /
  `remainingPlaceholder` (two-window like Claude), `dataSourceChain`.
- `ProviderDataSource.minimaxTokenPlanAPI` with `displayName` "MiniMax token
  plan API" and `chainStepName` "MiniMax token plan API (OpenCode key)".
- `MenuBarTitleFormatter.segments`: an absent state returns `nil` for
  `.miniMax` (matches `.openCodeGo` — default-hidden providers don't render a
  placeholder before their first report).
- `SettingsStore`: visibility key `settings.provider.miniMax.visible`, default
  `false`. Wire through `AppSettingsDraft` staged semantics.
- `ProviderStatusViewModel`: row for MiniMax, hidden by default renders `Off`.
- `AppSettingsView` / `AppSettingsDraft`: MiniMax toggle in Providers tab. No
  key field — the disclosure's caption notes the OpenCode key source. Toggling
  on shows `Checking…` until the first real report exists (current behavior
  already covers "no provider" → nothing rendered; if a placeholder provider is
  needed, register one returning `.hidden`).
- `UsageBarShellModel`: no provider implementation is wired yet — the poller
  has nothing to call for MiniMax.

### Acceptance criteria

- [ ] `swift build` clean under Swift 6 strict concurrency.
- [ ] Tests pass: formatter segments for hidden `.miniMax`, settings default
      `false`, `ProviderID` switch exhaustiveness, `dataSourceChain` declaration
      order.
- [ ] Settings › Providers shows the MiniMax row with an `Off` indicator.
- [ ] No provider is registered yet, so the poller has nothing to fetch.

---

## Slice 2 — Parser + credential reader + provider (fixture-backed)

- **Type:** AFK
- **Blocked by:** Slice 1
- **User stories:** US1, US7

### What to build

The full MiniMax read pipeline, exercised end-to-end via fixtures and a fake
transport — no real HTTP yet (lives in Slice 3). All in a new
`Sources/UsageCore/MiniMax.swift` (one-file-per-provider precedent set by
`OpenCodeGo.swift` and `CodexAppServer.swift`).

- Fixtures in `Tests/Fixtures/`:
  - `minimax-token-plan.json` — sanitized live capture with both `general` and
    `video` entries (proves `video` is ignored).
  - `minimax-token-plan-auth-failure.json` — HTTP 200 body with
    `base_resp.status_code == 1004`.
- `MiniMaxTokenPlanParser`:
  - Decode `base_resp` first; `status_code == 1004` → typed auth-failure error;
    other non-zero → parse failure.
  - Select `model_remains` entry with `model_name == "general"`; absent →
    parse failure. Malformed *other* entries must not poison a valid `general`
    entry (use the existing `FailableDecodable` pattern).
  - Map `current_interval_remaining_percent` → `fiveHour.percentRemaining`,
    `end_time` (ms) → `fiveHour.resetsAt`; likewise weekly. Percent clamped
    `0…100`; missing or out-of-range → parse failure.
  - Missing/unparseable reset with valid percent → unknown reset (Fable rule).
- `OpenCodeAuthFileCredentialReader` (or `MiniMaxCredentialReader`):
  - Injectable file URL; default
    `${XDG_DATA_HOME:-~/.local/share}/opencode/auth.json` (empty var counts as
    unset, matching `CLAUDE_CONFIG_DIR`).
  - Returns key string or `.credentialUnavailable`-shaped verdict per failure
    table. `mode` accepted and ignored. Strictly read-only — no write API.
- `MiniMaxUsageProvider` implementing `UsageProvider` with `fetchReport` as
  the real entry point and `fetch` expressed through it (parity with the
  three existing providers).
- Failure mapping per the plan's table.
- `docs/endpoints.md`: record the endpoint contract + evidence.

### Acceptance criteria

- [ ] Parser tests pass: happy path from fixture, video-only response fails,
      1004 body maps to auth failure, epoch-ms conversion, malformed sibling
      entry tolerated, percent-out-of-range rejected.
- [ ] Credential reader tests pass: present, absent, malformed JSON, entry
      missing, empty key, `type != "api"` still uses the key.
- [ ] `mode` is accepted but ignored (file reads can't prompt).
- [ ] No write API on the credential reader (test posture enforced — same
      invariant `CredentialStore` pins).
- [ ] Provider tests pass with fake transport + fake credential reader: fresh
      path, each stale mapping, previous-usage preservation, single-step chain
      contents, single-step chain-padding behavior, and the
      step-failure-equals-surfaced-reason invariant (which holds only because
      the chain has one step — pin explicitly against the surfaced reason).
- [ ] Fixtures are sanitized; no real key in version control.
- [ ] `swift build` clean; full suite executes via `scripts/run-swift-tests`.

---

## Slice 3 — Real HTTP transport + shell wiring + dropdown + status chain UI + recovery callouts + threshold notifications

- **Type:** AFK
- **Blocked by:** Slice 2
- **User stories:** US1, US2, US4, US5

### What to build

The provider goes live in the app, and the UI surfaces specific to MiniMax
land. Each item here is small but every layer is touched, so the slice is
demoable as "the menu bar shows live MiniMax data with full dropdown and
status UI".

- `MiniMaxUsageProvider` wired to the shared `HTTPTransport`. No User-Agent
  games, no cookies, no redirect concerns beyond the transport's defaults
  (plain API-key endpoint, not Cloudflare-fronted claude.ai).
- `UsageBarShellModel.live()`: construct the provider with the real transport,
  real credential reader at the default path, and system clock; add to the
  poller's provider set. No process lifecycle — `stop()`/`shutdown()` need
  nothing new from this provider.
- `DropdownViewModel`: MiniMax section with 5h and weekly rows + countdowns.
  No provider-specific guidance rows (unlike OpenCode Go).
- `ProviderStatusViewModel`:
  - Chain rendering: single-step `[.minimaxTokenPlanAPI]`, with per-reason
    failure phrasing chosen per *source* (an API endpoint *can* legitimately
    say `Network error`, unlike the statusline cache).
  - Recovery callouts per the plan: `.credentialUnavailable` →
    "No MiniMax key found. Sign in to the MiniMax provider in OpenCode
    (`opencode auth login`) — AIUsageBar borrows that key read-only —
    then choose Refresh Now from the menu bar.";
    `.tokenExpired` → "The MiniMax key was rejected. Re-authenticate the
    MiniMax provider in OpenCode, then choose Refresh Now from the menu
    bar."; `.networkError` / `.parseFailure` →
    generic phrasing consistent with the other providers.
  - Auto-expand-when-stale already generalizes — verify.
- `MenuBarTitleFormatter`: four-visible-providers two-row partition test (the
  algorithm is general; existing tests only pin up to three).
- `ThresholdNotifier` test: fires for a MiniMax window (proves the generic
  path picks it up).
- Settings staged-on preview invariant: staged-on drops retained state, source,
  chain, and last-updated (the existing `providerStatusViewModel(stagedVisibility:)`
  contract; pin a test if not already).

### Acceptance criteria

- [ ] `swift build` clean; `scripts/run-swift-tests` actually executes and
      passes.
- [ ] Dropdown tests pass for MiniMax 5h + weekly rows + countdowns.
- [ ] Status view model tests pass: chain rendering, per-reason phrasing,
      recovery callouts per stale reason, auto-expand-stale.
- [ ] Menu bar formatter test: four visible providers → at most two rows,
      contiguous-segment partition invariant preserved.
- [ ] ThresholdNotifier test fires for a MiniMax window.
- [ ] Staged-on settings preview drops retained state for MiniMax.
- [ ] `swift test --enable-swift-testing` genuinely executes the suites.

---

## Slice 4 — Bundle, code signing, manual smoke verification

- **Type:** HITL
- **Blocked by:** Slice 3
- **User stories:** US1, US2, US3, US4, US5, US6, US7

### What to build

- `scripts/bundle.sh` and `codesign -dvvv AIUsageBar.app` per repo signing
  rules. Verify `Signature=adhoc` is absent and a `TeamIdentifier` is set;
  reject the ad-hoc fallback on a machine with a valid Apple Development
  identity.
- Manual UI verification (the only HITL portion of this work):
  - Provider is `Off` by default.
  - Enable → `Checking…` → `Live · MiniMax token plan API · updated N s ago`.
  - Menu bar shows `Mx nn/nn` fresh; `~Mx nn/nn` when stale.
  - Dropdown 5h and weekly rows show countdowns matching `end_time` /
    `weekly_end_time` (modulo clock skew — confirm visually).
  - Threshold notification fires when crossing the configured threshold
    (verify via a temporary low threshold if needed; restore default).
  - Rename `~/.local/share/opencode/auth.json` → menu bar degrades to greyed
    stale `.credentialUnavailable` with the recovery callout shown in
    Settings › Providers.
  - Restore `auth.json` → next interactive Refresh restores `Live`.
  - Manual Refresh (US6) toggles from stale → fresh without a poll cycle.

### Acceptance criteria

- [ ] `scripts/bundle.sh` succeeds; bundle has a valid code signature with
      `TeamIdentifier` set (no `Signature=adhoc`).
- [ ] All Phase 6 manual checks above pass on a relaunched login app.
- [ ] Full test suite (`scripts/run-swift-tests`) still passes after the
      bundle step.
- [ ] No real key, cookie, or token is logged, persisted, or surfaced in any
      UI surface.

---

## Mapping to the parent plan's phases

For traceability, the slices consume plan phases as follows. The phases are
*not* the slice boundaries; each slice pulls from multiple phases.

| Plan phase | Folded into |
|---|---|
| Phase 0 — Contract capture | Slice 2 (fixtures) + Slice 2 (endpoints.md) |
| Phase 1 — Domain plumbing | Slice 1 |
| Phase 2 — Parser | Slice 2 |
| Phase 3 — Credential reader | Slice 2 |
| Phase 4 — Provider | Slices 2 (fixture-backed) + 3 (real transport) |
| Phase 5 — Status view model + app wiring | Slice 3 |
| Phase 6 — Validation | Slice 4 |