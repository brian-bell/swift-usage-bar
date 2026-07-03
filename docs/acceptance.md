# Acceptance Evidence

Date: 2026-07-03

| Field | Value |
|---|---|
| Phase 7 bundle code commit tested | `c169b549f1ed5ed1064ad4446eb1f0aa3c01db49` |
| Evidence document note | This file is updated in a later docs-only commit; the bundle code commit above is the revision verified. |
| macOS | 26.5.2, build 25F84 |
| App bundle path | `/Users/brian/dev/mac-ai-usage-bar-worktrees/flow-phase-7-bundle-login-item-acceptance/AIUsageBar.app` |
| Bundle identifier | `dev.brianbell.AIUsageBar` |
| Bundle executable | `AIUsageBarApp` |
| `LSUIElement` | `true` |

## Verification Commands

| Check | Status | Evidence |
|---|---|---|
| `scripts/run-swift-tests` | Pass | Review-loop rerun after `c169b54`; exit 0. Output showed debug SwiftPM builds completed for the harness commands. |
| `Tests/Scripts/bundle-script-test.sh` | Pass | Review-loop rerun after `c169b54`; exit 0. Covered verifier rejection for missing/invalid plist, wrong plist values, missing/non-executable executable, unsigned bundle, unsafe output paths, stale bundle replacement, successful verification, and `codesign -v`. |
| `swift build` | Pass | Review-loop rerun after `c169b54`; exit 0. Output ended with `Build complete! (0.09s)`. |
| `swift test --enable-swift-testing` | Pass | Review-loop rerun after `c169b54`; exit 0. Output ended with `Build complete! (0.08s)`. |
| `./scripts/bundle.sh` | Pass | Review-loop rerun after `c169b54`; exit 0. Built the release product, signed staged bundle `.AIUsageBar.bundle.ZOVaQ1/AIUsageBar.app`, verified it, and moved it to the default app path. |
| `./scripts/bundle.sh --verify` | Pass | Review-loop rerun after `c169b54`; exit 0 with no output. |
| `codesign -v AIUsageBar.app` | Pass | Review-loop rerun after `c169b54`; exit 0 with no output. |
| `open AIUsageBar.app` | Pass | Implementation-phase check started process `AIUsageBar.app/Contents/MacOS/AIUsageBarApp` from the signed bundle path; not rerun during review-loop script hardening. |

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
