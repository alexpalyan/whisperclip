---
phase: 9
slug: waveform-color-per-speaker
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-03-22
---

# Phase 9 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest |
| **Config file** | WhisperClip.xcodeproj |
| **Quick run command** | `swift test` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `swift test`
- **After every plan wave:** Run `swift test`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 09-00-01 | 00 | 0 | RT-01, RT-02, RT-03 | scaffold | `swift test --filter "SharedViewsTests\|WaveformHistoryTests\|SpeakerResolutionTests"` | Created in W0 | pending |
| 09-01-01 | 01 | 1 | RT-02 | unit | `swift test --filter SharedViewsTests` | Tests/SharedViewsTests.swift | pending |
| 09-01-02 | 01 | 1 | RT-03 | unit | `swift test --filter SpeakerResolutionTests` | Tests/SpeakerResolutionTests.swift | pending |
| 09-02-01 | 02 | 2 | RT-01, RT-03 | unit | `swift test --filter WaveformHistoryTests` | Tests/WaveformHistoryTests.swift | pending |
| 09-02-02 | 02 | 2 | RT-01, RT-03 | manual | Visual inspection during recording | N/A | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

- [x] `Tests/SharedViewsTests.swift` — unit tests for `speakerPaletteColor()` with new hex values (created in 09-00)
- [x] `Tests/WaveformHistoryTests.swift` — unit tests for waveform history logic (created in 09-00)
- [x] `Tests/SpeakerResolutionTests.swift` — unit tests for Speaker(displayName:) resolution (created in 09-00)

*Wave 0 plan: 09-00-PLAN.md creates all three stubs.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Waveform color changes at moment of speaker detection | RT-03 | Visual timing — requires live recording session | Start a recording with two speakers; confirm waveform bar color snaps immediately on speaker change without ASR delay |
| Scrolling color history visible | RT-01 | Visual — history scroll is a rendering behavior | Record 3 speaker turns; confirm old bars retain their speaker colors while new bars show current speaker |
| Noise floor scaling visible | RT-01 | Visual — bar height rendering | During quiet passages, confirm bars render at small but visible height (4pt min), not invisible |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 30s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** ready
