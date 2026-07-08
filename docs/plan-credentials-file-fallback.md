# Plan: read-only fallback to `~/.claude/.credentials.json`

## Problem

The Claude API path reads the OAuth credential exclusively from the macOS Keychain
(service `Claude Code-credentials`). Two failure modes make that single source fragile:

1. **Keychain item without `claudeAiOauth`.** On some Claude Code 2.1.x versions the
   keychain item holds only `mcpOAuth` state (MCP-server tokens), while the Claude
   OAuth credential lives in `~/.claude/.credentials.json`
   (documented by CodexBar: steipete/CodexBar#1844 and its `docs/claude.md` storage
   hierarchy "internal cache → `~/.claude/.credentials.json` → Keychain"). On such a
   machine this app parses the keychain payload, finds no usable `claudeAiOauth`, and
   degrades to `.parseFailure` stale even though a valid token exists on disk.
2. **No keychain grant.** A user who denies (or never sees) the Keychain prompt gets
   `.credentialUnavailable` forever, even though the same credential may be readable
   from the file with no prompt at all.

A file read is strictly read-only, can never present a Keychain dialog, and reuses the
existing parser — the file's `claudeAiOauth` object has the same shape as the keychain
payload (`accessToken`, `refreshToken`, `expiresAt` epoch ms, `scopes`,
`subscriptionType`).

## Non-goals

- No OAuth token refresh, no credential writes, no watching the file for changes
  (the 2-minute poll cadence is enough). Read-only access remains a hard constraint.
- No change to the Codex provider, no browser-cookie path, no delegated CLI refresh.
- No new UI. The fallback is invisible above `ClaudeCredentialReading`.

## Phase 0 — capture evidence (before any code)

The exact file contract is documented second-hand; verify it first and record it in
`docs/endpoints.md` alongside the existing keychain evidence:

- [ ] Confirm path and precedence: `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json`,
      permissions `600`. (Requires user approval to inspect the live file — capture
      key *names only*, never token values.)
- [ ] Confirm the JSON shape matches the keychain payload (top-level `claudeAiOauth`,
      `expiresAt` in epoch **milliseconds**) so `ClaudeCredentialParser` works unchanged.
- [ ] Add sanitized fixtures:
      `Tests/Fixtures/claude-credentials-file.json` (valid file payload) and
      `Tests/Fixtures/claude-keychain-mcponly.json` (keychain payload with only
      `mcpOAuth`, reproducing failure mode 1).
- [ ] If the file does not exist on this machine, keep the plan but mark the shape as
      "per CodexBar docs / Claude Code Linux behavior"; the parser already degrades an
      unexpected shape to `.parseFailure` stale, so a wrong guess cannot crash.

## Design

### New type: `ClaudeCredentialsFileStore`

A second `CredentialStore` implementation (same protocol as `KeychainCredentialStore`,
so the existing "read-only surface" test coverage applies):

- `read(.claude, mode:)` returns the file's `Data`, `nil` when the file is absent, and
  throws `CredentialStoreReadError.unavailable` when the file exists but is unreadable.
- Ignores `mode` — a file read cannot prompt, so `.background` needs no special casing.
- Path resolution injected for testability: `init(fileURL: URL)` plus a default that
  resolves `CLAUDE_CONFIG_DIR` from an injected `environment: [String: String]`
  (default `ProcessInfo.processInfo.environment`) and falls back to
  `~/.claude/.credentials.json`.

### `ClaudeCredentialReader` gains a fallback slot

- New optional `fallbackStore: (any CredentialStore)?` (default `nil`, so existing
  call sites and tests are unaffected until wired).
- Extract the current parse-and-check-expiry body into a private
  `evaluate(_ data: Data?) -> ClaudeCredentialReadResult` used for both sources.
- Fetch order per `read(mode:)`:
  1. Keychain (mode threaded through, exactly as today). Fresh → return; file untouched
     (no extra IO on the happy path).
  2. Otherwise consult the file. Fresh → return. This covers keychain-parse-failure
     (failure mode 1), keychain-denied (failure mode 2), keychain-item-missing, and
     keychain-expired-but-file-fresh (sources can drift while the CLI migrates storage).
- **Both-fail reason rule:**
  - File **absent** (`nil` data) → surface the keychain's reason. Standard macOS
    machines keep today's behavior exactly; zero regression risk.
  - File **present but unusable** (malformed → `.parseFailure`, expired →
    `.tokenExpired`) → the file's reason wins. A present credentials file is the
    stronger evidence of real CLI state (the keychain may hold only `mcpOAuth` noise).
  - File store **throws** (exists but unreadable) → keep the keychain's reason; an
    unreadable file proves nothing about CLI state.

### Wiring

`UsageBarShellModel.live()` constructs the reader with
`fallbackStore: ClaudeCredentialsFileStore()`. `UsagePoller`, `ClaudeUsageProvider`,
and all view code are untouched.

## Phase 1 — TDD slices (red–green–refactor, one behavior per cycle)

`ClaudeCredentialsFileStore` (new test file `CredentialsFileStoreTests.swift`, temp
dirs via `FileManager`):

1. Returns the file's data for an injected URL.
2. Returns `nil` when the file is absent.
3. Throws `.unavailable` when the file exists but is unreadable (chmod 000 in a temp dir).
4. Default path honors `CLAUDE_CONFIG_DIR` from the injected environment, else
   `~/.claude/.credentials.json` (assert on the resolved URL, not real IO).

`ClaudeCredentialReader` fallback (extend `ClaudeCredentialReaderTests`, recording fake
stores):

5. Keychain payload with only `mcpOAuth` + valid file → `.fresh` (the headline fix).
6. Keychain item missing (`nil`) + valid file → `.fresh`.
7. Keychain fresh → fallback store is **never read** (assert zero reads).
8. Keychain expired + fresh file → `.fresh` from the file.
9. Both fail, file absent → keychain's reason surfaces (pin today's behavior).
10. Both fail, file present-but-expired → `.tokenExpired`; present-but-malformed →
    `.parseFailure` (file's reason wins).
11. Fallback store throws → keychain's reason surfaces.
12. Mode is still forwarded to the keychain store only (file store receives whatever
    mode but must not require it — assert reader works with a mode-ignoring fake).

Refactor step: verify `evaluate(_:)` removed duplication between the two source paths;
run the full suite (`scripts/run-swift-tests`) after each slice.

## Phase 2 — wiring + docs

- Wire `ClaudeCredentialsFileStore()` into `.live()`.
- `docs/endpoints.md`: new "Claude credentials file" bullet with path, shape, precedence,
  and the Phase 0 evidence.
- `AGENTS.md`: update the Claude API bullet (credential source becomes
  "Keychain, falling back read-only to `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json`")
  and the `CredentialStore` seam note (two implementations).
- `README.md`: note that if Claude Code stores credentials in the file, no Keychain
  grant is needed for the Claude row.
- Never commit real payloads; fixtures sanitized (existing repo rule).

## Phase 3 — verification

- `scripts/run-swift-tests` (full suite executes, not just builds).
- `swift build` clean under Swift 6 strict concurrency (new type is a `Sendable` struct).
- Manual: `scripts/bundle.sh`, verify `codesign -dvvv` shows the Apple Development
  identity, relaunch, and confirm the Claude row stays fresh. If this machine still
  stores credentials in the keychain, simulate failure mode 1 by pointing
  `CLAUDE_CONFIG_DIR` at a fixture directory in a dev run.

## Risks and open questions

- **File shape unverified on this machine** (Phase 0 gates this). Worst case a wrong
  assumption degrades to `.parseFailure` stale — the status quo, not a regression.
- **Two valid-but-different tokens**: keychain wins by order; acceptable, both came
  from the same CLI login.
- **Secrets hygiene**: the file contains live tokens — never log its contents; tests
  use temp files with fake payloads only.
- **Future drift**: if Claude Code encrypts or relocates the file, the provider
  degrades to stale exactly as today; no crash path is introduced.

## Sizing and sequencing

Small: one new ~40-line type, ~20 changed lines in the reader, ~10 focused tests, doc
updates. Base the branch on `main` after PR #19 (background API polls) merges — #19
touches the same AGENTS.md/README paragraphs, so sequencing avoids doc conflicts.
