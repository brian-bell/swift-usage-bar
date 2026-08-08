# OpenCode credits (workspace balance) — plan

Surface the OpenCode workspace credit balance ("Current Balance" on the
console's Billing page) under the OpenCode Go provider, dropdown-only,
following the Fable-window precedent: no menu bar, no tone, no threshold
notifications.

## Evidence and constraints (captured 2026-08-07)

Full contract details live in `docs/endpoints.md` › "OpenCode credits".
The load-bearing facts:

- **No credits API exists** — no REST/JSON endpoint, no bearer-key path.
  The only access is the SolidStart server function `billing.get`, whose
  result is **already embedded in the `/workspace/<id>/go` SSR page the
  app fetches today**. Surfacing credits is therefore a parser-only data
  change: zero new HTTP requests, no new credential source, no new
  `ProviderDataSourceStep`.
- Units: `balance` and `monthlyUsage` are 10⁻⁸ dollars; `monthlyLimit`
  is whole dollars. Observed live: `balance:4703569480` ↔ `$47.04`,
  `monthlyUsage:296430520` ↔ `$2.96`, `monthlyLimit:50` ↔ `$50`.
- The billing record carries payment metadata (`customerID`,
  `paymentMethodID/Type/Last4`, Stripe subscription ids). Read-only
  product rules extend naturally: the parser extracts the three numeric
  fields and **drops everything else**; nothing from this record may be
  logged, persisted, or carried in `ProviderDataSource`.
- `customerID:null` means billing is not configured; that must yield
  "no credits", never `$0.00`.
- The billing record's plain-number `monthlyUsage:` coexists with the go
  window object of the same name, in nondeterministic stream order.
  `Tests/Fixtures/opencode-go-usage-billing.html` pins the billing-first
  order (the harder case for the window regexes).
- Watch item: anomalyco/opencode PR #16513 (`GET /zen/go/v1/usage`,
  authed by the `opencode-go` key in OpenCode's `auth.json`). If it
  merges, revisit — the entire Chrome-cookie chain could collapse to a
  file read plus one API call. Not actionable today.

## Product decisions (proposed defaults)

- **Where**: one extra row under OpenCode Go in the dropdown, shown
  whenever the provider is visible and the last parse carried credits.
  Nothing in the menu bar title, tone, or notifications — credits are a
  dollar scale, not a percent-remaining window, and mixing them into
  `tone(for:)` or `ThresholdNotifier` would need its own product design
  (dollar thresholds). Exclusions are pinned by tests, like Fable.
- **Copy**: title `Credits`, value `$47.04`, caption
  `$2.96 of $50 used this month` (limit line omitted when `monthlyLimit`
  is absent). No progress bar in slice 2 — a bar implies
  percent-remaining semantics the number doesn't have. If a bar is later
  wanted, `monthlyUsage / monthlyLimit` is the only defensible fraction.
- **No new settings.** Visibility rides on the provider's existing
  visibility toggle.
- **Staleness**: credits live inside `ProviderUsage`, so they inherit
  the provider's fresh/stale state and preserved-last-usage behavior for
  free. A stale row greys out with the rest of the provider section.

## Non-goals

- No `_server` `billing.get` direct call, no `/billing` page fetch — the
  `/go` page already carries the record, and the `_server` content hash
  is deploy-fragile.
- No Zen per-request cost ledger (`usage.list`), no referral rewards
  (different unit scale), no auto-reload state, no payment metadata.
- No menu bar, tone, or notification participation.
- No MiniMax/Codex credits generalization beyond the shared value type.

---

## Slice 0 — capture + repair (DONE, this session)

- `Tests/Fixtures/opencode-go-usage-billing.html`: sanitized 2026-08-07
  capture; billing record before go windows; `rollingUsage.status:
  "rate-limited"` variant.
- `openCodeGoParserParsesCapturedFixtureWithBillingRecordBeforeGoWindows`
  pins that the **current** parser handles the richer page unchanged
  (backward-compat floor for the slices below).
- `docs/endpoints.md`: credits contract + evidence recorded.
- Repaired main: `UsageBarShellModelTests.swift` had an unclosed brace
  plus a duplicated private-helper block colliding with PR #43's
  `Support/UITestFixtures.swift` — main did not compile. Fixed by
  closing the test and deleting the duplicate block (the Support file's
  "legacy alias" comments show that was the intent). Full suite green:
  497 + 2 hosted tests.

## Slice 1 — domain + parser (UsageCore only)

TDD order; every step red → green.

1. **`CreditBalance` value type** (in `UsageCore.swift`, near
   `UsageWindow`):

   ```swift
   public struct CreditBalance: Equatable, Sendable {
       /// Dollars remaining on the workspace balance.
       public let balanceUSD: Double
       /// Dollars spent from the balance this calendar month, when reported.
       public let monthlyUsedUSD: Double?
       /// Whole-dollar monthly spend limit, when configured.
       public let monthlyLimitUSD: Int?
   }
   ```

   Deliberately numeric-only: the type cannot carry payment metadata,
   which is the structural half of the privacy guarantee.

2. **`ProviderUsage.credits: CreditBalance?`** — fifth optional slot,
   default `nil`, mirroring how `fable` was added: existing call sites
   compile unchanged, `Equatable` extends naturally.

3. **Exclusion pins** (write these before touching the parser so the
   invariants are stated first):
   - `tone(for:)` ignores credits: a usage with healthy windows and a
     near-zero balance is still `.normal` (`tone` reads only
     fiveHour/weekly/monthly — test documents it stays that way).
   - `ThresholdNotifier` never fires for credits: notify-window
     comparison covers fiveHour/weekly/monthly only (existing
     `windows(comparedWith:)` — pin with a test where only credits
     change).
   - `MenuBarTitleFormatter` output is identical with and without
     credits present.

4. **Parser extraction** in `OpenCodeGoUsageParser.parse`:
   - New private `Self.credits(in: text) -> CreditBalance?` regex,
     modeled on `window(named:)`: match a single brace group containing
     `customerID:"…"` (non-null, the CodexBar sentinel), then in order
     `balance:(\d+)`, `monthlyLimit:(\d+)`, `monthlyUsage:(\d+)` with
     `[^{}]*` gaps — source-verified field order, and no nested braces
     occur between those keys (the `lite:{…}` object comes after).
   - Conversion: `balanceUSD = Double(balance) / 100_000_000` (round to
     cents at the formatter, not in the model), `monthlyUsedUSD`
     likewise, `monthlyLimitUSD = Int(limit)`.
   - **Credits are decoration**: any mismatch — no billing record,
     `customerID:null`, unparseable digits — yields `credits: nil` and
     must never fail window parsing. This deviates from the windows'
     strict anti-drift throw deliberately: rolling/weekly/monthly are
     the product; credits failing silently matches how the Claude web
     path and Codex app-server fallback degrade without surfacing their
     own errors.
   - Tests, fixture-backed on `opencode-go-usage-billing.html`:
     - parses `CreditBalance(balanceUSD: 42.5, monthlyUsedUSD: 2.96,
       monthlyLimitUSD: 50)` (fixture values).
     - old fixture `opencode-go-usage.html` (no billing record) →
       `credits == nil`, windows unchanged.
     - inline `customerID:null` variant → `credits == nil`, windows
       still parse.
     - malformed balance digits → `credits == nil`, no throw.
     - **privacy pin**: the parse result of the billing fixture is
       value-equal to one constructed from the three numbers alone —
       nothing else from the record can escape because `CreditBalance`
       has nowhere to put it (test states the intent for reviewers).

5. **Provider passthrough**: `OpenCodeGoProvider` needs no code change
   (credits ride inside the parsed `ProviderUsage`); add one provider
   test asserting a fetch through the fake transport surfaces credits
   in the `.fresh` state, and that workspace qualification (rolling
   window present) is unaffected by the billing record.

## Slice 2 — dropdown UI + docs

1. **`DropdownCreditsRow`** in `DropdownViewModel.swift`:

   ```swift
   public struct DropdownCreditsRow: Equatable, Sendable {
       public let title: String        // "Credits"
       public let amountLabel: String  // "$47.04"
       public let captionLabel: String? // "$2.96 of $50 used this month"
   }
   ```

   plus `DropdownProviderRow.credits: DropdownCreditsRow?`, built from
   `usage.credits` in both the fresh and stale(last:) paths (stale keeps
   last-known credits greyed, matching windows) and `nil` in the
   no-usage paths. Formatting is pure and tested: two-decimal dollars,
   caption omitted without a limit, `$0.00` rendered when balance is
   truly zero-but-billing-configured.

2. **`MenuBarContentView`**: render the credits row after the window
   rows in the OpenCode Go section — text row, no progress bar; add an
   `AccessibilityID` case (window-kind enum gets no new case; credits
   get their own id, e.g. `providerCredits(provider)` following the
   existing id scheme).

3. **Hosted UI fixture**: extend `uiTestOpenCodeGoUsage` in
   `Tests/AIUsageBarAppTests/Support/UITestFixtures.swift` with a
   credits value so the hosted AX test can read the row's label (slice-1
   reads-only harness covers it without synthetic clicks).

4. **Docs**: update `AGENTS.md` (OpenCode Go bullet + `ProviderUsage`
   key-types line + conventions: "credits changes must be backed by a
   sanitized observed fixture; never surface payment metadata") — and
   the fixture list. `docs/endpoints.md` already done in slice 0.

## Acceptance

- `scripts/run-swift-tests` green (both processes).
- Dropdown shows `Credits $47.04 · $2.96 of $50 used this month` under
  OpenCode Go when the live page carries a configured billing record;
  shows no credits row on the old fixture shape or `customerID:null`.
- Menu bar title, tone, and notifications byte-identical with and
  without credits (pinned by tests).
- No payment metadata anywhere: grep for `customerID` in `Sources/`
  matches only the parser regex.
- Manual smoke via `scripts/bundle.sh` + relaunch (per the signing notes
  in `AGENTS.md`) on the dev machine with the real Chrome session.

## Risks

- **Seroval drift**: the billing record shape is a private console
  implementation detail; a console deploy can reorder or rename fields.
  Mitigated by credits-as-decoration (drift degrades to a missing row,
  never a stale provider) and the fixture-backed anti-drift posture for
  the windows staying strict.
- **Field-order regex**: relies on source-verified key order within one
  object; if the console starts emitting nested braces between
  `customerID` and `monthlyUsage`, extraction silently drops. The
  slice-1 tests make the contract explicit; a future capture refreshes
  the fixture.
- **Balance semantics**: `useBalance` (spend balance after Go limits) is
  per-workspace; the row shows the balance regardless, which is correct
  — the money exists either way.
