---
phase: 6
slug: speakerbuffermanager-actor
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-22
---

# Phase 6 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (bundled with Xcode) |
| **Config file** | `Package.swift` — testTarget `WhisperClipTests` |
| **Quick run command** | `swift test --filter SpeakerBufferManagerTests` |
| **Full suite command** | `swift test --parallel --verbose` |
| **Estimated runtime** | ~15 seconds (unit tests only; no CoreML model load) |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter SpeakerBufferManagerTests`
- **After every plan wave:** Run `swift test --parallel --verbose`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** ~15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 6-W0-01 | Wave 0 | 0 | PIPE-01..06, SPKR-01..03 | unit stubs | `swift test --filter SpeakerBufferManagerTests` | ❌ W0 | ⬜ pending |
| 6-W0-02 | Wave 0 | 0 | all | mock infra | `swift test --filter MockDiarizationProviderTests` | ❌ W0 | ⬜ pending |
| 6-01-xx | Plan 01 | 1 | PIPE-01 | unit | `swift test --filter SpeakerBufferManagerTests/testOnAudioBatchAppends` | ❌ W0 | ⬜ pending |
| 6-01-xx | Plan 01 | 1 | PIPE-01 | unit | `swift test --filter SpeakerBufferManagerTests/testConcurrentBatchIngestion` | ❌ W0 | ⬜ pending |
| 6-01-xx | Plan 01 | 1 | PIPE-02 | unit | `swift test --filter SpeakerBufferManagerTests/testSpeakerChangeFlushesPreviousBuffer` | ❌ W0 | ⬜ pending |
| 6-01-xx | Plan 01 | 1 | PIPE-03 | unit | `swift test --filter SpeakerBufferManagerTests/testMaxDurationCapForceFlush` | ❌ W0 | ⬜ pending |
| 6-01-xx | Plan 01 | 1 | PIPE-04 | unit | `swift test --filter SpeakerBufferManagerTests/testEmittedBufferHasResolvedLabel` | ❌ W0 | ⬜ pending |
| 6-01-xx | Plan 01 | 1 | PIPE-06 | unit | `swift test --filter SpeakerBufferManagerTests/testShortBufferDiscarded` | ❌ W0 | ⬜ pending |
| 6-01-xx | Plan 01 | 1 | PIPE-06 | unit | `swift test --filter SpeakerBufferManagerTests/testStopFlushesAdequateBuffer` | ❌ W0 | ⬜ pending |
| 6-01-xx | Plan 01 | 1 | SPKR-01 | unit | `swift test --filter SpeakerBufferManagerTests/testSpeakerLabelStability` | ❌ W0 | ⬜ pending |
| 6-01-xx | Plan 01 | 1 | SPKR-02 | unit | `swift test --filter SpeakerBufferManagerTests/testDiarizerConfigThreshold` | ❌ W0 | ⬜ pending |
| 6-01-xx | Plan 01 | 1 | SPKR-03 | unit | `swift test --filter SpeakerBufferManagerTests/testSpeakerLabelOrdering` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Tests/WhisperClipTests/SpeakerBufferManagerTests.swift` — stubs for all 10 test cases (PIPE-01..04, PIPE-06, SPKR-01..03)
- [ ] `Tests/WhisperClipTests/MockDiarizationProvider.swift` — shared mock conforming to `DiarizationProvider`; `nextResult` property for test control

*No framework install needed — XCTest already present in `WhisperClipTests` target.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| CoreML latency at 150ms polling cadence | PIPE-02 | Requires real M-series hardware + FluidAudio model download | Profile with Instruments Time Profiler during a live recording; verify poll does not consistently exceed 150ms on M4 |
| End-to-end diarization accuracy | SPKR-01, SPKR-02, SPKR-03 | Requires Phase 7+8 integration with real audio | Validate post-Phase 8 in a two-person meeting — confirm alternating speaker labels match actual speakers |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
