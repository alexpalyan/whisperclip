---
phase: 4
slug: test-coverage
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-21
---

# Phase 4 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (built-in, macOS 14+) |
| **Config file** | `Package.swift` — `.testTarget(name: "WhisperClipTests", dependencies: ["WhisperClip"], path: "Tests")` |
| **Quick run command** | `swift test --filter HotkeySettingsViewModelTests` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~10 seconds |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter <TestClassName>`
- **After every plan wave:** Run `swift test`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** ~10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 4-01-01 | 01 | 1 | TEST-01 | unit | `swift test --filter HotkeySettingsViewModelTests` | ❌ Wave 0 | ⬜ pending |
| 4-01-02 | 01 | 1 | TEST-01 | unit | `swift test --filter HotkeySettingsViewModelTests` | ❌ Wave 0 | ⬜ pending |
| 4-02-01 | 02 | 2 | TEST-02 | unit | `swift test --filter PromptManagementViewModelTests` | ❌ Wave 0 | ⬜ pending |
| 4-03-01 | 03 | 2 | TEST-03 | unit | `swift test --filter LLMModelViewModelTests` | ❌ Wave 0 | ⬜ pending |
| 4-04-01 | 04 | 2 | TEST-04 | unit | `swift test --filter PromptSwiftDataTests` | ❌ Wave 0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Sources/HotkeyManager.swift` — add `HotkeyManaging` protocol + `HotkeyManager` conformance (prerequisite for TEST-01)
- [ ] `Sources/HotkeySettingsViewModel.swift` — change stored property types from `HotkeyManager` to `any HotkeyManaging`
- [ ] `Sources/SettingsStore.swift` — change `private init(container:)` to `init(defaults: UserDefaults = .standard, container: ModelContainer? = nil)`, replace `private let defaults = UserDefaults.standard` with injected `defaults`
- [ ] `Tests/HotkeySettingsViewModelTests.swift` — ≥5 tests for TEST-01
- [ ] `Tests/PromptManagementViewModelTests.swift` — ≥4 tests for TEST-02
- [ ] `Tests/LLMModelViewModelTests.swift` — ≥2 tests for TEST-03
- [ ] `Tests/PromptSwiftDataTests.swift` — ≥2 tests for TEST-04
- [ ] `Tests/TestDoubles/NullHotkeyManager.swift` — no-op `HotkeyManaging` conformance for injection in hotkey tests

*All files are Wave 0 — none exist yet. Source refactors must complete before test files can compile.*

---

## Manual-Only Verifications

*If none: "All phase behaviors have automated verification."*

All phase behaviors have automated verification via `swift test`.

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
