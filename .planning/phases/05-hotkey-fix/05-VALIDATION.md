---
phase: 5
slug: hotkey-fix
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-22
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (built-in, Swift Package Manager) |
| **Config file** | `Package.swift` testTarget `WhisperClipTests` |
| **Quick run command** | `swift test --filter HotkeySettingsViewModelTests` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter HotkeySettingsViewModelTests`
- **After every plan wave:** Run `swift test`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 5-01-01 | 01 | 1 | CONTEXT locked | unit/regression | `swift test --filter HotkeySettingsViewModelTests` | ✅ | ⬜ pending |
| 5-01-02 | 01 | 1 | CONTEXT locked | unit/regression | `swift test --filter HotkeySettingsViewModelTests` | ✅ | ⬜ pending |
| 5-01-03 | 01 | 1 | CONTEXT locked | build | `swift build` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] Optional: `Tests/WhisperClipTests/HotkeyAppDelegateSmokeTests.swift` — smoke test for AppDelegate wiring: after calling `applicationDidFinishLaunching`, both shared managers have been given `updateSystemHotkey` calls

*Existing `HotkeySettingsViewModelTests.swift` covers ViewModel layer and remains valid with unchanged `HotkeyManaging` protocol. Wave 0 test file is optional — existing infrastructure sufficient for green suite.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Hotkey registers at launch (recording) | CONTEXT: launch-time registration | AppDelegate.applicationDidFinishLaunching not easily unit-testable | Launch app, press configured hotkey, verify recording starts |
| Hotkey registers at launch (meeting) | CONTEXT: HotkeyManager.meetingShared wiring | AppDelegate.applicationDidFinishLaunching not easily unit-testable | Launch app, press configured meeting hotkey, verify meeting recording starts |
| Settings change propagates to OS hotkey | CONTEXT: Combine subscriptions | Requires real OS hotkey registration | Change hotkey in Settings; without relaunch, press new hotkey, verify it works |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
