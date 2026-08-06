# Automated UI Test Harness Plan — AIUsageBar

## Goal

Automate verification of **SwiftUI wiring and presentation** without re-testing pure domain logic. Nearly every string, bar fraction, tone, and chain phrase is already covered by UsageCore unit tests. The harness targets what those tests cannot catch: wrong bindings, missing rows, tab chrome, OK/Cancel staging, accessibility trees, and layout drift.

## Current baseline

| Layer | Status |
|---|---|
| Pure VMs / formatters (`DropdownViewModel`, `ProviderStatusViewModel`, `MenuBarTitleFormatter`, `AppSettingsDraft`, …) | ~487 Swift Testing tests — keep as source of truth |
| Shell + adapters (`UsageBarShellModel`, notifications, launch-at-login, termination) | Covered with fakes in `AIUsageBarAppTests` |
| Hosted SwiftUI views | **None** |
| Snapshots | Design PNGs only (`docs/screenshots/settings-redesign/`) |
| MenuBarExtra / bundled-app automation | Explicitly manual (`docs/phase-6-verification.md`) |

**Constraint:** pure SwiftPM, no `.xcodeproj`, no external deps, Swift 6 strict concurrency, `LSUIElement` agent app, label is a template `NSImage`.

---

## Architecture: four layers

```
L0  Pure view models          (existing — expand only when UI decisions move)
L1  Hosted SwiftUI + AX       (primary new harness)
L2  Snapshot tests            (layout/style regression)
L3  Bundled-app smoke         (process + optional AX attach)
L4  Full MenuBarExtra XCUITest (deferred — flaky, low ROI)
```

Never call `.live()` in UI tests. Always inject fakes (same pattern as `UsageBarShellModelTests`).

---

## L1 — Hosted SwiftUI unit tests (Phase 1, highest ROI)

### Approach

Host root views in `NSHostingView` on the main actor, seed a fake `UsageBarShellModel`, assert via the **accessibility tree** (and a thin query helper). Prefer AX over ViewInspector to avoid a dependency and to exercise real accessibility labels already on Settings controls.

### Package / code changes (minimal)

1. **Test host helpers** in `Tests/AIUsageBarAppTests/Support/`:
   - `UITestHost` — creates `NSHostingView(rootView:)`, sizes to production constants (dropdown 320, Settings 500), forces layout.
   - `AXQuery` — walk `NSAccessibility` children by identifier/label/role; `exists`, `value`, `press`, `setValue`.
   - `shellModel(...)` factory (extract/share from existing shell tests).
   - Fixture builders: `AppState` matrices (fresh/stale/hidden/checking × providers × windows).

2. **Accessibility completeness** (product code, small):
   - Add stable `.accessibilityIdentifier` (not only labels) on: Refresh now, Quit, Settings gear, provider visibility toggles, poll-interval picker, threshold stepper, OK/Cancel, tab labels, each progress bar, workspace field.
   - Menu bar: expose a **custom AX value** on the label image mirroring segment text (e.g. `Cl 62/81 | Cx 90`) so L1/L3 can assert without OCR. Keep visual rendering unchanged.

3. **Private nested views:** do **not** open them for import. Test only through:
   - `MenuBarContentView(model:)`
   - `AppSettingsView(model:)`
   - `MenuBarLabelView(segments:)` (already partially covered via `MenuBarLabelImage`)

### Test suites to add

| Suite | Asserts |
|---|---|
| `MenuBarContentViewTests` | Provider rows match `dropdownViewModel`; window rows present/absent (Codex no 5h, Go monthly, Claude Fable); stale greying + caption text; Refresh invokes controller; Settings opener called; last-updated caption; empty/all-hidden still renders footer |
| `AppSettingsViewGeneralTests` | Poll picker options; launch-at-login toggle stages draft; error text when manager reports failure; Cancel discards; OK applies + launch-at-login failure keeps draft synced and stays on General |
| `AppSettingsViewProvidersTests` | Four provider cards; Off / Live / Stale / Checking… lines; disclosure expand/collapse + auto-expand stale; chain step count/order/phrases; recovery callout only while stale; Go workspace field only when Go visible/expanded; staged-on provider shows Checking… without retained green “Used” |
| `AppSettingsViewNotificationsTests` | Threshold stepper bounds; caption visible |
| `MenuBarLabelViewTests` | Empty → “AI Usage” text path; non-empty → image path; AX value matches formatter (after identifier work) |
| `SettingsWiringTests` | Tab order/titles; footer actions; draft isolation across tabs |

### Fixture matrix (parameterized `@Test`)

Minimum combinatorial coverage (not full cartesian):

- Visibility: Claude+Codex; +Go; +MiniMax; all four; all hidden
- Freshness: fresh; stale+last; stale-nil; checking (visible, never polled)
- Stale reasons with distinct copy: `sessionExpired`, `workspaceSelectionRequired`, `tokenExpired`, `credentialUnavailable`
- Windows: Fable on/off; Go monthly present/`--`
- Launch-at-login: enabled / requiresApproval / updateFailed

### How to run

Same as today: `scripts/run-swift-tests`. No new runner. All L1 tests stay in `AIUsageBarAppTests`, `@MainActor`, Swift Testing.

### Out of scope for L1

Keychain prompts, real network, Codex helper spawn, Chrome cookies, notification permission sheets, actual MenuBarExtra status item.

---

## L2 — Snapshot tests (Phase 2)

### Approach

After L1 is green, add **image snapshots** of hosted views at fixed size, light + dark appearance, using a tiny in-repo snapshot helper (no third-party package unless you later choose one).

### Targets (align to existing design oracles)

| Snapshot | Oracle |
|---|---|
| Settings › General | `docs/screenshots/settings-redesign/` |
| Settings › Providers (live) | same |
| Settings › Providers (stale + expanded chain) | same |
| Settings › Notifications | same |
| Dropdown: 2-provider fresh | new baseline |
| Dropdown: stale Go workspace + MiniMax | new baseline |
| Menu bar image: 1 / 2 / 3 / 4 provider layouts | extend `MenuBarLabelImageTests` |

### Rules

- Inject fixed `now`, `calendar`, `locale` (already supported).
- Record baselines under `Tests/AIUsageBarAppTests/Snapshots/` (checked in).
- Failure = image diff path printed; update via explicit `UPDATE_SNAPSHOTS=1` env (never auto-update).
- Tolerate 0–2% pixel noise if needed for font smoothing; prefer exact match on template menu-bar images.

### Optional dependency decision

Prefer **zero deps** first (render `NSHostingView` → `NSBitmapImageRep` → PNG compare). Only add `swift-snapshot-testing` if the in-house helper becomes a maintenance burden — that requires a product decision (first external package).

---

## L3 — Bundled-app smoke (Phase 3)

### Approach

Shell script + optional small Swift driver, run **after** `scripts/bundle.sh`:

1. Quit any running instance (`make stop` pattern).
2. Launch signed `AIUsageBar.app` with a **test launch argument** (e.g. `--ui-smoke`) that:
   - Skips `.live()` providers; uses in-memory fixtures
   - Disables Keychain/Chrome/helper paths entirely
   - Exits 0 after N seconds if shell started and settings scene can be constructed
   Or simpler: no app changes — just assert process stays alive for 5s and `codesign`/plist checks (already in bundle verify).

**Recommended split:**

| Smoke | Mechanism |
|---|---|
| Bundle integrity | Existing `scripts/bundle.sh --verify` |
| Process launch | `open` + poll `pgrep` + clean quit via AppleScript/AX Quit if possible |
| Settings open | Optional: `osascript` or `swift` AX client sending ⌘, and checking window title |
| Menu bar label | Only if L1 added AX value **and** status item is findable; otherwise skip |

### New script

`scripts/ui-smoke` + `Tests/Scripts/ui-smoke-test.sh` following existing script-test patterns.

**Must not:** touch real Keychain, spawn Codex helper, or require Chrome session.

---

## L4 — Full MenuBarExtra XCUITest (deferred)

Do **not** build this until L1–L3 leave residual gaps.

Blockers: no Xcode project, `LSUIElement`, image-based label, flaky status-item hit testing. If ever needed:

- Generate a thin Xcode project solely for UI tests.
- Target only: open extra → Refresh → open Settings → Quit.
- Run only on a dedicated local agent, never as a required gate until flake rate is measured.

---

## Implementation phases

### Phase 0 — Prep

Inventory AX labels vs gaps; add identifiers; extract shared fixtures; document harness conventions.

Detailed plan: [`docs/ui-test-harness-phase-0.md`](ui-test-harness-phase-0.md).

### Phase 1 — L1 hosted views

1. `UITestHost` + `AXQuery`
2. `MenuBarContentViewTests` (fresh + stale matrices)
3. `AppSettingsView*Tests` (General / Providers / Notifications + OK/Cancel)
4. Menu bar AX value + `MenuBarLabelViewTests`
5. Wire into `scripts/run-swift-tests` (automatic via target membership)

**Exit criteria:** all Settings tabs and dropdown footers asserted via AX; staged visibility Checking… behavior covered at view layer; no flakiness on two local runs.

### Phase 2 — L2 snapshots

1. PNG render helper
2. Baselines for Settings (4 states) + dropdown (2 states) + menu bar layouts
3. Dark mode pair for Settings Providers stale

**Exit criteria:** intentional padding/font change fails local test; update path documented.

### Phase 3 — L3 smoke

1. `scripts/ui-smoke`
2. Optional `--ui-smoke` fixture mode **only if** plain launch is too environment-dependent
3. Makefile target `ui-smoke`

**Exit criteria:** `make bundle && make ui-smoke` green on a clean machine without Claude/Codex credentials.

### Phase 4 — Harden & gate (ongoing)

- Fold critical cases from `docs/acceptance.md` that are UI-visible into L1/L2.
- Keep true system interactions (login item approval, notification permission, Wi‑Fi off, Keychain Always Allow) on the **manual** checklist.
- Revisit L4 only if production bugs escape L1–L3 in the menu extra chrome itself.

---

## What stays unit-tested (do not duplicate in UI harness)

- Parsers, providers, poller generations, threshold notifier math
- `DropdownViewModel` / `ProviderStatusViewModel` string construction
- `AppSettingsDraft` capture/apply pure logic
- `MenuBarTitleFormatter` partition algorithm
- Codex helper process lifecycle / termination
- Credential read-only surface

UI tests **consume** fixed `AppState` + recording controllers; they do not fetch usage.

---

## Failure modes the harness is designed to catch

| Bug class | Layer |
|---|---|
| Forgot to render Fable / monthly row | L1 |
| Settings binds live store instead of draft | L1 |
| OK applies General but not Providers | L1 |
| Staged-on MiniMax shows stale retained chain | L1 |
| Disclosure chevron not toggled / wrong a11y | L1 |
| Progress bar missing / wrong fraction wiring | L1 (+ L2) |
| Footer/button layout break, dark mode contrast | L2 |
| Bundle won’t launch / wrong plist | L3 |
| Menu bar partition string wrong | L0 (existing) + label AX in L1 |

---

## Explicit non-goals

- Automating Keychain or Chrome Safe Storage dialogs
- Spawning real Codex `app-server` from UI tests
- OCR on the menu bar image
- Pixel-perfect match to production blur/vibrancy of the system menu extra chrome
- Replacing `docs/acceptance.md` entirely
- Adding write APIs or relaxing read-only credential rules for testability

---

## Success metrics

1. **Coverage:** every user-visible screen in AGENTS.md has ≥1 L1 test; every Settings redesign screenshot has an L2 twin.
2. **Speed:** full L1+L2 suite < 30s on a dev Mac (hosted views, no sleep/poll loops).
3. **Stability:** zero retries; no wall-clock waits except L3’s bounded process poll.
4. **Safety:** UI test target cannot call `.live()` paths that touch Keychain (enforce with test-only factory + code review).
5. **Docs:** `acceptance.md` items marked Automated (L1/L2/L3) vs Manual.

---

## Suggested first PR slice (after Phase 0)

Smallest vertical slice that proves the harness:

1. AX identifiers on dropdown Refresh / Settings / Quit
2. `UITestHost` + `AXQuery`
3. One `MenuBarContentView` test: two fresh providers → row names + Refresh records call
4. One `AppSettingsView` test: open Providers → Claude status line from seeded state → Cancel

That validates hosting + AX + fake shell before investing in the full matrix and snapshots.

---

## File map (proposed)

```
Sources/AIUsageBarApp/
  … existing views (+ accessibilityIdentifier additions)

Tests/AIUsageBarAppTests/
  Support/
    UITestHost.swift
    AXQuery.swift
    UITestFixtures.swift          # AppState / shell factories
    SnapshotSupport.swift         # Phase 2
  MenuBarContentViewTests.swift
  AppSettingsViewTests.swift      # or split per tab
  MenuBarLabelViewTests.swift
  Snapshots/                      # Phase 2 PNGs

scripts/ui-smoke                   # Phase 3
Tests/Scripts/ui-smoke-test.sh
docs/ui-test-harness.md            # this file
docs/ui-test-harness-phase-0.md    # Phase 0 detail
```
