---
phase: 07
slug: dualchannelaudiocapture-streaming-callback
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-03-22
---

# Phase 07 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest |
| **Config file** | Package.swift |
| **Quick run command** | `swift test --filter DualChannelAudioCaptureTests` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter DualChannelAudioCaptureTests`
- **After every plan wave:** Run `swift test`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | Status |
|---------|------|------|-------------|-----------|-------------------|--------|
| 07-01-00 | 01 | 0 | PIPE-05 | Scaffold | `test -f Tests/DualChannelAudioCaptureTests.swift` | ⬜ pending |
| 07-01-01 | 01 | 1 | PIPE-05 | Unit + Regression | `swift test --filter DualChannelAudioCaptureTests` | ⬜ pending |
| 07-01-02 | 01 | 1 | PIPE-05 | Regression | `swift test --filter AudioRecorderTests` | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Task 0 creates `Tests/DualChannelAudioCaptureTests.swift` with two unit tests for the `processSystemAudioSamples` helper method. These tests will not compile until Task 1 adds the internal helper to `DualChannelAudioCapture`. This is intentional — Task 0 is the RED step (test exists, code does not yet).

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| System audio batches arrive in real time during live recording | PIPE-05 (integration) | Requires live ScreenCaptureKit stream + SpeakerBufferManager actor running | Start a recording session, play audio from another app, confirm SpeakerBufferManager receives samples; check logs for "onSystemBatch called" |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 30s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved
