# UI Test Harness — Slice 1 (Vertical proof)

Parent plan: [`docs/ui-test-harness.md`](ui-test-harness.md)  
Prerequisite: [`docs/ui-test-harness-phase-0.md`](ui-test-harness-phase-0.md) (merged — AX ids, fixtures, conventions)

This is the **suggested first PR slice after Phase 0** from the parent plan
(“Suggested first PR slice”). It is the smallest vertical cut that proves
hosted SwiftUI + accessibility querying + fake shell wiring before the full
Phase 1 matrix lands.

## Goal

Prove the L1 harness end-to-end with **two hosted tests and the shared host/query
infrastructure**, and nothing more:

1. Host `MenuBarContentView` / `AppSettingsView` in `NSHostingView` on the main
   actor.
2. Query real accessibility identifiers from Phase 0’s `AccessibilityID`.
3. Assert one dropdown wiring path (rows + Refresh → controller).
4. Assert one Settings wiring path (Providers status line + Cancel).

When this slice merges, Phase 1’s remaining suites (`MenuBarContentViewTests`
matrix, `AppSettingsView*Tests` per tab, `MenuBarLabelViewTests`,
`SettingsWiringTests`) become pure test additions on a known-good host/query
layer — no more identifier design, no more fixture extraction, no product AX
churn.

## Non-goals

- Full fixture matrix (stale reasons, Go monthly, Fable, all-four visibility,
  launch-at-login failure paths) — later Phase 1 PRs.
- Snapshot / PNG infrastructure (Phase 2).
- Bundle smoke / `--ui-smoke` (Phase 3).
- MenuBarExtra / status-item XCUITest (L4, deferred).
- Hosting `MenuBarLabelView` or asserting menu-bar AX value (Phase 1 later;
  pure `MenuBarLabelImage.accessibilityValue` already unit-tested in Phase 0).
- Opening private nested Settings subviews for import.
- Calling or refactoring `.live()`.
- New SPM dependencies (no ViewInspector, no swift-snapshot-testing).
- Product copy, layout, color, or behavior changes.
- New accessibility identifiers (catalog is complete; only consume
  `AccessibilityID`).
- Keychain, network, Chrome cookies, Codex helper, notification sheets.

## Exit criteria

Slice 1 is done when all of the following hold (updated to the **reads-only**
scope that actually shipped — see “What actually shipped” below):

1. `Tests/AIUsageBarAppTests/Support/UITestHost.swift` hosts a SwiftUI root in
   `NSHostingView`, sizes to production constants (dropdown **320**, Settings
   **500**), and forces a full content size so every tab’s AX tree is reachable.
2. `Tests/AIUsageBarAppTests/Support/AXQuery.swift` finds nodes by
   `AccessibilityID` (and by label/role where TabView flattens pane ids) and
   supports at least `exists`, label/value read. **No** in-process `press`/
   click API — synthetic input kills the runner (documented below).
3. One `MenuBarContentView` test: two fresh providers → Claude/Codex provider
   and window AX nodes exist (incl. Codex having no 5-hour row); footer
   Refresh/Settings/Quit/Updated exist.
4. One `AppSettingsView` test: General pane picker shows a **non-default**
   seeded poll interval (store→control binding); launch-at-login checkbox and
   Cancel/OK footer present.
5. Both tests run **off** `@MainActor` (cooperative pool + `onMain` hops),
   Swift Testing only, use `shellModel(...)` / `UITestFixtures`, never
   `.live()`.
6. `scripts/run-swift-tests` is green twice in a row (hosted suite in a
   separate process from the rest). Bounded `pollUntil` sleeps are allowed;
   no multi-second `Task.sleep` retries.
7. **Zero** product-code diff under `Sources/`.
8. Parent plan / AGENTS.md pointer updated for the reads-only handoff.

Estimated effort: about half a day to one day; one PR on a feature branch off
updated `main` (or off merged Phase 0).

---

## Preconditions (verify before coding)

Phase 0 must already be true in the worktree:

| Check | Command / expectation |
|---|---|
| `AccessibilityID` exists | `Sources/AIUsageBarApp/AccessibilityID.swift` |
| Fixtures exist | `Tests/AIUsageBarAppTests/Support/UITestFixtures.swift` with `shellModel`, `freshState`, `RecordingUsageController`, `uiTestNow`, sample usages |
| Dropdown tagged | `rg 'menuBarRefresh\|menuBarProvider' Sources/AIUsageBarApp/MenuBarContentView.swift` |
| Settings tagged | `rg 'settingsCancel\|settingsProviderStatus\|settingsTabProviders' Sources/AIUsageBarApp/AppSettingsView.swift` |
| No `.live()` in tests | `rg 'UsageBarShellModel\.live' Tests/` → no matches |
| Suite green | `scripts/run-swift-tests` |

If any of the above fail, finish Phase 0 — do not start Slice 1.

**Branch hygiene (from `AGENTS.md` / CLAUDE.md):**

- Inspect worktree; preserve user changes.
- Pull latest `main` before branching unless already based correctly.
- Feature branch only; never commit/push to `main`.

Suggested branch name: `flow/ui-test-harness-slice-1` (or `flow/ui-test-harness-phase-1-slice-1`).

---

## Architecture for this slice

```
┌─────────────────────────────────────────────────────────────┐
│  @Test @MainActor                                           │
│    shellModel(appState: freshState(...), usageController:)  │
│    host = UITestHost.dropdown(MenuBarContentView(model:))   │
│    ax   = AXQuery(root: host.root)                          │
│    #expect(ax.exists(AccessibilityID.menuBarProvider(.claude))) │
│    ax.press(AccessibilityID.menuBarRefresh)                 │
│    #expect(await controller.refreshCallCount() == 1)        │
└───────────────────────────┬─────────────────────────────────┘
                            │
            ┌───────────────▼────────────────┐
            │ UITestHost                     │
            │  NSHostingView(rootView:)      │
            │  frame = production size       │
            │  layoutSubtreeIfNeeded()       │
            └───────────────┬────────────────┘
                            │ AppKit AX tree
            ┌───────────────▼────────────────┐
            │ AXQuery                        │
            │  walk accessibility children   │
            │  match accessibilityIdentifier │
            │  press / read value/label      │
            └────────────────────────────────┘
```

**Hard rules (from Phase 0 conventions):**

1. Fake-only shell via `shellModel` — never `.live()`.
2. No credentials / network / helper spawn.
3. `@MainActor` for all view + shell tests.
4. Swift Testing only.
5. Shared `AccessibilityID` constants — no string literals in tests for ids.
6. VMs stay source of truth for copy — assert **wiring** (node exists, action
   fires, bound value shows). One representative status string is enough.
7. Deterministic `uiTestNow`.
8. Isolated `UserDefaults` (factory default already fixed in Phase 0).
9. **No `Task.sleep` / wall-clock waits.**
10. Private views stay private — roots only:
    `MenuBarContentView`, `AppSettingsView` (not `MenuBarLabelView` in this slice).

---

## Workstream 1 — `UITestHost`

### 1.1 File

`Tests/AIUsageBarAppTests/Support/UITestHost.swift`

### 1.2 Responsibilities

- Create an `NSHostingView` wrapping a generic `Root: View`.
- Apply fixed sizes matching production:
  - Dropdown: **width 320** (`MenuBarContentView` `.frame(width: 320)`).
  - Settings: **width 500** (`AppSettingsView` `.frame(width: 500)`).
- Choose a generous height so TabView / provider cards are not clipped before
  layout (e.g. dropdown height ~600, Settings height ~700). Prefer constants
  named next to the production widths:

  ```swift
  enum UITestHost {
      static let dropdownWidth: CGFloat = 320
      static let settingsWidth: CGFloat = 500
      // heights are test-only; wide enough that content is not clipped
      static let dropdownHeight: CGFloat = 600
      static let settingsHeight: CGFloat = 720
  }
  ```

- Force layout so accessibility children exist **before** the test queries:
  - set `hostingView.frame`
  - `hostingView.layoutSubtreeIfNeeded()`
  - optionally attach to an off-screen `NSWindow` if bare `NSHostingView`
    yields an empty AX tree (see Risks). Prefer the minimal approach that
    works; document which one landed in the PR body.

- Keep the host alive for the duration of the test (return a small holder type
  that retains `NSHostingView` and optional `NSWindow`).

### 1.3 Suggested API shape

Names indicative; match project style when implementing:

```swift
import AppKit
import SwiftUI

@MainActor
final class UITestHost {
    let hostingView: NSHostingView<AnyView>
    private var window: NSWindow?

    static func dropdown<Content: View>(_ root: Content) -> UITestHost {
        UITestHost(
            root: root,
            size: NSSize(width: dropdownWidth, height: dropdownHeight)
        )
    }

    static func settings<Content: View>(_ root: Content) -> UITestHost {
        UITestHost(
            root: root,
            size: NSSize(width: settingsWidth, height: settingsHeight)
        )
    }

    var axRoot: any NSObjectProtocol { hostingView /* or contentView */ }

    /// Run the default run-loop briefly only if layout alone is insufficient.
    /// Prefer layoutSubtreeIfNeeded; forbid multi-second sleeps.
    func settleIfNeeded() { … }
}
```

### 1.4 What not to put here

- Snapshot PNG encoding (Phase 2).
- Global shared host / singleton.
- Auto-calling `.live()`.
- Production size constants moved into the app target (keep test-only unless a
  later product need appears).

### 1.5 Package membership

No `Package.swift` change: `AIUsageBarAppTests` already compiles everything
under `Tests/AIUsageBarAppTests/`.

---

## Workstream 2 — `AXQuery`

### 2.1 File

`Tests/AIUsageBarAppTests/Support/AXQuery.swift`

### 2.2 Responsibilities

Walk the AppKit accessibility tree rooted at the hosting view (and window
content view if hosted in a window). Match primarily by
`accessibilityIdentifier()`.

Minimum surface for Slice 1:

| Method | Purpose |
|---|---|
| `init(root:)` | Entry point from `UITestHost` |
| `element(id: String) -> AXNode?` | First match by identifier |
| `exists(_ id: String) -> Bool` | Convenience |
| `label(_ id: String) -> String?` | `accessibilityLabel()` |
| `value(_ id: String) -> Any?` / `stringValue` | `accessibilityValue()` |
| `press(_ id: String)` | Invoke the default action (`AXPress` / `accessibilityPerformPress()`) |

Optional but useful if first Settings tab switch needs it:

| Method | Purpose |
|---|---|
| `element(label: String) -> AXNode?` | Fallback when TabView hides pane identifiers |
| `children` debug dump | Fail messages listing visible ids/labels |

### 2.3 Implementation notes

- Use `NSAccessibility` / `NSView` accessibility API available on macOS 14+.
  Prefer typed Swift (`accessibilityChildren()`, `accessibilityIdentifier()`,
  `accessibilityPerformPress()`) over raw `AXUIElement` C API **unless** the
  Swift API does not see SwiftUI-hosted controls — then fall back to
  `AXUIElementCreateWithHitTest` / attribute copy on the view’s window.
- Recurse depth-first; first match wins.
- Identifier comparison is exact string equality against `AccessibilityID.*`.
- Do **not** hard-code product ids inside `AXQuery`; callers pass
  `AccessibilityID.menuBarRefresh` etc.
- Failure messages should include the missing id and a short dump of nearby
  identifiers to speed debugging (keep dump bounded, e.g. first 40 nodes).

### 2.4 Thin wrapper type

```swift
@MainActor
struct AXQuery {
    let root: any NSObjectProtocol  // or NSView

    func exists(_ id: String) -> Bool { element(id: id) != nil }

    func press(_ id: String) throws {
        guard let el = element(id: id) else {
            Issue.record("Missing AX id \(id). Tree:\n\(dumpIdentifiers())")
            throw AXQueryError.notFound(id)
        }
        // perform press
    }

    func stringValue(id: String) -> String? { … }
    func label(id: String) -> String? { … }
}
```

Use `throws` or `#require` at call sites — either is fine; be consistent in
both tests.

### 2.5 Unit-level smoke (optional micro-test)

If useful while building the query layer, a tiny internal test that hosts a
one-line `Text("hi").accessibilityIdentifier("probe")` and asserts
`exists("probe")` can lock the host+query path before product views. Delete or
keep — not required for exit criteria if the two product tests cover it.

---

## Workstream 3 — Dropdown vertical test

### 3.1 File

`Tests/AIUsageBarAppTests/MenuBarContentViewTests.swift`  
(new file; later Phase 1 PRs append the full matrix here)

### 3.2 Scenario (exactly one test in this slice)

**Name (indicative):**
`menuBarContentViewShowsFreshProviderRowsAndRefreshCallsController`

**Seed:**

```swift
let controller = RecordingUsageController()
let model = shellModel(
    appState: freshState(),           // Claude + Codex fresh @ uiTestNow
    usageController: controller
)
// freshState already uses uiTestClaudeUsage / uiTestCodexUsage
```

**Host:**

```swift
let host = UITestHost.dropdown(MenuBarContentView(model: model))
let ax = AXQuery(root: host.axRoot)
```

**Assert wiring (not VM re-derivation):**

1. Provider name nodes exist:
   - `AccessibilityID.menuBarProvider(.claude)` 
   - `AccessibilityID.menuBarProvider(.codex)`
2. Optional but cheap if stable after layout:
   - Claude five-hour + weekly window ids present
   - Codex weekly present; Codex five-hour **absent**
     (`!ax.exists(AccessibilityID.menuBarWindow(.codex, .fiveHour))`)
3. Footer controls exist: refresh, settings, quit.
4. Action:
   ```swift
   #expect(await controller.refreshCallCount() == 0)
   try ax.press(AccessibilityID.menuBarRefresh)
   // Refresh is `Task { await model.refreshNow() }` — yield once on MainActor
   await Task.yield()
   // If still 0, a second yield or awaiting a tiny MainActor hop is OK;
   // never sleep for wall-clock seconds.
   #expect(await controller.refreshCallCount() == 1)
   ```

**Do not assert in this slice:**

- Full countdown / percent string equality for every window (VM-tested).
- Stale greying, Fable, monthly, empty footer-only state.
- Settings gear calling `openSettings` (environment action is a no-op / no-op
  outside a `Settings` scene — cover Settings via `AppSettingsView` directly).
- Quit (would terminate the test process if it hit `NSApplication.terminate`).

### 3.3 Known pitfall — Quit button

`MenuBarContentView`’s Quit calls `NSApplication.shared.terminate(nil)`.
**Never** `press` Quit in automated tests. Existence-only is fine; pressing is
out of scope forever unless Quit is redirected behind a test seam (not this
slice).

### 3.4 Known pitfall — Settings gear / `openSettings`

On appear, the view installs:

```swift
model.setSettingsOpener {
    NSApplication.shared.activate(ignoringOtherApps: true)
    openSettings()
}
```

In a bare `NSHostingView`, `openSettings` does nothing useful. Slice 1 does
**not** test Settings presentation from the dropdown. The Settings vertical
test hosts `AppSettingsView` directly.

### 3.5 Async Refresh

Refresh wraps work in `Task { await model.refreshNow() }`. After `press`, the
test must allow that task to run. Preferred pattern:

```swift
try ax.press(AccessibilityID.menuBarRefresh)
await waitUntil {
    await controller.refreshCallCount() == 1
}
```

where `waitUntil` is a **bounded MainActor poll** using `Task.yield()` /
`await Task.detached { }.value` style hops with a low iteration cap (e.g. 50
yields), **not** `Task.sleep`. Put `waitUntil` in Support if both tests need
it; otherwise inline once.

If `accessibilityPerformPress` is synchronous and the button action schedules
a `Task`, one or two yields are usually enough. Pin the final count with
`#expect`.

---

## Workstream 4 — Settings vertical test

### 4.1 File

`Tests/AIUsageBarAppTests/AppSettingsViewTests.swift`  
(new file; later PRs may split per tab — keep one file for now)

### 4.2 Scenario (exactly one test in this slice)

**Name (indicative):**
`appSettingsViewShowsSeededClaudeStatusOnProvidersTabAndCancelDiscardsNothingCommitted`

Parent plan wording: *“open Providers → Claude status line from seeded state →
Cancel”*.

**Seed (reuse the shell-model status fixture shape):**

```swift
let defaults = isolatedDefaults()
let settingsStore = SettingsStore(defaults: defaults)
// Defaults: Claude/Codex visible, Go/MiniMax hidden — fine for this test.

let appState = AppState(
    providerStates: [
        .claude: .fresh(uiTestClaudeUsage, asOf: uiTestNow),
        .codex: .fresh(uiTestCodexUsage, asOf: uiTestNow),
        .openCodeGo: .hidden,
        .miniMax: .hidden,
    ],
    lastSuccessfulRefreshes: [
        .claude: uiTestNow.addingTimeInterval(-120),
        .codex: uiTestNow.addingTimeInterval(-120),
    ],
    lastDataSources: [
        .claude: .claudeWebSession,
        .codex: .codexAPI,
    ]
)
let model = shellModel(appState: appState, settingsStore: settingsStore)
```

Expected Claude status text (already pinned in
`shellModelExposesProviderStatusRowsForTheSettingsProvidersTab`):

```text
Live · claude.ai web session · updated 2 min ago
```

(use `"Live \u{00B7} claude.ai web session \u{00B7} updated 2 min ago"` in source)

AX label on the combined status element (from product code):

```text
Claude status: Live · claude.ai web session · updated 2 min ago
```

Prefer asserting via identifier + label (or value) containing that text:

```swift
#expect(ax.exists(AccessibilityID.settingsProviderStatus(.claude)))
#expect(
    ax.label(AccessibilityID.settingsProviderStatus(.claude))
        == "Claude status: Live \u{00B7} claude.ai web session \u{00B7} updated 2 min ago"
)
```

That is **one** representative string proving the view bound
`providerStatusViewModel(stagedVisibility:)` — not a re-test of every
`StaleReason` phrase.

### 4.3 Tab selection

`AppSettingsView` opens on `SettingsTab.initial` == `.general`. The Claude
status line lives on **Providers**.

Phase 0 already warned: TabView may not surface
`settings.tab.providers` on the selectable chrome. Strategy order:

1. Try `ax.press` / activate control with identifier
   `AccessibilityID.settingsTabProviders` **if** it appears in the tree
   (pane root id may only exist after selection).
2. Else find by AX label / title `"Providers"` (tab item title from
   `SettingsTab.providers.title`) and press/select it.
3. After selection, assert pane content:
   `ax.exists(AccessibilityID.settingsProviderStatus(.claude))`
   and/or `ax.exists(AccessibilityID.settingsProviderToggle(.claude))`.

Document which strategy worked in the PR body so later suites copy it
(extract `func selectSettingsTab(_ tab: SettingsTab, ax: AXQuery)` into
Support only if the dance is non-trivial).

### 4.4 Cancel path

Cancel button:

```swift
Button("Cancel") { dismiss() }
.accessibilityIdentifier(AccessibilityID.settingsCancel)
```

In a hosted view without a real sheet presentation:

- `@Environment(\.dismiss)` may be a no-op.
- That is **acceptable** for Slice 1: the proof is that Cancel is present and
  pressing it does not call draft `apply`.

Assertions:

1. Before any edit, snapshot something that would change on OK — e.g.
   `settingsStore.pollInterval` and `model.pollInterval` (defaults).
2. Optionally flip a draft-only control if easily reachable (launch-at-login
   toggle on General) **before** switching tabs — only if it does not
   destabilize the test. Prefer the minimal path:
   - Open Settings host
   - Switch to Providers
   - Assert Claude status
   - Press Cancel
   - Assert store/model unchanged (poll interval, provider visibility, threshold)
3. Do **not** require that the hosting window closes.

If Cancel press is hard to observe, existence of Cancel + status assertion
still mostly proves the slice; prefer actually pressing Cancel once the press
path works for Refresh.

### 4.5 What not to assert yet

- OK apply / launch-at-login failure stay-on-General
- Disclosure expand/collapse / chain steps / recovery callout
- Staged-on Checking… without retained green Used
- Workspace field
- Threshold stepper
- Draft isolation across tabs

Those are later Phase 1 suites listed in the parent plan.

---

## Workstream 5 — Fixture touch-ups (only if needed)

`UITestFixtures.swift` already has what Slice 1 needs. Allowed additive
helpers if they remove duplication **in this PR**:

```swift
/// Claude Live + Codex Live with ages suitable for "updated 2 min ago".
@MainActor
func liveProvidersState(
    asOf: Date = uiTestNow,
    lastSuccess: Date = uiTestNow.addingTimeInterval(-120)
) -> AppState {
    AppState(
        providerStates: [
            .claude: .fresh(uiTestClaudeUsage, asOf: asOf),
            .codex: .fresh(uiTestCodexUsage, asOf: asOf),
            .openCodeGo: .hidden,
            .miniMax: .hidden,
        ],
        lastSuccessfulRefreshes: [
            .claude: lastSuccess,
            .codex: lastSuccess,
        ],
        lastDataSources: [
            .claude: .claudeWebSession,
            .codex: .codexAPI,
        ]
    )
}
```

Do **not** build the full parameterized matrix helpers here.

If Refresh needs a shared waiter:

```swift
@MainActor
func waitUntil(
    attempts: Int = 50,
    _ condition: () async -> Bool
) async -> Bool { … }
```

No `Task.sleep`. Fail the test if the condition never holds.

---

## Workstream 6 — Docs (minimal)

| Edit | Required? |
|---|---|
| This file (`docs/ui-test-harness-slice-1.md`) | Yes — this plan |
| `docs/ui-test-harness.md` | Only a one-line pointer under Phase 1 / first PR slice if missing: “Detailed plan: `docs/ui-test-harness-slice-1.md`” |
| `docs/ui-test-harness-phase-0.md` | No rewrite; handoff already points at this work |
| `AGENTS.md` | No change unless conventions need a “Slice 1 landed” note — skip |
| `acceptance.md` | No (Phase 4) |

Do not paste the full plan into AGENTS.md.

---

## File map (this slice only)

```
Sources/AIUsageBarApp/
  (no changes expected)

Tests/AIUsageBarAppTests/
  Support/
    UITestFixtures.swift          # existing — optional small helpers only
    UITestHost.swift              # NEW
    AXQuery.swift                 # NEW
  MenuBarContentViewTests.swift   # NEW — 1 test
  AppSettingsViewTests.swift      # NEW — 1 test

docs/
  ui-test-harness-slice-1.md      # this plan
  ui-test-harness.md              # optional one-line link
```

---

## Implementation order (recommended)

TDD-friendly; each step keeps the suite green or intentionally red only for
the new failing test under construction.

```
1. UITestHost.swift
   - Host a trivial Text with accessibilityIdentifier("probe")
   - Manual playground or optional probe test: frame + layout non-zero

2. AXQuery.swift
   - Find "probe" by identifier
   - exists / label path works
   - scripts/run-swift-tests green (probe test optional)

3. RED: MenuBarContentViewTests — provider ids + refresh count
   - Expect fail until host sizes / press / yield are right

4. GREEN: fix host/query until dropdown test passes
   - Do not weaken assertions (e.g. do not drop Refresh) to go green

5. RED: AppSettingsViewTests — Providers tab + Claude status + Cancel
   - Likely fail first on tab selection

6. GREEN: tab selection strategy + status label assert

7. Remove optional probe test if it adds noise

8. scripts/run-swift-tests twice
   - Confirm no flake

9. Optional docs one-liner in ui-test-harness.md

10. PR
```

### Commit strategy (optional, reviewable)

Prefer 1–2 commits on the branch:

1. `Add UITestHost and AXQuery for hosted SwiftUI tests`
2. `Add first MenuBarContentView and AppSettingsView AX tests`

Or a single commit if the diff stays small.

---

## Follow-ups after Slice 1 lands

### What actually shipped (deviations from the plan above)

Slice 1 landed **reads-only** hosted AX tests with **zero product-code
changes** (matching the plan's expectation — no test seams were needed in the
end):

- `UITestHost` / `AXQuery` as planned, plus `onMain { }` hops and a
  background-thread `pollUntil`.
- `MenuBarContentViewTests`: provider rows, window rows (incl. Codex having
  no 5-hour row), footer buttons, last-updated caption.
- `AppSettingsViewTests`: General pane controls bound to the store (picker
  shows the stored interval) + Cancel/OK footer. See below for why the
  original "Providers tab → Claude status → Cancel" assertions did not land.

### Synthetic input is not runner-safe in-process (findings)

Delivering a click to a SwiftUI control from inside the test process was
tried three ways — `AXUIElementPerformAction` (AXPress), HID-tap `CGEvent`,
and direct `NSEvent` posting. Each works in isolation but nondeterministically
kills the SwiftPM runner afterwards: `swift_task_asyncMainDrainQueue` exits
mid-run, so every later test silently never executes (exit 0, no
`Test run with N tests` summary). Related constraints discovered:

- AX **reads and actions must run on the main thread**: SwiftUI answers AX
  attribute requests (e.g. a Toggle's value) by evaluating view bindings and
  asserts the main queue (`dispatch_assert_queue_fail` in
  `ProvidersSettingsPane.body` when read off-main).
- Nested `RunLoop.run` inside a `@MainActor` test body steals Swift Testing's
  main-queue scheduling blocks — hosted tests therefore run on the
  cooperative pool and hop via `onMain`.

Interaction coverage stays at the model level (`shellModelRefreshIntent…`,
`AppSettingsDraftTests`, `shellModelPresentSettings…`). Phase 1+ interaction
testing needs either a process-per-test runner or XCUITest (L4).

### `ApplicationTerminationTests` process separation

`RecordingTerminationApplication()` instantiates a second `NSApplication`;
once `UITestHost` has called `NSApplication.shared.finishLaunching()`, that
second instance traps in `-[NSApplication init]`. `scripts/run-swift-tests`
therefore runs the hosted suite in a separate invocation
(`--skip 'HostedUITests'` then `--filter 'HostedUITests'`). If a future phase
needs them in one process, refactor the termination test to capture the reply
through a delegate-side seam instead of an NSApplication subclass.

### Identifiers inside TabView panes are flattened

Every control inside a macOS TabView pane reports the **pane's** identifier
(e.g. `settings.tab.general`), not its own — `settings.general.pollInterval`,
`settings.provider.{id}.*`, etc. are unreachable via the AX tree. The hosted
Settings test asserts pane controls by label + role (e.g. the `Refresh every`
pop-up's value proves store→control binding). Also, the TabView tab bar's AX
radio group is not reliably published in a hosted window. Fixing the
flattening (likely `.accessibilityElement(children: .contain)` on the pane
root) is a Phase 1 product-side decision; until then per-provider Settings
identifiers are only exercised by the model-level tests.

---

## Test plan / verification

| Check | How |
|---|---|
| Full suite | `scripts/run-swift-tests` (must show `Test run with N tests`, not build-only) |
| Focused | `swift test --enable-swift-testing --filter MenuBarContentView` |
| Focused | `swift test --enable-swift-testing --filter AppSettingsView` |
| Second run | Re-run full suite; zero flakes |
| No `.live()` | `rg 'UsageBarShellModel\.live' Tests/` clean |
| No sleeps | `rg 'Task\.sleep|Thread\.sleep' Tests/AIUsageBarAppTests` clean (except if somehow pre-existing) |
| Ids only from catalog | Tests reference `AccessibilityID.*`, not raw `"menubar.content.refresh"` literals |
| Product diff | `git diff main -- Sources/` empty (or justify any exception) |
| Manual AX spot-check (optional, 5 min) | Accessibility Inspector on a debug host if tab ids misbehave — note in PR |

### Acceptance mapping (slice-level)

| Acceptance | Evidence |
|---|---|
| Host works at production widths | `UITestHost` constants 320 / 500; tests pass |
| AX query by id | Both tests use `AccessibilityID` |
| Dropdown rows wired | Claude + Codex provider nodes exist |
| Refresh wired | `refreshCallCount() == 1` after press |
| Settings status wired | Claude status label matches seeded Live line |
| Cancel safe | Store/model unchanged after Cancel (or Cancel present + no apply side effects) |
| Conventions held | MainActor, fakes, no live, no sleep, no new deps |

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Bare `NSHostingView` has empty AX tree | Attach to off-screen `NSWindow` (`isReleasedWhenClosed = false`, `setIsVisible(false)` or order out); retain window on `UITestHost` |
| SwiftUI delays AX identifier publication until next layout pass | `layoutSubtreeIfNeeded()` + bounded yield loop; never multi-second sleep |
| TabView does not expose pane `accessibilityIdentifier` for selection | Select by tab title `"Providers"`; keep pane ids for post-selection content asserts |
| `accessibilityPerformPress` no-ops on some controls | Try `NSAccessibilityPerformAction` / button cell performClick on the backing view; last resort: call `model.refreshNow()` only in a **separate** non-AX unit test (already exists) and keep AX press as the Slice 1 goal — dig until press works for Refresh |
| Refresh `Task { }` races the assertion | Bounded MainActor `waitUntil` on `refreshCallCount` |
| Cancel/`dismiss` no-op confuses “did Cancel run?” | Assert no store mutation; do not assert window dismissal |
| Quit terminates the test runner | Never press Quit |
| Scope creep into full matrix | Review gate: only 2 product UI tests in this PR; extra cases → follow-up issues |
| Flaky font/layout on CI vs laptop | No snapshots in this slice; AX ids are stable |
| AppKit import in test target | Already implied by app tests linking the app; add `import AppKit` in Support files |
| Swift 6 concurrency on AX types | Keep query `@MainActor`; avoid sending `NSView` across actors |
| `openSettings` / activate side effects if Settings gear pressed | Do not press Settings gear in Slice 1 |

---

## Explicit non-regressions

Existing suites must stay green without rewrites:

- `UsageBarShellModelTests` (including status-line string pins)
- `AppSettingsDraftTests`, `SettingsTabTests`
- `MenuBarLabelImageTests`, `AccessibilityIDTests`
- `ApplicationTerminationTests`, notification / launch-at-login tests
- All `UsageCoreTests`

If `UITestHost` window creation interferes with termination tests, ensure
windows are closed/`window = nil` in `UITestHost.deinit` or an explicit
`close()` called at the end of each UI test.

---

## PR checklist

- [ ] Feature branch (not `main`)
- [ ] `Support/UITestHost.swift` added
- [ ] `Support/AXQuery.swift` added
- [ ] `MenuBarContentViewTests.swift` — one fresh two-provider + Refresh test
- [ ] `AppSettingsViewTests.swift` — Providers Claude status + Cancel test
- [ ] Tests use `AccessibilityID` + `shellModel` / `UITestFixtures` only
- [ ] No `.live()`, no Keychain/Chrome/helper, no `Task.sleep`
- [ ] No new SPM dependencies
- [ ] Product `Sources/` unchanged (or called out and minimal)
- [ ] `scripts/run-swift-tests` green ×2
- [ ] PR description links `docs/ui-test-harness.md` + this file
- [ ] PR description notes TabView selection strategy that worked
- [ ] Out of scope called out: matrix, snapshots, smoke, label hosting

### Suggested PR title

`Add hosted SwiftUI AX harness with first dropdown and Settings tests`

### Suggested PR body outline

1. Context: Phase 0 landed ids/fixtures; this proves L1 host+query.
2. What landed: UITestHost, AXQuery, 2 tests.
3. How to run: `scripts/run-swift-tests` / filters above.
4. Follow-ups: full `MenuBarContentView` matrix; per-tab Settings suites;
   menu bar label AX hosting; then Phase 2 snapshots.

---

## Handoff to rest of Phase 1

When Slice 1 merges, continue Phase 1 **without** redesigning identifiers or
host/query:

| Next PR (suggested) | Contents |
|---|---|
| Phase 1b — Dropdown matrix | Stale + caption; window present/absent (Fable, Go monthly, Codex no 5h); empty/all-hidden footer; last-updated caption |
| Phase 1c — Settings General + Notifications | Poll picker; launch-at-login staging + error; threshold stepper; OK/Cancel apply/discard |
| Phase 1d — Settings Providers matrix | Four cards; Off/Live/Stale/Checking; disclosure; chain; callout; workspace; staged-on Checking… |
| Phase 1e — Menu bar label hosting | `MenuBarLabelViewTests` via AX value already computed in Phase 0 |
| Phase 1f — SettingsWiringTests | Tab order/titles; draft isolation across tabs |

Each of those PRs only adds tests (+ tiny AXQuery helpers if press/setValue
gaps appear). Host and identifier catalog should stay stable.

**Phase 1 exit criteria (parent plan) still apply at the end of 1b–1f**, not
at Slice 1 merge. Slice 1 only proves the harness.

---

## Success definition (one sentence)

After Slice 1, a developer can host any app root view, query it by
`AccessibilityID`, and trust that Refresh and Settings status bindings are
observable in CI — unlocking the rest of Phase 1 as straight test writes.
