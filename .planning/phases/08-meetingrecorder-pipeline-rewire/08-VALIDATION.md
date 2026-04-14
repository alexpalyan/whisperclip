---
phase: 8
slug: meetingrecorder-pipeline-rewire
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-22
---

# Phase 8 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest |
| **Config file** | none |
| **Quick run command** | `swift test --filter MeetingRecorderTests` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter MeetingRecorderTests`
- **After every plan wave:** Run `swift test`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 08-01-01 | 01 | 1 | PIPE-08-01 | integration | `swift test --filter MeetingRecorderTests` | ❌ Wave 0 | ⬜ pending |
| 08-01-01 | 01 | 1 | PIPE-08-02 | integration | `swift test --filter MeetingRecorderTests` | ❌ Wave 0 | ⬜ pending |
| 08-01-01 | 01 | 1 | PIPE-08-03 | unit | `swift test --filter MeetingRecorderTests` | ❌ Wave 0 | ⬜ pending |
| 08-01-02 | 01 | 1 | dead-code | build | `swift build 2>&1 \| grep -c error:` returns 0 | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Tests/MeetingRecorderTests.swift` — mock `SpeakerBufferManager` and `DualChannelAudioCapture` to verify:
  - Consumer loop processes `ClosedSpeakerBuffer` items from `AsyncStream`
  - `activeSpeakerLabel` updates before ASR enqueue (Zero Data Loss timing)
  - Teardown order: stop manager → await consumer → drain queue

*If Wave 0 stubs are too complex for the phase (integration tests require real audio stack): mark as Manual-Only and note here.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Two-person meeting produces alternating speaker labels | PIPE-08-01 | Requires live audio from two microphones / screen capture | Record a 30s meeting with two speakers, check MeetingDetailView for alternating "Me" / "Speaker 1" labels |
| `activeSpeakerLabel` updates before ASR text appears | PIPE-08-02 | Timing contract requires visual inspection of real-time UI | Start recording, observe waveform color change precedes transcript update |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
