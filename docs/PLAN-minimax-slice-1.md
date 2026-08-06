# Slice 1 — Plumbing + hidden-by-default UI scaffold

Drill-down of `docs/PLAN-minimax-slices.md` Slice 1. This is the *plumbing-only*
slice: MiniMax exists in every compiler-flagged `switch` but no provider is
wired, so the poller has nothing to fetch. Slice 2 lands the parser +
credential reader + provider; Slice 3 wires the real transport and surfaces
the dropdown / status / notifications.

## Goal

`ProviderID.miniMax` becomes a first-class case end to end:

- The menu bar title formatter has a symbol (`Mx`), a two-window display
  (`nn/nn`), and an absent-state placeholder rule (matches `.openCodeGo` —
  default-hidden providers don't render a placeholder before their first
  report).
- `ProviderDataSource.minimaxTokenPlanAPI` exists with display + chain labels.
- `SettingsStore.isProviderVisible(.miniMax)` returns `false` by default.
- `ProviderStatusViewModel` renders a MiniMax row that defaults to `Off`.
- `AppSettingsDraft` (placeholder + capture + apply) handles MiniMax with the
  same staged-OK/Cancel semantics as the other providers.
- No `UsageProvider` is constructed for MiniMax, so the poller has nothing to
  call. `UsageBarShellModel.live()` is unchanged.
- `swift build` stays clean under Swift 6 strict concurrency. The full Swift
  Testing suite (`scripts/run-swift-tests`) passes.

## Non-goals (deferred)

- No `MiniMaxUsageProvider`, no parser, no credential reader, no HTTP transport.
- No recovery-callout copy for MiniMax (Slice 3; the unreachable stub cases
  added here use neutral wording).
- No fixture in `Tests/Fixtures/`.
- No mention of MiniMax in `docs/endpoints.md` (Slice 2).
- No live provider wired in `UsageBarShellModel.live()`.

---

## File-by-file change list

Every edit below adds a `.miniMax` (provider) or `.minimaxTokenPlanAPI`
(source) case to a switch the compiler will flag, plus the surrounding wiring.
Order is chosen so each commit keeps `swift build` clean (or at most flags one
remaining known switch, see "Order of operations" below).

### 1. `Sources/UsageCore/UsageCore.swift`

Five edits in this file.

#### 1a. Add the enum case — line 68-72

Before:

```swift
public enum ProviderID: CaseIterable, Hashable, Sendable {
    case claude
    case codex
    case openCodeGo
}
```

After:

```swift
public enum ProviderID: CaseIterable, Hashable, Sendable {
    case claude
    case codex
    case openCodeGo
    case miniMax
}
```

#### 1b. `notificationDisplayName` — line 125-136

Add `case .miniMax:` returning `"MiniMax"`. Order: keep alphabetical-by-casing
habit (Claude, Codex, OpenCode Go, MiniMax) — matches the existing layout.

```swift
private extension ProviderID {
    var notificationDisplayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .openCodeGo:
            return "OpenCode Go"
        case .miniMax:
            return "MiniMax"
        }
    }
}
```

#### 1c. `MenuBarTitleFormatter.segments` absent-state rule — line 2057-2094

The current early-return special-cases `.openCodeGo`. Two providers now share
that rule. Replace the equality check with a set, so the rule is named and
extensible:

Before (lines 2059-2069):

```swift
public static func segments(_ states: [ProviderID: ProviderState]) -> [MenuBarTitleSegment] {
    ProviderID.allCases.compactMap { provider -> MenuBarTitleSegment? in
        guard let state = states[provider] else {
            if provider == .openCodeGo {
                return nil
            }
            return MenuBarTitleSegment(
                provider: provider,
                value: remainingPlaceholder(for: provider),
                isStale: false
            )
        }
        ...
```

After:

```swift
public static func segments(_ states: [ProviderID: ProviderState]) -> [MenuBarTitleSegment] {
    ProviderID.allCases.compactMap { provider -> MenuBarTitleSegment? in
        guard let state = states[provider] else {
            if Self.defaultHiddenProviders.contains(provider) {
                return nil
            }
            return MenuBarTitleSegment(
                provider: provider,
                value: remainingPlaceholder(for: provider),
                isStale: false
            )
        }
        ...
```

And add at the bottom of the `MenuBarTitleFormatter` enum:

```swift
    /// Providers that ship hidden and don't render a placeholder until they
    /// report at least once. The Settings tab lists them as `Off`; the menu bar
    /// title skips them entirely.
    private static let defaultHiddenProviders: Set<ProviderID> = [.openCodeGo, .miniMax]
```

This is the only behavior change vs. the existing `.openCodeGo` rule. The test
in `MenuBarTitleFormatterTests.swift` covers the absent-state rule today for
Claude/Codex implicitly (via the "all providers are hidden" test); the new
MiniMax test (§5 below) covers the new membership.

#### 1d. `remainingDisplay(for:)` — line 2432-2443

Two-window like Claude (`--/--`):

```swift
private extension ProviderUsage {
    func remainingDisplay(for provider: ProviderID) -> String {
        switch provider {
        case .claude:
            return "\(fiveHour.percentRemaining.map(String.init) ?? "--")/\(weekly.percentRemaining.map(String.init) ?? "--")"
        case .codex:
            return weekly.percentRemaining.map(String.init) ?? "--"
        case .openCodeGo:
            return "\(fiveHour.percentRemaining.map(String.init) ?? "--")/\(weekly.percentRemaining.map(String.init) ?? "--")/\(monthly?.percentRemaining.map(String.init) ?? "--")"
        case .miniMax:
            return "\(fiveHour.percentRemaining.map(String.init) ?? "--")/\(weekly.percentRemaining.map(String.init) ?? "--")"
        }
    }
}
```

#### 1e. `remainingPlaceholder(for:)` — line 2445-2454

Two-window placeholder, same as Claude:

```swift
private func remainingPlaceholder(for provider: ProviderID) -> String {
    switch provider {
    case .claude:
        return "--/--"
    case .codex:
        return "--"
    case .openCodeGo:
        return "--/--/--"
    case .miniMax:
        return "--/--"
    }
}
```

#### 1f. `symbol` — line 2456-2467

```swift
private extension ProviderID {
    var symbol: String {
        switch self {
        case .claude:
            return "*"
        case .codex:
            return "#"
        case .openCodeGo:
            return "G"
        case .miniMax:
            return "Mx"
        }
    }
}
```

### 2. `Sources/UsageCore/ProviderDataSource.swift`

Six edits.

#### 2a. New source case — line 9-21

```swift
public enum ProviderDataSource: Hashable, Sendable, CaseIterable {
    case claudeWebSession
    case claudeOAuthAPI
    case claudeStatuslineCache
    case codexAPI
    case codexAppServer
    case openCodeGoChromeCookie
    case minimaxTokenPlanAPI
```

#### 2b. `provider` mapping — line 23-32

```swift
public var provider: ProviderID {
    switch self {
    case .claudeWebSession, .claudeOAuthAPI, .claudeStatuslineCache:
        return .claude
    case .codexAPI, .codexAppServer:
        return .codex
    case .openCodeGoChromeCookie:
        return .openCodeGo
    case .minimaxTokenPlanAPI:
        return .miniMax
    }
}
```

#### 2c. `displayName` — line 35-50

```swift
public var displayName: String {
    switch self {
    case .claudeWebSession:
        return "claude.ai web session"
    case .claudeOAuthAPI:
        return "OAuth usage API"
    case .claudeStatuslineCache:
        return "Statusline cache"
    case .codexAPI:
        return "ChatGPT API (local Codex credential)"
    case .codexAppServer:
        return "Codex desktop app"
    case .openCodeGoChromeCookie:
        return "Chrome cookie"
    case .minimaxTokenPlanAPI:
        return "MiniMax token plan API"
    }
}
```

#### 2d. `chainStepName` — line 55-66

The slice doc specifies the literal label `"MiniMax token plan API (OpenCode key)"`,
matching the format used for other one-step providers:

```swift
public var chainStepName: String {
    switch self {
    case .claudeWebSession, .claudeOAuthAPI, .claudeStatuslineCache:
        return displayName
    case .codexAPI:
        return "ChatGPT API \u{00B7} Local Codex credential"
    case .codexAppServer:
        return "Codex app-server \u{00B7} Desktop sign-in"
    case .openCodeGoChromeCookie:
        return "Chrome cookie \u{00B7} opencode.ai"
    case .minimaxTokenPlanAPI:
        return "MiniMax token plan API (OpenCode key)"
    }
}
```

#### 2e. `dataSourceChain` — line 73-82

```swift
public extension ProviderID {
    var dataSourceChain: [ProviderDataSource] {
        switch self {
        case .claude:
            return [.claudeWebSession, .claudeOAuthAPI, .claudeStatuslineCache]
        case .codex:
            return [.codexAPI, .codexAppServer]
        case .openCodeGo:
            return [.openCodeGoChromeCookie]
        case .miniMax:
            return [.minimaxTokenPlanAPI]
        }
    }
}
```

#### 2f. `chainFailureSummary` — line 297-339

Route the new source like the existing API endpoints. For Slice 1 there is no
provider that can produce a `.minimaxTokenPlanAPI` step (no provider is
wired), so the wording is theoretical until Slice 3. We add it to the same
branches as `.codexAPI` because both are plain HTTPS endpoints, and let
Slice 3 refine if needed.

In the `.networkError` switch (lines 302-316), the existing
"catch-all to Network error" branch covers everything except
`.claudeStatuslineCache` and `.codexAppServer`. Add `.minimaxTokenPlanAPI` to
the catch-all:

```swift
case .claudeWebSession, .claudeOAuthAPI, .codexAPI,
     .openCodeGoChromeCookie, .minimaxTokenPlanAPI:
    return "Network error"
```

In the `.credentialUnavailable` switch (lines 324-337), add it alongside
`.claudeOAuthAPI, .codexAPI`:

```swift
case .claudeOAuthAPI, .codexAPI, .minimaxTokenPlanAPI:
    return "No credential found"
```

The other branches (`parseFailure`, `tokenExpired`, `sessionExpired`,
`workspaceSelectionRequired`) don't enumerate source cases at all and compile
without edits.

### 3. `Sources/UsageCore/ProviderStatusViewModel.swift`

Five edits, all in private extensions.

#### 3a. `chainCaption` — line 345-360

The slice doc says the disclosure's caption notes the OpenCode key source.
Claude and Codex have captions; OpenCode Go has none (the caption belongs to
the workspace field instead). MiniMax's caption should follow Claude/Codex
because it has no in-disclosure workspace field:

```swift
private extension ProviderID {
    var chainCaption: String? {
        switch self {
        case .claude:
            return """
                Sources are tried in order each refresh; data comes from the first that succeeds. \
                All access is read-only.
                """
        case .codex:
            return """
                The signed Codex desktop helper is tried only when the local Codex credential is \
                unavailable. Both paths read the weekly limit only.
                """
        case .openCodeGo:
            return nil
        case .miniMax:
            return """
                Reads only the OpenCode auth.json key for the MiniMax provider. All access is \
                read-only.
                """
        }
    }
```

#### 3b. `recoveryCallout(for:)` — line 366-403

`MiniMax` is unreachable as a stale provider in Slice 1 (no provider is wired,
so it never reports anything but `.hidden`). The catch-all branches
`(_, .networkError)`, `(_, .parseFailure)`, `(_, .workspaceSelectionRequired)`
already cover those reasons for every provider, but the switch has explicit
cases for the remaining reasons per provider and will fail to compile without
`.miniMax` cases.

Add the four cases Slice 3 will refine. Use the Slice 3 copy now (the
phrasing is documented in `docs/PLAN-minimax-slices.md` §3); even though
unreachable today, it eliminates a needless edit in Slice 3.

Insert before the existing `(_, .networkError)` catch-all:

```swift
        case (.miniMax, .credentialUnavailable):
            return prefix + "No MiniMax key found. Sign in to the MiniMax provider in "
                + "OpenCode (`opencode auth login`) \u{2014} AIUsageBar borrows that key "
                + "read-only."
        case (.miniMax, .tokenExpired):
            return prefix + "The MiniMax key was rejected. Re-authenticate the MiniMax "
                + "provider in OpenCode."
        case (.miniMax, .sessionExpired):
            return prefix + "Re-authenticate the MiniMax provider in OpenCode, then choose "
                + "Refresh Now from the menu bar."
```

(`(.miniMax, .networkError)`, `(.miniMax, .parseFailure)`, and
`(.miniMax, .workspaceSelectionRequired)` are caught by the existing
catch-alls.)

#### 3c. `statusDisplayName` — line 405-414

```swift
var statusDisplayName: String {
    switch self {
    case .claude:
        return "Claude"
    case .codex:
        return "Codex"
    case .openCodeGo:
        return "OpenCode Go"
    case .miniMax:
        return "MiniMax"
    }
}
```

#### 3d. `statusSummary(for:)` `.tokenExpired` arm — line 428-435

MiniMax uses an API key from `auth.json` (like Codex's Keychain token, but a
file-based key). Use a copy analogous to Codex's:

```swift
case .tokenExpired:
    switch provider {
    case .claude:
        return "OAuth token expired"
    case .codex:
        return "Keychain token expired"
    case .openCodeGo:
        return "Session token expired"
    case .miniMax:
        return "MiniMax key rejected"
    }
```

#### 3e. `statusSummary(for:)` `.credentialUnavailable` arm — line 436-444

```swift
case .credentialUnavailable:
    switch provider {
    case .claude:
        return "No Claude Code credential found"
    case .codex:
        return "No local Codex sign-in found"
    case .openCodeGo:
        return "OpenCode usage unavailable"
    case .miniMax:
        return "No MiniMax key found"
    }
```

#### 3f. (Optional) `showsWorkspaceField` — line 219

Already `provider == .openCodeGo`. No change — MiniMax does not get the
workspace field, per the slice's "no key field — the disclosure's caption
notes the OpenCode key source."

### 4. `Sources/AIUsageBarApp/AppSettingsDraft.swift`

#### 4a. `placeholder` defaults — line 15-23

Today: hidden iff `.openCodeGo`. Add MiniMax to the hidden set:

Before:

```swift
providerVisibility: Dictionary(
    uniqueKeysWithValues: ProviderID.allCases.map { ($0, $0 != .openCodeGo) }
),
```

After:

```swift
providerVisibility: Dictionary(
    uniqueKeysWithValues: ProviderID.allCases.map { provider in
        (provider, provider != .openCodeGo && provider != .miniMax)
    }
),
```

`capture(from:)` and `apply(to:)` already iterate `ProviderID.allCases` and
require no change.

### 5. `Sources/AIUsageBarApp/UsageBarShellModel.swift`

No code change. The `liveProviders(settingsStore:)` dictionary only constructs
three concrete providers (Claude, Codex, OpenCode Go). The poller iterates the
dictionary keys (line 748 in `UsageCore.swift`), so MiniMax is not polled.
`ProviderID.allCases` will now include `.miniMax` after the enum edit in
§1a, but its absence from `liveProviders` means `providers[.miniMax]` is
`nil` and the poller has nothing to call — exactly the acceptance criterion.

If `applyStoredProviderVisibility()` walks all `.allCases` and tries to hide
the not-registered MiniMax, it should still no-op safely (`setProvider(_, visible: false)`
just inserts into `hiddenProviders`).

### 6. `Sources/AIUsageBarApp/ProviderIconView.swift`

#### 6a. `resourceBaseName(for:)` — line 68-77

Returns `nil` for the new case (no SVG yet). Slice 3 will add one if desired.

```swift
private static func resourceBaseName(for provider: ProviderID) -> String? {
    switch provider {
    case .claude:
        return "ProviderIcon-claude"
    case .codex:
        return "ProviderIcon-codex"
    case .openCodeGo:
        return "ProviderIcon-opencode-go"
    case .miniMax:
        return nil
    }
}
```

#### 6b. `fallbackSymbol` — line 97-106

```swift
private var fallbackSymbol: String {
    switch provider {
    case .claude:
        return "*"
    case .codex:
        return "#"
    case .openCodeGo:
        return "G"
    case .miniMax:
        return "Mx"
    }
}
```

### 7. `Sources/AIUsageBarApp/NotificationSupport.swift`

#### 7a. `identifierComponent` — line 164-173

```swift
private extension ProviderID {
    var identifierComponent: String {
        switch self {
        case .claude:
            return "claude"
        case .codex:
            return "codex"
        case .openCodeGo:
            return "opencode-go"
        case .miniMax:
            return "minimax"
        }
    }
}
```

### 8. `Sources/AIUsageBarApp/MenuBarLabel.swift`

#### 8a. `abbreviation(for:)` — line 117-126

The slice doesn't dictate this (the AGENTS.md note of `Cl`/`Cx`/`Go` is
inconsistent with the actual icon assets), but the abbreviation is used in the
two-row menu bar image. Use `"Mx"` to match `symbol` from §1f:

```swift
private static func abbreviation(for provider: ProviderID) -> String {
    switch provider {
    case .claude:
        return "Cl"
    case .codex:
        return "Cx"
    case .openCodeGo:
        return "Go"
    case .miniMax:
        return "Mx"
    }
}
```

This keeps the menu bar's two-row partition consistent (`Cl  Cx  Mx  Go`)
when all four providers are visible. Slice 3 will pin a four-visible
partition test.

---

## Test additions

All edits below are red-first TDD. The acceptance-criteria tests are itemized
so each is independently runnable.

### 9. `Tests/UsageCoreTests/MenuBarTitleFormatterTests.swift`

Add one test for the absent-state rule with MiniMax:

```swift
@Test
func menuBarTitleFormatterOmitsDefaultHiddenProvidersWithNoDataYet() {
    let title = MenuBarTitleFormatter.format([:])

    // MiniMax is default-hidden; with no data yet it doesn't render at all,
    // unlike Claude and Codex which show placeholders until their first report.
    #expect(plainText(title) == "* --/--  # --")
}
```

(The current test `menuBarTitleFormatterShowsPlaceholdersWhenProvidersHaveNoDataYet`
asserts `"* --/--  # --"`. Once the existing helper is updated, this is the
same expectation — verify the assertion still holds with the new
`defaultHiddenProviders` set in §1c. If it does, no new test is required; if
it changes the assertion in any way, that's a regression and the new test
pins it.)

### 10. `Tests/UsageCoreTests/ProviderDataSourceChainTests.swift`

Extend the "declared chains" test (line 11-20):

```swift
@Test
func providerDataSourceChainListsEachProvidersSourcesInFallbackOrder() {
    #expect(ProviderID.claude.dataSourceChain == [
        .claudeWebSession,
        .claudeOAuthAPI,
        .claudeStatuslineCache,
    ])
    #expect(ProviderID.codex.dataSourceChain == [.codexAPI, .codexAppServer])
    #expect(ProviderID.openCodeGo.dataSourceChain == [.openCodeGoChromeCookie])
    #expect(ProviderID.miniMax.dataSourceChain == [.minimaxTokenPlanAPI])
}
```

Add a test for the new source's display names:

```swift
@Test
func minimaxTokenPlanAPIDataSourceNamesMatchTheProviderStatusConvention() {
    #expect(ProviderDataSource.minimaxTokenPlanAPI.provider == .miniMax)
    #expect(ProviderDataSource.minimaxTokenPlanAPI.displayName == "MiniMax token plan API")
    #expect(ProviderDataSource.minimaxTokenPlanAPI.chainStepName == "MiniMax token plan API (OpenCode key)")
}
```

### 11. `Tests/UsageCoreTests/SettingsStoreTests.swift`

Extend the defaults test (line 5-17):

```swift
@Test
func settingsStoreReturnsDefaultsWhenNothingHasBeenSaved() {
    withIsolatedDefaults { defaults in
        let store = SettingsStore(defaults: defaults)

        #expect(store.pollInterval == UsagePoller.defaultInterval)
        #expect(store.isProviderVisible(.claude))
        #expect(store.isProviderVisible(.codex))
        #expect(!store.isProviderVisible(.openCodeGo))
        #expect(!store.isProviderVisible(.miniMax))    // <— new
        #expect(store.thresholdPercent == 20)
        #expect(!store.launchAtLoginEnabled)
    }
}
```

Add a round-trip test for MiniMax visibility, parallel to the existing
`settingsStoreRoundTripsProviderVisibility`:

```swift
@Test
func settingsStoreRoundTripsMiniMaxVisibility() {
    withIsolatedDefaults { defaults in
        let store = SettingsStore(defaults: defaults)
        store.setProvider(.miniMax, visible: true)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.isProviderVisible(.miniMax))
    }
}
```

### 12. `Tests/AIUsageBarAppTests/AppSettingsDraftTests.swift`

Rename + extend `placeholderHidesOpenCodeGoOnly` (line 198-204):

```swift
@Test
@MainActor
func placeholderHidesOpenCodeGoAndMiniMax() {
    #expect(AppSettingsDraft.placeholder.visibility(for: .claude))
    #expect(AppSettingsDraft.placeholder.visibility(for: .codex))
    #expect(!AppSettingsDraft.placeholder.visibility(for: .openCodeGo))
    #expect(!AppSettingsDraft.placeholder.visibility(for: .miniMax))
}
```

### 13. `Tests/AIUsageBarAppTests/UsageBarShellModelTests.swift`

Extend `shellModelExposesProviderStatusRowsForTheSettingsProvidersTab`
(line 412-436) so the MiniMax row renders `Off`:

```swift
let appState = AppState(
    providerStates: [
        .claude: .fresh(claudeUsage, asOf: referenceNow),
        .codex: .stale(last: codexUsage, reason: .tokenExpired),
        .openCodeGo: .hidden,
        .miniMax: .hidden,
    ],
    lastSuccessfulRefreshes: [
        .claude: referenceNow.addingTimeInterval(-120),
        .codex: referenceNow.addingTimeInterval(-3_600),
    ],
    lastDataSources: [.claude: .claudeWebSession, .codex: .codexAPI]
)
let model = shellModel(appState: appState)

let rows = model.providerStatusViewModel.rows
#expect(rows.map(\.provider) == ProviderID.allCases)        // includes .miniMax now
#expect(try #require(rows.first { $0.provider == .claude }).text
    == "Live \u{00B7} claude.ai web session \u{00B7} updated 2 min ago")
#expect(try #require(rows.first { $0.provider == .codex }).text
    == "Stale \u{00B7} Keychain token expired \u{00B7} last data 1 h ago")
#expect(try #require(rows.first { $0.provider == .openCodeGo }).text == "Off")
#expect(try #require(rows.first { $0.provider == .miniMax }).text == "Off")
```

(The existing test happens to omit `.miniMax`; this expansion verifies the
provider shows up as `Off`. No test in this file currently asserts the row
order matches `ProviderID.allCases`, so add that pin too.)

The existing `stagedVisibilityRevealsANewlyEnabledProvidersDisclosureBeforeItIsPolled`
test (line 494-507) covers `.openCodeGo: true`. A parallel test for
`.miniMax: true` belongs in Slice 3, where the staged-on preview invariant
is pinned per the slice doc. Slice 1 leaves it untouched — `applyStoredProviderVisibility`
walks `.allCases` and will hide the not-yet-polled MiniMax safely without
needing a new test.

---

## Order of operations (TDD-friendly)

Each step ends with `swift build` (and where marked, `scripts/run-swift-tests`)
green. Commit after each step.

1. **Add the enum case and notification display name** (§1a + §1b). No tests
   break, but everything that switches on `ProviderID` becomes incomplete.
   `swift build` will fail on every flagged switch — this is expected and
   the next steps fix each.
2. **Update `MenuBarTitleFormatter.segments`** (§1c) + **add the
   `MenuBarTitleFormatterTests` assertion** (§9). Build green; the
   "no data yet" test passes because MiniMax is in
   `defaultHiddenProviders`.
3. **Update `remainingDisplay` / `remainingPlaceholder` / `symbol`**
   (§1d–1f). No new tests required (the formatter already covers these
   shapes indirectly via `MenuBarTitleSegment.value`).
4. **Add `ProviderDataSource.minimaxTokenPlanAPI` and its display /
   chainStepName / provider mapping / dataSourceChain** (§2a–2e) +
   **declared-chains test** (§10). Build green.
5. **Route `.minimaxTokenPlanAPI` through `chainFailureSummary`** (§2f).
   Build green.
6. **Update `ProviderStatusViewModel` (caption, recovery callout,
   statusDisplayName, statusSummary for tokenExpired/credentialUnavailable)**
   (§3a–3e). Build green.
7. **Update `AppSettingsDraft.placeholder`** (§4) + **placeholder test**
   (§12). Build green.
8. **Update icon view** (§6) + **notification id** (§7) + **menu bar
   abbreviation** (§8). Build green.
9. **Update `SettingsStore` defaults test** (§11) — no code change; just
   adds the new assertion. Build green.
10. **Extend the shell-model status rows test** (§13) — pure test edit.
    Build green.

Final verification: `scripts/run-swift-tests` passes and `git grep -n
"ProviderID"` shows every switch updated.

---

## Verification checklist (mirrors slice acceptance criteria)

- [ ] `swift build` clean under Swift 6 strict concurrency.
- [ ] `scripts/run-swift-tests` executes and passes (full suite, not just
      builds — see `AGENTS.md` "Test-execution note").
- [ ] `Tests/UsageCoreTests/MenuBarTitleFormatterTests.swift` covers the
      MiniMax absent-state rule.
- [ ] `Tests/UsageCoreTests/ProviderDataSourceChainTests.swift` asserts the
      MiniMax chain and the source's display names.
- [ ] `Tests/UsageCoreTests/SettingsStoreTests.swift` asserts the default
      visibility is `false` and that `setProvider(.miniMax, visible:)`
      round-trips.
- [ ] `Tests/AIUsageBarAppTests/AppSettingsDraftTests.swift` asserts the
      placeholder hides MiniMax.
- [ ] `Tests/AIUsageBarAppTests/UsageBarShellModelTests.swift` asserts the
      MiniMax row exists and renders `Off`.
- [ ] `git grep -nE "case \.claude|case \.codex|case \.openCodeGo"` shows
      every result paired with `case .miniMax` in the same switch body.
- [ ] `UsageBarShellModel.liveProviders` returns no entry for `.miniMax`
      (verify with `git diff` — should be empty).
- [ ] No fixture is added in this slice.
- [ ] No new package dependency, no script edit, no `docs/endpoints.md`
      change.

---

## Risks and follow-ups

- **`MenuBarLabel.abbreviation` divergence from the icon assets.** The
  `Cl`/`Cx`/`Go`/`Mx` labels are short enough to render in the two-row
  layout, but no SVG exists yet (`ProviderIconAsset.image(for: .miniMax)`
  returns `nil`, falling back to the `Mx` text). Slice 3 may add an asset;
  not required here.
- **`MenuBarTitleFormatter.segments` empty-states list.** The current
  `menuBarTitleFormatterReturnsEmptyStringWhenAllProvidersAreHidden` test
  (line 114-122) only exercises `.claude` and `.codex` hidden. With
  `.miniMax` now in `defaultHiddenProviders`, an absent-state MiniMax is
  treated identically to an explicit `.hidden`. The test still passes; no
  edit required, but worth running manually once to confirm.
- **Recovery-callout wording is committed in Slice 1.** The four
  `recoveryCallout` cases added in §3b use the Slice 3 wording because they
  are unreachable today. If the wording shifts in Slice 3, those four
  strings are the only ones to touch. They are display-only and won't
  change the chain logic.
- **`AppSettingsDraftTests` uses `ProviderID.allCases` directly.** Several
  tests iterate `.allCases` (lines 192-204 are the obvious ones); none
  enumerate individual provider IDs in a way that needs MiniMax-specific
  updating beyond the placeholder test. A `git grep ProviderID\.allCases`
  confirms coverage.
- **`scripts/setup-statusline` and the Codex desktop helper are unrelated.**
  No script edit is required for Slice 1.
- **Status-tone / threshold notifier.** `ThresholdNotifier` and
  `tone(for:)` iterate `current.windows(comparedWith:)`, which is keyed by
  `UsageWindowKind` rather than `ProviderID`, so they compile and run
  unchanged. The four-window-notification test (Slice 3) covers the
  provider-specific path.