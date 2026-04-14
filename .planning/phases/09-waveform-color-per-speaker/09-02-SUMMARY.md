---
phase: 09-waveform-color-per-speaker
plan: 02
subsystem: ui
tags: [swiftui, canvas, timelineview, waveform, diarization]
requires:
  - phase: 09-01
    provides: "Hex-based speaker palette and Speaker(displayName:) conversion"
provides:
  - "Timeline-driven Canvas waveform rendering under heavy main-thread load"
  - "Fixed-size circular history buffer for stable geometry"
  - "Square-root amplitude scaling for speech-friendly visual response"
affects: [meetingwaveformview, meetingnotesview]
tech-stack:
  added: []
  patterns: ["TimelineView tick-driven rendering", "fixed-capacity waveform history", "speaker color sampled per point"]
key-files:
  created: [.planning/phases/09-waveform-color-per-speaker/09-02-SUMMARY.md]
  modified: [Sources/MeetingWaveformView.swift]
key-decisions:
  - "Use TimelineView + Canvas for deterministic redraw cadence when AI workloads load the main thread"
  - "Use fixed 120-sample waveform history to avoid startup lag and geometry jumps"
  - "Use sqrt(level) visual scaling to better show quiet speech while retaining loud-speech dynamics"
  - "Accept diarization color lag as model-side latency; keep amplitude path real-time"
patterns-established:
  - "Waveform rendering should be decoupled from heavy processing bursts via timeline ticks"
  - "Speaker color must be bound to sampled point history, not recomputed from current state"
requirements-completed: [RT-01, RT-03]
duration: 40 min
completed: 2026-03-23
---

# Phase 09 Plan 02: Waveform Color Per Speaker Summary

**Meeting waveform now uses TimelineView + Canvas with a fixed history buffer and sqrt-based amplitude response for stable, real-time visualization under AI load**

## Performance

- **Duration:** ~40 min (including checkpoint iterations)
- **Completed:** 2026-03-23

## Accomplishments

- Reworked `MeetingWaveformView` to use `TimelineView(.animation(minimumInterval: 0.1))` with `Canvas` rendering.
- Kept waveform history as fixed-capacity `WaveformPoint` array (`120` samples) to avoid delayed startup and layout jumps.
- Implemented per-point speaker color assignment with unknown fallback color and strict speaker mapping for detected speakers.
- Switched visual amplitude response to `sqrt(level)` to improve low-level signal visibility while preserving loud-signal contrast.
- Restored companion view structs in `MeetingWaveformView.swift` (`AudioLevelIndicator`, `MeetingStatusBadge`, `PulseModifier`, `SpeakerBadge`, `MeetingTimerView`) after detecting accidental removal during checkpoint iteration.

## Task Commits

1. `017709e` — rewrite waveform view to Canvas history rendering
2. `4ee54d0` — apply checkpoint polish (density/model/color behavior)
3. `616d8e7` — finalize timeline-driven renderer and restore companion views

## Architecture Notes (for future agents)

- **Rendering Engine:** `TimelineView + Canvas` is preferred for stable redraw cadence (10 FPS / 60 FPS strategy) when the main thread is busy with Parakeet/Diarization workloads.
- **Buffering Model:** fixed-size waveform history (circular behavior) reduces warm-up delay and avoids geometry jitter.
- **Signal Physics:** `sqrt()` amplitude transform yields a more "analog" visual response that keeps whisper-level activity visible.
- **Known Constraint:** speaker color can lag due to diarization chunk latency; this is model-pipeline behavior, not waveform rendering latency.

## Verification

- `swift build` passes.
- `swift test --parallel --verbose` passes in this environment.

## Deviations from Original Plan

- Original plan specified timer-based updates, -50dB floor scaling, and 250-point history iteration from earlier checkpoint drafts.
- Final implementation intentionally favors timeline-driven rendering and 120-point fixed history for responsiveness and visual stability under load.

## Self-Check: PASSED

- Summary file created.
- Source changes compiled.
- Plan commit recorded.
