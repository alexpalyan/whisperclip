# Project Research Summary

**Project:** WhisperClip v1.1 — Speaker Diarization Pipeline Rewrite
**Domain:** Real-time streaming ASR with per-speaker audio buffer management on macOS
**Researched:** 2026-03-22
**Confidence:** HIGH (all findings derived directly from codebase source and FluidAudio internals)

## Executive Summary

WhisperClip v1.1 is a surgical pipeline rewrite, not a greenfield build. The v1.0 pipeline batches audio into fixed 5-second chunks and assigns the dominant speaker to the entire chunk — meaning any speaker change mid-chunk produces a mis-attributed transcript segment. The v1.1 goal is a diarization-first architecture: detect speaker boundaries continuously, accumulate audio per-speaker in an actor-isolated buffer, and dispatch ASR only when a buffer closes (speaker changes or 30-second cap fires). Every dispatched buffer maps to exactly one speaker, so transcript attribution is correct by construction rather than by post-hoc heuristic.

The recommended approach centers on a new `SpeakerBufferManager` Swift actor that sits between `DualChannelAudioCapture` and the existing `TranscriptionQueue`. The audio tap callback stays thin — it only copies samples into the actor. A polling `Task` (100-200ms cadence) runs `DiarizerManager.performCompleteDiarization()` on incoming batches, detects speaker changes with 2-3 batch hysteresis to avoid thrashing, and closes/opens per-speaker `[Float]` buffers keyed by `speakerId`. No new Swift Package Manager dependencies are needed. The entire implementation reuses FluidAudio's `DiarizerManager`, the existing `TranscriptionQueue` actor, and `speakerPaletteColor()` from `SharedViews.swift`.

The principal risks are all concurrency-related. Calling diarization synchronously inside the audio tap will silently drop audio frames. Actor reentrancy on `MeetingRecorder`'s `speakerLabelMap` during concurrent ASR Tasks can corrupt speaker labels. Speaker ID drift from FluidAudio's online clustering algorithm is most severe in the first 60 seconds of a recording. All three risks have clear prevention strategies documented in PITFALLS.md and must be addressed in Phase 1 before any UI work begins. Enabling `SWIFT_STRICT_CONCURRENCY=complete` before the first line of new code is written is the single highest-leverage action.

---

## Key Findings

### Recommended Stack

No new dependencies are required. The rewrite extends existing components: `AudioBufferActor` is replaced by `SpeakerBufferManager` (a new actor with the same isolation pattern), `DualChannelAudioCapture` drops its 5-second `chunkTimer` for system audio and adds a continuous streaming callback, and `MeetingRecorder` gains a `@Published activeSpeakerColor: Color` property. The mic path is untouched — it has always attributed to `.me` and remains a simple 2-second chunked flow.

**Core technologies:**
- `actor SpeakerBufferManager` — per-speaker `[String: SpeakerBuffer]` accumulation; same Swift actor pattern as existing `AudioBufferActor`; isolates all mutable buffer state from the audio callback thread
- `DiarizerManager.performCompleteDiarization` (FluidAudio) — called on a 100-200ms polling cadence on small rolling windows, not on full accumulated buffers; stateful instance preserves speaker embeddings across calls for ID stability
- `[Float]` with `reserveCapacity(30 * 16_000)` — plain Swift array for accumulation; pre-allocated to cap at 1.8 MB per buffer and eliminate doubling-reallocation spikes
- `TranscriptionQueue` (existing actor) — unchanged; all closed-buffer ASR tasks must flow through it to prevent concurrent CoreML crashes
- `Task { }` unstructured from nonisolated audio callbacks — the correct bridge from audio threads to Swift concurrency; same pattern already in `DualChannelAudioCapture`
- `@Published activeSpeakerColor: Color` on `MeetingRecorder` — updated before ASR dispatch (pre-transcription) so waveform color leads the text segment
- `speakerPaletteColor()` in `SharedViews.swift` — already used in `MeetingDetailView`; reused in `MeetingWaveformView.barGradient()` to unify color identity across live and review modes

**Critical constraint:** Never reset `DiarizerManager` between speaker turns. Resetting destroys `SpeakerManager` state and causes speaker IDs to restart from "1", collapsing multi-speaker sessions. One `DiarizerManager` instance per recording session.

### Expected Features

**Must have — v1.1 launch (table stakes and pipeline prerequisites):**
- PIPE-01/02/03/04: Per-speaker buffer accumulation, speaker-change flush trigger, 30-second hard cap, and atomic ASR dispatch — these four must ship together as one atomic pipeline unit; partial delivery means no segments ever arrive
- SPKR-01/02/03: Stable speaker IDs across the session — prerequisite for all downstream UI; broken IDs mean broken grouping and broken waveform color
- CHAT-01/02/03/04: iMessage-style bubble grouping in `MeetingDetailView` — the primary user-visible output; if the transcript still looks like a flat list after the pipeline fix, the work is invisible
- RT-01/02/03: Waveform color per active speaker using `speakerPaletteColor()` — low implementation cost, high "alive" signal during recording

**Should have — add after v1.1 validation (competitive):**
- Transcript auto-scroll to latest bubble during live recording (`ScrollViewReader` + `.onChange(of: segments.count)`)
- Overlap window prepend (100ms of previous speaker's audio at transition boundaries) — add only if word-clipping is observed in real recordings
- Typing indicator during buffer accumulation (`...` badge on waveform while current buffer is building)

**Defer to v1.2+:**
- Speaker naming UI — explicitly deferred per PROJECT.md; requires reference embeddings or manual rename flow
- Per-speaker parallel waveforms — too much UI complexity for the menu-bar window footprint
- Partial ASR preview — conflicts with `TranscriptionQueue` safety design; would require a parallel bypassing pipeline

**Anti-features to avoid:**
- Animated color fade on speaker change — speaker change is a discrete boundary event, not a continuous one; fade implies uncertainty
- Per-segment timestamps — creates ~900px of noise in a 60-segment meeting; use one timestamp per group
- Mid-buffer partial ASR results — Parakeet TDT produces unstable partials; `TranscriptionQueue` serializes for CoreML safety

### Architecture Approach

The architecture change is a vertical slice: the service layer changes significantly, the manager layer changes moderately, and the view layer changes only at two integration points. `MeetingSession`, `MeetingStorage`, `Speaker` enum, and `speakerPaletteColor()` are completely unchanged. The `TranscriptionQueue` actor is unchanged. The new `SpeakerBufferManager` actor is the central addition, sitting between `DualChannelAudioCapture` and the existing dispatch path. The state machine it owns is: idle → buffering(speakerId: X) → flushing(X) → buffering(newSpeaker).

**Major components:**
1. `SpeakerBufferManager` (NEW actor) — receives raw system audio batches, runs diarization at 100-200ms intervals, maintains `[String: SpeakerBuffer]`, manages 30-second cap, dispatches closed buffers through `TranscriptionQueue`, and publishes speaker-change events to `MeetingRecorder`
2. `DualChannelAudioCapture` (MODIFIED) — removes 5-second `chunkTimer` for system audio; adds continuous streaming callback that forwards raw batches to `SpeakerBufferManager`; mic path is completely unchanged
3. `MeetingRecorder` (MODIFIED) — removes `processAudioChunk` fixed-chunk flow for system audio; adds `@Published activeSpeakerColor: Color`; wires `SpeakerBufferManager` speaker-change callback to update color before ASR completes
4. `ChatBubbleGroup` (NEW SwiftUI view) — iMessage-style grouping of consecutive same-speaker `MeetingSegment`s; computed `[SpeakerGroup]` derived from `meeting.segments`; no model persistence
5. `MeetingWaveformView` (MODIFIED) — `barGradient()` uses `speakerPaletteColor(recorder.activeSpeaker)` instead of level-based thresholds

**Build order follows dependency chain:** SpeakerBufferManager actor (no integration) → DualChannelAudioCapture streaming callback → MeetingRecorder pipeline rewire → waveform color → chat bubble UI. Each phase compiles and records without regression.

### Critical Pitfalls

1. **Calling `performCompleteDiarization` inside the audio tap callback** — blocks the real-time audio thread, causing silent frame drops. Prevention: tap closure does only `Task { await actor.append() }` and returns; diarization runs in a separate polling Task at 100-200ms cadence. This is a load-bearing architectural constraint for the entire design.

2. **Actor reentrancy corrupting `speakerLabelMap`** — two rapid speaker-change events can interleave between `await asrManager.transcribe()` and the subsequent label write, assigning the same "Speaker 1" label to two different raw IDs. Prevention: move `speakerLabelMap` and `nextSpeakerNumber` into `SpeakerBufferManager` (the new actor), and resolve labels before the `await transcribe()` suspension point — never after.

3. **Speaker ID drift across diarization calls** — FluidAudio's online clustering centroid is unstable in the first 60 seconds; the same voice can be assigned `SPEAKER_00` then `SPEAKER_01` across consecutive calls. Prevention: enforce a 3-second minimum buffer before running diarization; use `clusteringThreshold: 0.3` (already tuned); do not pass the full accumulated buffer to diarization — only the new incremental batch.

4. **Unbounded per-speaker buffer memory growth** — a 10-minute monologue accumulates 38 MB; three channels for 60 minutes could exceed 300 MB plus WAV temp file copies. Prevention: pre-allocate each buffer with `reserveCapacity(30 * 16_000)`; enforce the 30-second cap at sample-append time inside the actor, not only at flush time.

5. **SwiftUI @Published updates from background Tasks without explicit MainActor hop** — waveform color lags or flickers when `activeSpeakerColor` is updated from a non-isolated context. Prevention: enable `SWIFT_STRICT_CONCURRENCY=complete` as the first commit of the v1.1 branch; wrap all `activeSpeakerColor` writes in `Task { @MainActor in ... }`.

---

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: SpeakerBufferManager Actor (Core Pipeline Foundation)
**Rationale:** All downstream features — waveform color, chat grouping, stable IDs — depend on this actor existing and being correct. Implementing it first in isolation (no DualChannelAudioCapture wiring) allows unit testing before any integration risk. PITFALLS.md maps pitfalls 1-5 all to Phase 1; these cannot be deferred.
**Delivers:** A standalone Swift actor that accumulates per-speaker `[Float]` buffers, detects speaker changes via diarization polling, enforces the 30-second cap, resolves speaker labels, and dispatches closed buffers through `TranscriptionQueue`. All concurrency constraints from PITFALLS.md are baked in at design time.
**Addresses:** PIPE-01, PIPE-02, PIPE-03, PIPE-04, SPKR-01, SPKR-02, SPKR-03
**Avoids:** Pitfalls 1 (audio thread blocking), 2 (label reentrancy), 3 (ID drift), 4 (memory growth), 5 (strict concurrency violations)
**Precondition:** Enable `SWIFT_STRICT_CONCURRENCY=complete` before writing any new code.

### Phase 2: DualChannelAudioCapture Streaming Callback
**Rationale:** This wires the new actor into the live audio path. The mic path is left completely untouched to minimize regression risk. System audio gets a continuous streaming callback that replaces the 5-second timer for that channel only.
**Delivers:** Live audio flows into `SpeakerBufferManager` during an actual recording session; the 5-second system-audio chunk timer is removed; mic path is unchanged and still works.
**Uses:** Continuous `SCStreamOutput` batch forwarding; `Task { await speakerBufferManager.onAudioBatch() }` pattern
**Implements:** Modified `DualChannelAudioCapture` streaming path

### Phase 3: MeetingRecorder Pipeline Rewire (PIPE-05)
**Rationale:** With the actor proven and audio flowing, this phase connects the full pipeline: `SpeakerBufferManager` closes buffers and dispatches ASR through `TranscriptionQueue`; `MeetingRecorder` adds `@Published activeSpeakerColor`. Recording should produce correct per-speaker segments end-to-end after this phase.
**Delivers:** End-to-end recording with diarization-driven segment splits; each segment maps to exactly one speaker; existing `MeetingSession` and `MeetingStorage` APIs are unchanged
**Implements:** Modified `MeetingRecorder` (system audio path), `@Published activeSpeakerColor` property

### Phase 4: Waveform Color Per Speaker (RT-01/02/03)
**Rationale:** Pure UI change on top of the `@Published activeSpeakerColor` property added in Phase 3. No pipeline changes. This is the real-time "who is speaking" signal and is low cost relative to its value.
**Delivers:** `MeetingWaveformView.barGradient()` reflects `speakerPaletteColor(recorder.activeSpeaker)` — waveform color changes at the moment of speaker-change detection, before ASR text appears
**Uses:** Existing `speakerPaletteColor()`, existing `@ObservedObject recorder` in `MeetingWaveformView`

### Phase 5: Chat Bubble UI (CHAT-01/02/03/04)
**Rationale:** Depends only on `MeetingSegment.speaker` being stable (Phase 1/3) and segments being sorted by `startTime` (already true via `MeetingNote.addSegment()`). The CHAT features are entirely independent of the pipeline — they can be developed against existing stored data. This is the primary user-visible output of the whole v1.1 effort.
**Delivers:** iMessage-style grouped transcript in `MeetingDetailView`; "Me" bubbles right-aligned; one speaker header and one timestamp per group; 75% max width bubbles with palette-tinted backgrounds
**Implements:** New `ChatBubbleGroup` SwiftUI view, `chatGroups()` computed property, modified `transcriptContent` in `MeetingDetailView`

### Phase Ordering Rationale

- **Phases 1-3 are a dependency chain** — buffer actor before wiring, wiring before pipeline completion. Each phase compiles and records without regression.
- **Phases 4 and 5 are independent of each other** — waveform color (Phase 4) and chat grouping (Phase 5) both depend on Phase 3 completing but not on each other; they could be parallelized if multiple developers are available.
- **CHAT features deliberately deferred to Phase 5** — they work against existing stored data and carry zero pipeline risk; implementing them early would only create review surface area without unblocking anything.
- **All critical pitfalls are front-loaded into Phase 1** — concurrency architecture, label reentrancy, and memory management are non-negotiable design constraints, not optimizations to add later.

### Research Flags

Phases likely needing additional research spikes before or during implementation:
- **Phase 1 (SpeakerBufferManager diarization polling cadence):** The 100-200ms polling interval is an estimate. Real-world CoreML latency for `performCompleteDiarization` on M-series chips should be measured with Instruments Time Profiler before committing to the polling cadence. If latency exceeds 150ms at the 99th percentile, the cadence needs adjustment.
- **Phase 1 (clusteringThreshold validation):** PITFALLS.md flags that `0.3` was chosen from observation. The "looks done but isn't" checklist requires verification on at least 3 speaker pairs before treating it as the shipping default.
- **Phase 2 (SCStreamOutput buffer size variation):** PITFALLS.md flags a `CMSampleBuffer` format assumption (32-bit float PCM). A format assertion should be added and verified on macOS 14 and 15 before the streaming callback is treated as stable.

Phases with well-established patterns (no additional research needed):
- **Phase 4 (waveform color):** The `@Published` + `@ObservedObject` chain is standard SwiftUI; `speakerPaletteColor()` already exists. Integration is mechanical.
- **Phase 5 (chat bubble grouping):** Standard SwiftUI iMessage layout pattern; `HStack` + `Spacer()` alignment with computed `segmentGroups` is well-documented. The `SpeakerGroup` data structure is designed and ready.

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All recommendations verified against FluidAudio source, existing codebase patterns, and Package.swift; no new dependencies required |
| Features | HIGH | FEATURES.md derived from direct PROJECT.md requirements (authoritative) + codebase analysis; external streaming ASR conventions are MEDIUM but consistent with project decisions already made |
| Architecture | HIGH | Derived entirely from direct source reading of all files in `Sources/`; no inference; component boundaries are explicit |
| Pitfalls | HIGH | All pitfalls found in existing codebase code and comments; none are hypothetical; each has a specific warning sign and recovery strategy |

**Overall confidence:** HIGH

### Gaps to Address

- **diarization polling cadence vs. CoreML latency:** The 100-200ms cadence is recommended but not empirically confirmed against `performCompleteDiarization` on the project's target hardware profile. Measure with Instruments in Phase 1 before finalizing.
- **`clusteringThreshold` generalization:** The value `0.3` (lowered from 0.7) was tuned for a specific recording scenario. PITFALLS.md recommends testing on 3+ diverse speaker pairs before shipping as default. Plan a validation spike in Phase 1 before Phase 3 integration.
- **Hysteresis batch count:** ARCHITECTURE.md recommends 2-3 consecutive batches before confirming a speaker change (~300-750ms). The exact value depends on real-world cross-talk frequency. Start at 3; adjust based on Phase 2 integration testing with live audio.
- **v1.x features activation criteria:** Overlap window prepend, transcript auto-scroll, and typing indicator are marked P2 with "add after validation." The validation criteria (user reports word-clipping; user reports view not following segments) are subjective. Define concrete acceptance thresholds during Phase 3 retrospective.

---

## Sources

### Primary (HIGH confidence)
- FluidAudio source (`DiarizerManager.swift`, `DiarizerTypes.swift`, `AudioBuffer.swift`, `SpeakerManager.swift`) — speaker ID stability, `performCompleteDiarization` API, `clusteringThreshold` behavior
- FluidAudio CLAUDE.md — threading model, `SpeakerManager` lifecycle, `@unchecked Sendable` prohibition
- FluidAudio tests (`StreamingAsrManagerTests.swift`, `SpeakerManagerTests.swift`) — `AudioBuffer` actor API, `speakerId` as stable numeric String
- WhisperClip `Sources/` codebase — `DualChannelAudioCapture.swift`, `MeetingRecorder.swift`, `MeetingWaveformView.swift`, `MeetingDetailView.swift`, `SharedViews.swift`, `MeetingModels.swift`, `MeetingSession.swift` — all existing patterns
- `.planning/PROJECT.md` — authoritative v1.1 milestone requirements (PIPE-01..05, SPKR-01..03, RT-01..03, CHAT-01..04)
- `Package.swift` — dependency versions confirmed

### Secondary (MEDIUM confidence)
- Streaming ASR buffer conventions (training knowledge; web search unavailable): 0.5s minimum floor, 30s cap, dominant-speaker attribution — consistent with project decisions already made
- iMessage/chat bubble UX conventions (Apple HIG and Messages.app observable patterns): right-for-self, left-for-others, timestamp at group end — stable conventions
- Apple AVAudioEngine tap callback threading requirements — well-established but not verified via live docs

### Tertiary (LOW confidence — needs validation during implementation)
- `clusteringThreshold: 0.3` generalization across diverse speaker pairs — single-scenario observation; verify in Phase 1
- CoreML latency of `performCompleteDiarization` on M-series chips at 100-200ms polling cadence — estimated from known CoreML characteristics; verify with Instruments

---
*Research completed: 2026-03-22*
*Ready for roadmap: yes*
