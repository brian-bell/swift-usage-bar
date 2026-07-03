# Phase 6 Verification

Recorded for the SwiftUI shell implementation on 2026-07-03.

## Automated and fake-state checks

- Dropdown rows: provider ordering, hidden-provider omission, clamped bar fractions, formatted countdown labels, stale styling flags, stale placeholders.
- Settings persistence: poll interval, provider visibility, threshold percent, launch-at-login preference, and first-run defaults through isolated `UserDefaults` suites.
- Shell intents: menu bar title uses `MenuBarTitleFormatter`, refresh dispatches to the poller controller, provider visibility updates settings plus `AppState`, and launch-at-login success/failure paths are mapped through an injectable manager.

## Local smoke checks

- `swift build && swift test` completed successfully.
- `scripts/run-swift-tests` completed successfully for the CommandLineTools Swift Testing harness.
- `.build/arm64-apple-macosx/debug/AIUsageBarApp` launched and stayed running for 3 seconds before being terminated by the smoke check.

## Bundle check

- Not run: this tree does not include `scripts/bundle.sh`.

## Manual UI notes

- Full menu-bar interaction remains a local human check because this phase has no UI automation harness for opening the macOS menu extra. The fake-state tests cover the planned stale, visibility, refresh, settings persistence, and launch-at-login decision logic without mutating real Keychain entries.
