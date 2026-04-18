---
phase: 10
slug: mutable-data-model
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-18
---

# Phase 10 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Swift Package Manager) |
| **Config file** | none — Standard SPM |
| **Quick run command** | `swift test --filter MeetingSegmentTests` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter MeetingSegmentTests`
- **After every plan wave:** Run `swift test`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 10-01-01 | 01 | 1 | MUT-01 | — | N/A | unit | `swift test --filter ObservationTests` | ✅ | ✅ green |
| 10-01-02 | 01 | 1 | MUT-02 | — | N/A | unit | `swift test --filter MeetingSegmentTests` | ✅ | ✅ green |
| 10-01-03 | 01 | 1 | MUT-03 | — | N/A | unit | `swift test --filter PersistenceTests` | ✅ | ✅ green |
| 10-02-01 | 02 | 2 | DIAR-01 | — | N/A | unit | `swift test --filter BufferSplitTests` | ✅ | ✅ green |
| 10-02-02 | 02 | 2 | DIAR-02 | — | N/A | integration | `swift test --filter DiarizerMicroWindowTests` | ✅ | ✅ green |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] `Tests/ObservationTests.swift` — MUT-01 coverage present
- [x] `Tests/MeetingSegmentTests.swift` — MUT-02 coverage present
- [x] `Tests/PersistenceTests.swift` — MUT-03 coverage present
- [x] `Tests/BufferSplitTests.swift` — DIAR-01 coverage present
- [x] `Tests/DiarizerMicroWindowTests.swift` — DIAR-02 coverage present

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Bubble visually updates in-place without full-list reload | MUT-01 | Requires running app + UI observation | Start a session, observe a pending segment resolve to final text/speaker without flicker or position jump |
| Silence does not create failed transcript bubbles | MUT-01 | Requires live mic capture + app observation | Start a session, stay silent for 10-15 seconds, verify no `transcription failed` bubbles appear |
| Diarizer micro-window triggers correct speaker-change split | DIAR-01 / DIAR-02 | Requires live audio with real speaker changes | Record 2-person conversation or replay system audio with two distinct speakers, verify segments don't blend across speaker boundaries |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 30s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** updated after Phase 10 execution audit on 2026-04-18

---

## UAT Outcome

**Status:** PASS

Phase 10 passes UAT for its primary objective: transcript rows are now mutable, pending segments can finalize in place, and chat-style transcript messages update live without replacing the entire segment.

### Known Limitations Carried Forward

- Silence-handling and pending-bubble suppression improved, but brief transient pending UI may still appear in edge cases during uncertain speech detection.
- Speaker-boundary quality is improved but not fully final; some mixed speaker attribution or small start/end truncation may still occur near split boundaries.
- Diarization and boundary-handling are expected to be substantially revisited in Phases 11 and 12, so remaining edge cases are accepted for this phase.
