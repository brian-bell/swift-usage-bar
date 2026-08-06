# UI Test Harness — Phase 0 (Prep)

Parent plan: [`docs/ui-test-harness.md`](ui-test-harness.md).

## Goal

Make Phase 1 (hosted SwiftUI + AX) a pure greenfield of host/query/tests — not blocked by missing identifiers, duplicated fixtures, or undocumented conventions.

Phase 0 **does not** host views, assert accessibility trees, take snapshots, or launch the app bundle. It only prepares seams, identifiers, shared test support, and docs so Phase 1’s first PR can be the vertical slice (one dropdown test + one Settings test).

## Non-goals

- `UITestHost` / `AXQuery` implementation (Phase 1)
- Snapshot infrastructure (Phase 2)
- Bundle smoke scripts (Phase 3)
- Opening private nested Settings subviews for import
- Calling or refactoring `.live()`
- Changing user-visible copy, layout, or behavior (except additive accessibility metadata)
- New SPM dependencies

## Exit criteria

Phase 0 is done when all of the following hold:

1. **Identifier catalog** is written and every catalog entry is applied in product code (or explicitly deferred with reason).
2. **Shared test fixtures** live under `Tests/AIUsageBarAppTests/Support/` and existing app tests still compile/pass after adopting them (or after dual-writing during migration).
3. **Harness conventions** are documented in this file’s “Conventions” section and cross-linked from `AGENTS.md` (short pointer only).
4. **AX inventory** table below is filled with current vs target state (no “unknown” rows for controls Phase 1 will touch).
5. `scripts/run-swift-tests` is green.
6. No Keychain, network, Chrome, or Codex helper paths are introduced.

Estimated effort: about half a day of focused work, one PR.

---

## Workstream A — Accessibility inventory

### A.1 Inventory (Phase 0 applied)

| Control | File | Label | Identifier | Phase 1 need |
|---|---|---|---|---|
| Settings gear | `MenuBarContentView.swift` | `"Settings"` | `menubar.content.settings` | done |
| Refresh now | `MenuBarContentView.swift` | button title | `menubar.content.refresh` | done |
| Quit | `MenuBarContentView.swift` | button title | `menubar.content.quit` | done |
| Last-updated caption | `MenuBarContentView.swift` | text value | `menubar.content.updated` | done |
| Provider row name | `MenuBarContentView.swift` | Text | `menubar.content.provider.{id}` | done |
| Provider stale caption | `MenuBarContentView.swift` | Text | `menubar.content.provider.{id}.stale` | done |
| Window title | `MenuBarContentView.swift` | Text | `…window.{key}` | done |
| Window % | `MenuBarContentView.swift` | Text | `…window.{key}.percent` | done |
| Window countdown | `MenuBarContentView.swift` | Text | `…window.{key}.countdown` | done |
| Progress bar | `MenuBarContentView.swift` | value = percent label | `…window.{key}.bar` | done |
| Menu bar label image | `MenuBarLabel.swift` | `"AI usage"` + AX value | `menubar.label` | done |
| Menu bar empty fallback | `MenuBarLabel.swift` | `"AI Usage"` text / AX value | same `menubar.label` (empty = value `"AI Usage"`; no separate id) | done |
| Settings Cancel / OK | `AppSettingsView.swift` | button titles | `settings.cancel` / `settings.ok` | done |
| Tab panes | `AppSettingsView.swift` | tab titles | `settings.tab.{general\|providers\|notifications}` on pane root | done (Phase 1 may still select by label if TabView hides pane ids) |
| Poll interval picker | `AppSettingsView.swift` | `"Refresh every"` | `settings.general.pollInterval` | done |
| Launch at login toggle | `AppSettingsView.swift` | `"Launch at login"` | `settings.general.launchAtLogin` | done |
| Launch at login error | `AppSettingsView.swift` | Text | `settings.general.launchAtLoginError` | done |
| Provider visibility toggle | `AppSettingsView.swift` | switch | `settings.provider.{id}.toggle` | done |
| Provider status line | `AppSettingsView.swift` | `"{name} status: {text}"` | `settings.provider.{id}.status` | done |
| Disclosure chevron | `AppSettingsView.swift` | `"Show {name} data sources"` + Expanded/Collapsed | `settings.provider.{id}.disclosure` | done |
| Chain step row | `AppSettingsView.swift` | `"Step N, {name}: {stateText}"` | `settings.provider.{id}.chain.{n}` | done |
| Recovery callout | `AppSettingsView.swift` | full text as label | `settings.provider.{id}.callout` | done |
| OpenCode workspace field | `AppSettingsView.swift` | VM-supplied a11y label | `settings.provider.{id}.workspace` | done |
| Threshold stepper | `AppSettingsView.swift` | control | `settings.notifications.threshold` | done |

### A.2 Identifier naming convention

Stable, hierarchical, kebab-case strings. Never include dynamic percent values or ages in the **identifier** (those belong in label/value).

```
menubar.label                         # empty state: same id, value "AI Usage"
menubar.content.refresh
menubar.content.settings
menubar.content.quit
menubar.content.updated
menubar.content.provider.{claude|codex|opencodeGo|minimax}
menubar.content.provider.{id}.stale
menubar.content.provider.{id}.window.{fiveHour|weekly|monthly|fable}
menubar.content.provider.{id}.window.{key}.bar
menubar.content.provider.{id}.window.{key}.percent
menubar.content.provider.{id}.window.{key}.countdown

settings.cancel
settings.ok
settings.tab.general
settings.tab.providers
settings.tab.notifications
settings.general.pollInterval
settings.general.launchAtLogin
settings.general.launchAtLoginError
settings.notifications.threshold
settings.provider.{id}.toggle
settings.provider.{id}.status
settings.provider.{id}.disclosure
settings.provider.{id}.callout
settings.provider.{id}.workspace
settings.provider.{id}.chain.{n}          # 1-based step number
```

Provider id tokens match a fixed map (not `String(describing:)`):

| `ProviderID` | Token |
|---|---|
| `.claude` | `claude` |
| `.codex` | `codex` |
| `.openCodeGo` | `opencodeGo` |
| `.miniMax` | `minimax` |

Centralize tokens in one place so product code and tests cannot drift:

- Prefer a small `enum AccessibilityID` (or `enum UIAccessibilityID`) in the **app target** (`Sources/AIUsageBarApp/AccessibilityID.swift`) with static lets / functions.
- Tests import via `@testable import AIUsageBarApp` and use the same constants — never re-string literals in tests.

### A.3 Menu bar AX value (spec only in Phase 0 if deferred)

Phase 1 needs a non-OCR way to read the label. Phase 0 either implements it or leaves a checked stub decision:

**Decision for Phase 0:** implement the accessibility value now (small, pure, testable without hosting).

- Add `MenuBarLabelImage.accessibilityValue(for: [MenuBarTitleSegment]) -> String` pure function:
  - empty segments → `"AI Usage"` (matches visible fallback)
  - else join `rowLabel` texts with `" | "` in **display row order** (same partition as the image), e.g. `"Cl 62/81 | Cx 90"` or two-row layout still flattened left-to-right top-then-bottom.
- On `MenuBarLabelView` (single combined element; children ignored):
  - `.accessibilityIdentifier(AccessibilityID.menuBarLabel)` — always, including empty
  - `.accessibilityLabel("AI usage")` (short, stable)
  - `.accessibilityValue(MenuBarLabelImage.accessibilityValue(for: segments))`
  - Empty state is **not** a second identifier; Phase 1 reads value `"AI Usage"`
- Unit-test the pure value function in `MenuBarLabelImageTests` (no hosting required) — this is in-scope for Phase 0.

### A.4 Implementation rules for AX edits

- Additive only: identifiers + values; do not remove existing labels that Settings already uses.
- Do not change layout, fonts, or colors.
- Prefer `.accessibilityIdentifier` on the interactive control (Button, Toggle, Picker), not on a wrapper that splits the AX element incorrectly.
- Where `.accessibilityElement(children: .combine)` already exists (status line, chain step, callout), put the identifier on that combined element.
- ProgressView: set identifier on the progress view; expose percent via accessibility value string matching the visible percent label when practical.

### A.5 Deliverables

| Deliverable | Path |
|---|---|
| ID constants | `Sources/AIUsageBarApp/AccessibilityID.swift` |
| AX applied on dropdown + label + settings controls | existing view files |
| Pure label value + unit tests | `MenuBarLabel.swift` + `MenuBarLabelImageTests.swift` |
| Inventory marked done | this doc, section A.1 updated to “done” in the PR description if not edited in-doc |

---

## Workstream B — Shared test fixtures

### B.1 Problem

`UsageBarShellModelTests.swift` privately owns:

- `shellModel(appState:settingsStore:usageController:launchAtLoginManager:)`
- `RecordingUsageController`
- `RecordingLaunchAtLoginManager`
- `claudeUsage` / `codexUsage` / `referenceNow`
- assorted `AppState` setups inline

Phase 1 suites will need the same factory. Duplicating it across files will drift.

### B.2 Target layout

```
Tests/AIUsageBarAppTests/
  Support/
    UITestFixtures.swift       # Phase 0 — factories + recordings + sample usage
    # UITestHost.swift         # Phase 1
    # AXQuery.swift            # Phase 1
  UsageBarShellModelTests.swift   # adopts Support/
  … existing suites …
```

SwiftPM: by default all sources under `Tests/AIUsageBarAppTests/` are compiled into the test target — no `Package.swift` change unless the target uses explicit source lists (it does not today).

### B.3 What to extract in Phase 0

**Must extract:**

```swift
// UITestFixtures.swift (names indicative)

let uiTestNow: Date                    // fixed reference instant
let uiTestClaudeUsage: ProviderUsage
let uiTestCodexUsage: ProviderUsage
// optional: go / minimax sample usages for later suites

@MainActor
func makeShellModel(
    appState: AppState = AppState(),
    settingsStore: SettingsStore = SettingsStore(defaults: isolatedDefaults()),
    usageController: any UsageControlling = RecordingUsageController(),
    launchAtLoginManager: any LaunchAtLoginManaging = RecordingLaunchAtLoginManager(),
    now: @MainActor @escaping () -> Date = { uiTestNow }
) -> UsageBarShellModel

func isolatedDefaults(suiteName: String = UUID().uuidString) -> UserDefaults

@MainActor
func appState(
    _ states: [ProviderID: ProviderState]
) -> AppState

actor RecordingUsageController: UsageControlling { … }  // refreshCallCount, intervals

final class RecordingLaunchAtLoginManager: LaunchAtLoginManaging { … }
```

**Should extract (cheap, high reuse for Phase 1 matrix):**

```swift
@MainActor
func freshState(
    claude: ProviderUsage = uiTestClaudeUsage,
    codex: ProviderUsage = uiTestCodexUsage,
    asOf: Date = uiTestNow
) -> AppState

@MainActor
func staleState(
    provider: ProviderID,
    last: ProviderUsage?,
    reason: StaleReason,
    others: [ProviderID: ProviderState] = [:]
) -> AppState
```

**Defer to Phase 1:**

- Full parameterized matrix helpers
- `UITestHost` / window sizing constants used only by hosting
- Snapshot PNG helpers

### B.4 Migration of existing tests

1. Move types/functions into `Support/UITestFixtures.swift` with `internal` access (default).
2. Delete private duplicates from `UsageBarShellModelTests.swift`.
3. Rename call sites `shellModel(` → `makeShellModel(` **or** keep the name `shellModel` in Support to minimize diff — prefer keeping `shellModel` if it reduces churn.
4. Ensure every settings-touching test still uses **isolated** `UserDefaults` suites (fix any use of `.standard` in tests while extracting; production default in the factory should be isolated, not `.standard`).

**Bugfix opportunity while extracting:** the current private factory defaults to `SettingsStore(defaults: .standard)`, which can leak across tests. Phase 0 should change the default to an isolated suite. That is an allowed behavior change **in tests only**.

### B.5 Deliverables

| Deliverable | Notes |
|---|---|
| `Tests/AIUsageBarAppTests/Support/UITestFixtures.swift` | factories + fakes + sample data |
| Existing app tests green | same assertions, less private boilerplate |
| No `.standard` UserDefaults in app test factories | isolation guarantee |

---

## Workstream C — Documentation

### C.1 This phase doc (done when exit criteria met)

Keep `docs/ui-test-harness-phase-0.md` as the living checklist; tick workstreams in the PR body.

### C.2 Parent plan

Already at `docs/ui-test-harness.md`. Phase 0 PR should not rewrite it except to fix factual drift.

### C.3 AGENTS.md pointer (short)

Add a brief subsection under Build/test or Conventions — roughly:

```markdown
## UI test harness

Hosted SwiftUI / accessibility UI tests are planned in `docs/ui-test-harness.md`.
Phase prep and conventions: `docs/ui-test-harness-phase-0.md`.
UI tests must use fake `UsageBarShellModel` wiring from
`Tests/AIUsageBarAppTests/Support/` — never `UsageBarShellModel.live()`.
Accessibility identifiers live in `AccessibilityID` (app target).
```

Do not paste the full plan into AGENTS.md.

### C.4 Conventions (canonical copy for agents)

These rules apply from Phase 0 forward:

1. **Fake-only shell.** Construct `UsageBarShellModel` via test factories. Never call `.live()` from tests.
2. **No credentials.** No Keychain, Chrome Safe Storage, auth.json, or Codex helper in UI-oriented tests.
3. **Main actor.** All view and shell tests are `@MainActor`.
4. **Swift Testing only.** `@Test` / `#expect`; no XCTest UI test target in Phase 0–1.
5. **Shared identifiers.** Product and tests use `AccessibilityID`; no duplicate string literals in tests.
6. **VMs stay source of truth for copy.** UI tests assert wiring (control exists, action fires, bound value shows). Do not re-encode every `StaleReason` phrase in UI tests if the VM already has a unit test — sample one representative string per path.
7. **Deterministic time.** Inject `now: { uiTestNow }` (or equivalent); never `Date()`.
8. **Isolated defaults.** Every `SettingsStore` in tests gets its own `UserDefaults` suite.
9. **No sleeps.** Phase 0–1 forbid `Task.sleep` / wall-clock waits. (Phase 3 smoke may bound-poll a process.)
10. **Private views stay private.** Test through `MenuBarContentView`, `AppSettingsView`, `MenuBarLabelView` roots only.

### C.5 acceptance.md (optional touch)

If time permits, add a one-line legend note that automation status will be filled in Phase 4 — do not reclassify checklist items yet.

---

## Workstream D — Package / build sanity

### D.1 Verify no Package.swift change required

Confirm `AIUsageBarAppTests` picks up `Support/*.swift` automatically. If the target ever switches to explicit sources, add the new file.

### D.2 Verify AccessibilityID does not break concurrency

`AccessibilityID` should be a pure namespace (`enum AccessibilityID { … }`) with `static let` / `static func` returning `String`. `Sendable`, no mutable state.

### D.3 Run

```bash
scripts/run-swift-tests
```

Optional focused filter once Phase 0 tests exist:

```bash
swift test --enable-swift-testing --filter MenuBarLabelImage
swift test --enable-swift-testing --filter shellModel
```

### D.4 What not to run

- `scripts/bundle.sh` is not required for Phase 0 sign-off (no bundle surface change beyond additive AX on views already in the app target).
- Do not start the live app against real credentials to “check” identifiers — that is manual and optional.

---

## Implementation order (recommended)

```
1. AccessibilityID.swift          (constants only; tests can reference later)
2. UITestFixtures.swift           (extract fakes + factory; fix isolated defaults)
3. Migrate UsageBarShellModelTests (+ any other file using private fakes)
4. scripts/run-swift-tests        (green checkpoint)
5. Apply identifiers to MenuBarContentView + MenuBarLabelView
6. MenuBarLabelImage.accessibilityValue + unit tests
7. Apply identifiers to AppSettingsView controls
8. scripts/run-swift-tests        (green checkpoint)
9. AGENTS.md pointer + finalize this doc’s exit checklist
```

Steps 5–7 are still Phase 0 (prep identifiers), not Phase 1 (hosting). They intentionally land before hosting so Phase 1 PRs do not mix product AX churn with new infrastructure.

If the PR threatens to grow past ~reviewable size, split:

- **0a:** fixtures + isolated defaults + AGENTS pointer  
- **0b:** AccessibilityID + all view identifier applications + label AX value tests  

Both must finish before Phase 1 starts.

---

## Test plan for Phase 0 itself

| Check | How |
|---|---|
| Existing shell/settings/label/icon/notification/termination tests still pass | `scripts/run-swift-tests` |
| New label AX value cases | `#expect` on empty, one provider, two providers, stale `~` prefix, three-provider partition order |
| Factory isolation | Two `shellModel()` / `makeShellModel()` calls with different visibility settings do not clobber each other (add one small test if not already implied) |
| No `.live()` in test target | `rg 'UsageBarShellModel\.live' Tests/` → no matches |
| Identifier constants used in views | `rg 'accessibilityIdentifier' Sources/AIUsageBarApp` shows catalog entries |

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| TabView does not expose per-tab identifiers reliably | Phase 0 still adds ids on tab root panes via `.accessibilityIdentifier` on each pane’s outer container; Phase 1 may select tabs by AX label (“General”) if ids do not surface |
| Changing default `UserDefaults` in factory breaks a test that relied on shared state | Prefer fix the test; shared `.standard` was a latent footgun |
| AX combine + identifier interaction drops children | Spot-check with Accessibility Inspector manually once after 0b (manual, 5 minutes); document result in PR |
| Scope creep into UITestHost | Reject in review; host code is Phase 1 exit |

---

## Phase 0 PR checklist

- [x] `Sources/AIUsageBarApp/AccessibilityID.swift` added
- [x] Dropdown, label, Settings controls tagged per catalog
- [x] `MenuBarLabelImage.accessibilityValue(for:)` + unit tests
- [x] `Tests/AIUsageBarAppTests/Support/UITestFixtures.swift` added
- [x] App tests migrated off private duplicate fakes
- [x] Test factory uses isolated `UserDefaults` by default
- [x] `rg 'UsageBarShellModel\.live' Tests/` clean
- [x] `AGENTS.md` short pointer added
- [x] `scripts/run-swift-tests` green
- [ ] PR description links `docs/ui-test-harness.md` and this file
- [x] No snapshot/host/smoke code included

---

## Handoff to Phase 1

When Phase 0 is merged, Phase 1 starts with:

1. `Support/UITestHost.swift` — `NSHostingView` + fixed sizes (320 / 500)
2. `Support/AXQuery.swift` — lookup by `AccessibilityID`
3. Vertical slice tests:
   - `MenuBarContentView`: two fresh providers → provider AX nodes exist; Refresh increments `RecordingUsageController`
   - `AppSettingsView`: seeded Off/Checking status visible; Cancel path
4. No further identifier design work unless a control was deferred in A.1

Phase 1 must not redefine identifier strings; it only consumes `AccessibilityID`.
