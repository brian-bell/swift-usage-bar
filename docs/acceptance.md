# Acceptance Evidence

Date: 2026-07-03

| Field | Value |
|---|---|
| Code commit tested | `e94d6785cef7476cbad50ba6adf7519ea6b54e57` |
| macOS | 26.5.2, build 25F84 |
| App bundle path | `/Users/brian/dev/mac-ai-usage-bar-worktrees/flow-phase-7-bundle-login-item-acceptance/AIUsageBar.app` |
| Bundle identifier | `dev.brianbell.AIUsageBar` |
| Bundle executable | `AIUsageBarApp` |
| `LSUIElement` | `true` |

## Verification Commands

| Check | Status | Evidence |
|---|---|---|
| `scripts/run-swift-tests` | Pass | Completed before Phase 7 edits and again during final closeout. |
| `swift build` | Pass | Completed before Phase 7 edits and again during final closeout. |
| `swift test --enable-swift-testing` | Pass | Completed before Phase 7 edits and again during final closeout. |
| `Tests/Scripts/bundle-script-test.sh` | Pass | Built an isolated temp app, removed stale bundle contents, verified the bundle, and ran `codesign -v`. |
| `./scripts/bundle.sh` | Pass | Created the default signed `AIUsageBar.app`. |
| `./scripts/bundle.sh --verify` | Pass | Verified the default app bundle structure, plist fields, executable bit, and code signature. |
| `codesign -v AIUsageBar.app` | Pass | Exited 0. |
| `open AIUsageBar.app` | Pass | Started process `AIUsageBar.app/Contents/MacOS/AIUsageBarApp` from the signed bundle path. |

## Manual Acceptance Checklist

| Item | Status | Evidence |
|---|---|---|
| Launch at login enable, approval state, System Settings Login Items presence, logout/login relaunch, disable | Not run | The app was launched from the signed bundle, but the login item toggle, System Settings approval, logout/login, and unregister check were not performed in this agent session. |
| Fresh boot or session start shows numbers within 2 minutes | Not run | No logout/login or reboot was performed. |
| Wi-Fi off greys values and app does not crash | Not run | Wi-Fi was not disabled in this session. |
| Expired token shows stale hint text after natural expiry | Not run | Provider token expiry was not reached; credentials were not mutated. |
| Notification fires once when crossing the 20% threshold | Not run | Notification permission and a live threshold crossing were not exercised. |
| CPU near 0% between polls | Pass | `ps -p <pid> -o %cpu=` sampled the launched app at 2026-07-03T19:16:10Z, 19:16:40Z, 19:17:10Z, 19:17:40Z, and 19:18:10Z. Samples were `0.0`, `0.0`, `0.0`, `0.0`, `0.0`. |

Unchecked manual items are recorded as `Not run` rather than inferred from automated bundle checks.
