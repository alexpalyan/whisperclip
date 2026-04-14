---
phase: 2
slug: viewmodel-extraction
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-21
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest |
| **Config file** | `Package.swift` (WhisperClipTests target) |
| **Quick run command** | `swift test --filter HotkeySettingsViewModelTests` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~10 seconds |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter {CurrentVM}Tests`
- **After every plan wave:** Run `swift test`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** ~10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 2-??-01 | 01 | 0 | VM-01 | unit stub | `swift test --filter HotkeySettingsViewModelTests` | ❌ W0 | ⬜ pending |
| 2-??-02 | 01 | 0 | VM-02 | unit stub | `swift test --filter LLMModelViewModelTests` | ❌ W0 | ⬜ pending |
| 2-??-03 | 01 | 0 | VM-03 | unit stub | `swift test --filter PromptManagementViewModelTests` | ❌ W0 | ⬜ pending |
| 2-??-04 | TBD | 1 | VM-01 | unit | `swift test --filter HotkeySettingsViewModelTests` | ❌ W0 | ⬜ pending |
| 2-??-05 | TBD | 1 | VM-02 | unit | `swift test --filter LLMModelViewModelTests` | ❌ W0 | ⬜ pending |
| 2-??-06 | TBD | 1 | VM-03 | unit | `swift test --filter PromptManagementViewModelTests` | ❌ W0 | ⬜ pending |
| 2-??-07 | TBD | 1 | VM-04 | build | `swift build` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Tests/HotkeySettingsViewModelTests.swift` — stubs for VM-01
- [ ] `Tests/LLMModelViewModelTests.swift` — stubs for VM-02
- [ ] `Tests/PromptManagementViewModelTests.swift` — stubs for VM-03
- [ ] Test helpers: `SettingsStore` init with `UserDefaults(suiteName: UUID().uuidString)` for isolation
- [ ] `HotkeyManager` test double or injectable protocol for VM-01 side-effect testing

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Settings UI fully functional after extraction | VM-04 | Requires running app + UI interaction | Launch app, open Settings, verify all tabs work: hotkeys register, LLM downloads, prompts CRUD |
| HotkeyManager registers system hotkey | VM-01 | System-level side effect | Change hotkey in Settings, verify new hotkey triggers recording |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
