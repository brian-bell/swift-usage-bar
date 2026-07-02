# Endpoint Discovery

Phase 0 source checks and live-call results for the read-only usage providers.

## Claude

- Auth source: macOS Keychain generic password with service `Claude Code-credentials`.
- Credential shape: top-level `claudeAiOauth` object with `accessToken`, `refreshToken`, `expiresAt`, `scopes`, `subscriptionType`, and `rateLimitTier`.
- Expiry detection: treat `claudeAiOauth.expiresAt` as the OAuth token expiry timestamp.
- Usage request: `GET https://api.anthropic.com/api/oauth/usage`.
- Headers: `Authorization: Bearer <claudeAiOauth.accessToken>` and `anthropic-beta: oauth-2025-04-20`.
- Source evidence: local Claude Code 2.1.198 binary strings include `fetchUtilization: GET /api/oauth/usage`, `/api/oauth/usage`, `anthropic-beta`, and `oauth-2025-04-20`.
- Live result: the controlled `curl` attempt on 2026-07-02 returned HTTP 429, so `Tests/Fixtures/claude-usage.json` was not created. Do not fabricate this fixture.
- Local fallback: `scripts/claude-statusline-cache` can be used as the Claude Code statusline command. It writes the raw statusline JSON to `${XDG_CACHE_HOME:-$HOME/.cache}/ai-usage-bar/claude-status.json` or `AI_USAGE_BAR_CLAUDE_STATUS_JSON`, then forwards the same stdin to `ccstatusline`. This lets the app consume `rate_limits` from Claude Code's own statusline payload without calling the usage endpoint directly.
- Fallback fixture: `Tests/Fixtures/claude-statusline.json` preserves the sanitized statusline shape used by `ccstatusline` 2.2.22. The relevant fields are `rate_limits.five_hour.used_percentage`, `rate_limits.five_hour.resets_at`, `rate_limits.seven_day.used_percentage`, and `rate_limits.seven_day.resets_at`; `resets_at` is Unix epoch seconds.

## Codex

- Auth source: macOS Keychain generic password with service `Codex Auth` and account `cli|<sha256(canonical CODEX_HOME)[0..<16]>`. For `/Users/brian/.codex`, the discovered account is `cli|546fd934022c2d7b`.
- Credential shape: JSON with `auth_mode`, `last_refresh`, and `tokens`. The `tokens` object has `access_token`, `refresh_token`, `id_token`, and `account_id`.
- Expiry detection: parse the JWT payload from `tokens.access_token` and read the standard `exp` claim; Codex refreshes inside a 5-minute window.
- Usage request: `GET https://chatgpt.com/backend-api/wham/usage` for the default ChatGPT base URL. The same backend client maps non-`/backend-api` Codex API base URLs to `/api/codex/usage`.
- Headers: `Authorization: Bearer <tokens.access_token>`, `ChatGPT-Account-Id: <tokens.account_id>`, and Codex's user agent.
- Source evidence: `openai/codex` tag `rust-v0.142.5`, especially `codex-rs/login/src/auth/storage.rs`, `codex-rs/login/src/token_data.rs`, `codex-rs/login/src/auth/manager.rs`, `codex-rs/backend-client/src/client.rs`, and `codex-rs/backend-client/src/client/rate_limit_resets.rs`.
- Live result: the controlled `curl` attempt succeeded and produced the sanitized fixture at `Tests/Fixtures/codex-usage.json`.
