---
phase: 11
slug: live-transcription-stream
status: complete-with-carryover
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-18
---

# Phase 11 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest |
| **Config file** | none — existing test target |
| **Quick run command** | `swift test --filter StreamingTests` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `swift build`
- **After every plan wave:** Run `swift test --filter StreamingTests`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|--------|
| 11-01-01 | 01 | 0 | LIVE-01 | — | N/A | unit | `swift test --filter StreamingTests` | ✅ green |
| 11-01-02 | 01 | 0 | LIVE-02 | — | N/A | unit | `swift test --filter StreamingTests` | ✅ green |
| 11-02-01 | 02 | 1 | LIVE-01 | — | N/A | build | `swift build` | ✅ green |
| 11-03-01 | 03 | 1 | LIVE-02 | — | N/A | unit | `swift test --filter MeetingSegmentTests` | ✅ green |
| 11-03-02 | 03 | 1 | LIVE-02 | — | N/A | unit | `swift test --filter ObservationTests` | ✅ green |
| 11-04-01 | 04 | 2 | LIVE-01 | — | N/A | build | `swift build` | ✅ green |
| 11-04-02 | 04 | 2 | LIVE-03 | — | N/A | build | `swift build` warning-clean | ❌ red |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] `Tests/StreamingTests.swift` — stubs for LIVE-01/LIVE-02/LIVE-03 model-facing checks

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Tokens appear word-by-word during mic recording | LIVE-01 | Requires live hardware audio | Start meeting, speak for 5s, observe text appearing incrementally in gray |
| System audio shows `[Pending]` label | LIVE-02 | Requires system audio capture | Play audio from another app, verify segment label shows `[Pending]` |
| Text transitions from gray to primary after chunk completes | LIVE-01 | Visual state transition | Observe color change after chunk finalizes |
| No audio samples dropped between chunks | LIVE-03 | Requires live session analysis | Record 30s, verify transcript is continuous with no gaps |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** complete with carry-over warning debt (`swift build` not warning-clean).
