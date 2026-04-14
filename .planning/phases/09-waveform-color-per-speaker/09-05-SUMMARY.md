---
phase: 09-waveform-color-per-speaker
plan: 05
subsystem: audio
tags: [hotfix, diarization, latency, streaming, meeting]
requires:
  - phase: 09-04
    provides: "Mic path sets activeSpeakerLabel=Me and waveform regression coverage"
provides:
  - "Temporary diarization-off operating mode documented for planning/execution"
  - "Source-based speaker labeling contract for live meeting stability"
affects: [meeting-recorder, waveform, planning]
tech-stack:
  added: []
  patterns: ["operational mode flag in planning docs", "source-based speaker attribution"]
key-files:
  created: [.planning/phases/09-waveform-color-per-speaker/09-05-SUMMARY.md]
  modified: [.planning/PROJECT.md, .planning/STATE.md, .planning/ROADMAP.md, Sources/MeetingRecorder.swift]
key-decisions:
  - "Disable diarization pipeline in MeetingRecorder until explicit re-enable decision"
  - "Prioritize continuous low-latency transcription stream over diarization attribution quality"
  - "Mic path publishes activeSpeakerLabel='Me'; non-mic/system keeps label empty/unknown"
patterns-established:
  - "Future plans must assume diarization is OFF unless milestone explicitly restores it"
requirements-completed: [RT-01, RT-03]
duration: 10min
completed: 2026-03-23
---

# Phase 09 Plan 05: Operational Hotfix Note (Diarization OFF)

**Temporary mode introduced for live meeting reliability:** diarization is disabled in `MeetingRecorder`, and transcription runs as a continuous source-based stream.

## Why

- Priority changed for a live meeting window (11:30).
- Dіarization added lag/instability and degraded real-time UX.
- Goal shifted to stable continuous transcription first.

## Active Runtime Contract (temporary)

- `MeetingRecorder` does **not** initialize/use diarization pipeline components.
- Mic source sets `activeSpeakerLabel = "Me"` immediately.
- Non-mic/system path keeps `activeSpeakerLabel = ""` (unknown) for waveform state.
- Waveform remains TimelineView + Canvas and no longer depends on diarizer chunk timing.

## Planning Guardrail for Next Agents

Until explicit re-enable decision:
- Do not plan diarizer-dependent behavior as a prerequisite for recording/transcription flow.
- Use source-based attribution assumptions in execution plans.
- Treat diarization restoration as a dedicated future decision/phase, not an incidental refactor.

## Verification Snapshot

- `swift build` passes after disabling diarization pipeline in `MeetingRecorder`.
- `swift test --filter MeetingRecorderTests` passes.

## Self-Check: PASSED

- Hotfix note created at `.planning/phases/09-waveform-color-per-speaker/09-05-SUMMARY.md`.
- Linked planning docs updated with TEMP mode policy (`PROJECT.md`, `STATE.md`, `ROADMAP.md`).
- Runtime implementation updated in `Sources/MeetingRecorder.swift`.
