---
gsd_state_version: 1.0
milestone: v1.2
milestone_name: Live Enrichment & Diarization Fix
status: Phase 10 complete; ready for Phase 11
stopped_at: Phase 10 PASS (10-01 and 10-02 complete)
last_updated: "2026-04-18T16:59:21Z"
progress:
  total_phases: 4
  completed_phases: 1
  total_plans: 2
  completed_plans: 2
  percent: 25
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-22)

**Core value:** Точна транскрипція зустрічей з правильною атрибуцією спікерів.
**Current focus:** Phase 11 — live-transcription-stream

---

## Current Position

Phase: 10 (mutable-data-model) — COMPLETE
Next: Phase 11 (live-transcription-stream) — READY

## Performance Metrics

**Velocity (v1.0 complete):**

- Total plans completed: 14
- v1.0 phases: 5 complete

**v1.1 By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 6. SpeakerBufferManager Actor | TBD | - | - |
| 7. DualChannelAudioCapture | TBD | - | - |
| 8. MeetingRecorder Rewire | TBD | - | - |
| 9. Waveform Color | TBD | - | - |
| 10. Chat Bubble UI | TBD | - | - |

| Phase 06 P01 | 115s | 2 tasks | 4 files |

---
| Phase 06 P02 | 223 | 2 tasks | 3 files |
| Phase 06 P03 | 5min | 2 tasks | 2 files |
| Phase 08 P01 | 8m | 3 tasks | 3 files |
| Phase 08 P02 | 16m | 2 tasks | 2 files |
| Phase 09-waveform-color-per-speaker P01 | 225s | 2 tasks | 3 files |
| Phase 09-waveform-color-per-speaker P00 | 3m | 1 tasks | 3 files |
| Phase 09-waveform-color-per-speaker P03 | 6min | 2 tasks | 4 files |
| Phase 09-waveform-color-per-speaker P04 | 7min | 2 tasks | 2 files |

## Accumulated Context

### v1.0 SettingsView Refactoring — Completed (Phases 1-5)

- Phase 1: UI Decomposition ✓
- Phase 2: ViewModel Extraction ✓
- Phase 3: SwiftData Migration ✓
- Phase 4: Test Coverage (18 tests) ✓
- Phase 5: Hotkey Fix (KeyboardShortcuts 2.4.0, AppDelegate) ✓

### Diarization Debug Session (2026-03-22)

- DiarizerManager wired into MeetingRecorder (was never called before)
- Me label regression fixed: mic audio returns .me immediately, skips diarizer
- clusteringThreshold lowered 0.7 → 0.4 → 0.3 (speakerThreshold 0.84 → 0.48 → 0.36)
- Speaker 2 now detected: distance 0.437 > speakerThreshold 0.36 ✓
- Root problem: resolveSpeaker() returns ONE dominant speaker per chunk — minority speaker lost
- New milestone: full pipeline rewrite — diarization-first, per-speaker buffers, atomic ASR

### Key Decisions (v1.1)

- Hybrid splitting: speaker change trigger + 30s max duration cap (PIPE-02, PIPE-03)
- 0.5s minimum floor: buffers < 8,000 samples discarded without ASR (PIPE-06)
- Colored waveform (not name chip) for real-time speaker feedback (RT-01..03)
- Chat-style bubbles (iMessage) for MeetingDetailView grouping (CHAT-01..04)
- Never reset DiarizerManager between turns — destroys SpeakerManager state
- `SWIFT_STRICT_CONCURRENCY=complete` must be enabled before first line of Phase 6
- Extracted TranscriptionQueue to top-level file in Phase 6 (not Phase 8) to keep actor promotion isolated from pipeline rewiring (06-03)
- TranscriptionQueue uses internal access (not public) — WhisperClip is single-module, no ABI boundary needed (06-03)
- MeetingRecorder updates `activeSpeakerLabel` from `ClosedSpeakerBuffer` arrival before enqueueing ASR work (08-01)
- `stopRecording()` now follows producer stop, consumer join, capture stop, queue drain, then final mic processing to avoid dropping the last speaker turn (08-01)
- MeetingRecorder no longer owns system speaker-label mapping or system-text deduplication; fallback attribution uses `source.speaker` with mic-only deduplication (08-01)
- MeetingRecorder now buffers non-diarized system audio locally and routes 5-second `.system` chunks through `TranscriptionQueue` when the diarizer is unavailable (08-02)
- System audio fallback preserves overflow samples beyond 5 seconds and flushes the remainder during `stopRecording()` to avoid data loss (08-02)
- Use explicit `Color(hex:)` palette entries in `speakerPaletteColor()` so waveform and chat bubbles share deterministic speaker colors (09-01)
- Map empty `activeSpeakerLabel` values to `.unknown` through `Speaker(displayName:)` for idle-state safety (09-01)
- Establish Wave 0 XCTest stubs before implementation waves so filtered test commands are stable and meaningful (09-00)
- Route MeetingWaveformView active bars through `speakerPaletteColor(Speaker(displayName:))` to keep palette identity aligned with chat bubbles (09-03)
- Normalize waveform bar heights using `20*log10` with `-50dB` floor and `2px` minimum for stable low-signal rendering (09-03)
- Set `activeSpeakerLabel` to `Speaker.me.displayName` at mic chunk ingress so waveform color reflects local speech immediately (09-04)
- Lock mic-source identity with regression checks for `Speaker.me.displayName`, `Speaker(displayName:)`, color index, and `AudioSource.microphone.speaker` mapping (09-04)
- TEMP (2026-03-23 11:30 prep): Disable diarization pipeline in `MeetingRecorder`; use continuous source-based streaming path (`mic -> "Me"`, system/non-mic -> `activeSpeakerLabel = ""`) until explicit re-enable decision
- Phase 10 restored mutable transcript segments via `@Observable` `MeetingSegment`, pending/finalize APIs in `MeetingSession`, and in-place transcript row updates without replacing list elements
- Phase 10 re-enabled diarizer processing with 7-second micro-windows, sample-accurate split helpers, and pending transcript finalization for diarized buffers
- Phase 10 UAT is accepted as PASS with known carry-over limitations: transient pending UI can still appear in edge cases, and speaker-boundary quality still needs follow-up in Phases 11 and 12

### Blockers/Concerns

- Phase 6: diarization polling cadence (100-200ms) unvalidated against CoreML latency on M-series — measure with Instruments before finalizing
- Phase 6: clusteringThreshold=0.3 validated for one scenario; verify on 3+ speaker pairs before Phase 8 integration
- Phase 7: CMSampleBuffer format assumption (32-bit float PCM) needs assertion verified on macOS 14 and 15
- Phase 10 reduced but did not eliminate split-boundary artifacts; watch for occasional start/end truncation or mixed attribution near speaker changes
- Live transcription still waits on current recorder/ASR chunk flow; Phase 11 remains the milestone-critical step for immediate render behavior
- **Swift Concurrency:** Phase 11 implementation leaves multiple strict-concurrency warnings (queue-handoffs) in `MeetingRecorder`. This is a high-priority tech debt that may impact `Reconciler` stability in Phase 13.

---

## Session Continuity

Last session: 2026-03-23T09:04:53.214Z
Stopped at: Phase 10 PASS (10-01 and 10-02 complete)
Resume file: None
