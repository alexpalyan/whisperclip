---
phase: 08-meetingrecorder-pipeline-rewire
verified: 2026-03-22T20:17:37Z
status: human_needed
score: 6/6 must-haves verified
re_verification:
  previous_status: gaps_found
  previous_score: 5/6
  gaps_closed:
    - "When diarizer is unavailable, system audio falls back to 5s chunks attributed to Other"
  gaps_remaining: []
  regressions: []
human_verification:
  - test: "Two-speaker live recording attribution"
    expected: "Alternating remote speakers stay consistently labeled in the transcript throughout a real recording session."
    why_human: "Static analysis and seam tests cannot prove live diarizer behavior on captured audio."
  - test: "Label-first UI timing"
    expected: "The UI driven by activeSpeakerLabel updates before transcript text for that turn appears."
    why_human: "Code order is correct, but visible UI timing still requires an end-to-end run."
---

# Phase 8: MeetingRecorder Pipeline Rewire Verification Report

**Phase Goal:** The full end-to-end pipeline is connected — SpeakerBufferManager dispatches ASR through TranscriptionQueue, MeetingRecorder receives completed segments with correct per-speaker attribution, and `activeSpeakerLabel` is published before each ASR result arrives.
**Verified:** 2026-03-22T20:17:37Z
**Status:** human_needed
**Re-verification:** Yes — after gap closure

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
| --- | --- | --- | --- |
| 1 | System audio buffers from SpeakerBufferManager flow through TranscriptionQueue and produce MeetingSegments with correct speaker labels | ✓ VERIFIED | `MeetingRecorder` still consumes `managerRef.buffers`, sets `activeSpeakerLabel`, and enqueues each `ClosedSpeakerBuffer` in `Sources/MeetingRecorder.swift:119-127`; `transcribeClosedBuffer(_:)` still creates `.labeled(buffer.speakerLabel)` segments in `Sources/MeetingRecorder.swift:434-482`. |
| 2 | `activeSpeakerLabel` updates on MeetingRecorder before ASR text arrives for that turn | ✓ VERIFIED | `activeSpeakerLabel = buffer.speakerLabel` still executes before `transcriptionQueue.enqueue(buffer:)` in `Sources/MeetingRecorder.swift:120-127`; `MeetingRecorderTests.testActiveSpeakerLabelUpdatesBeforeProcessorCall` passed from `Tests/MeetingRecorderTests.swift:64-93`. |
| 3 | `stopRecording()` drains all in-flight buffers and ASR before returning — zero data loss | ✓ VERIFIED | Stop order remains producer stop -> consumer await -> fallback flush -> capture stop -> queue drain -> final mic processing in `Sources/MeetingRecorder.swift:205-264`; `MeetingRecorderTests.testTeardownSequenceStopThenConsumeThenDrain` passed from `Tests/MeetingRecorderTests.swift:95-129`. |
| 4 | Mic transcription continues to work as before — always attributed to Me | ✓ VERIFIED | Mic chunks still go through `transcriptionQueue.enqueue(source:...)` in `Sources/MeetingRecorder.swift:143-155`, and `processAudioChunk` still maps `.microphone` via `AudioSource.speaker` in `Sources/MeetingRecorder.swift:406-425` and `Sources/DualChannelAudioCapture.swift:8-15`. |
| 5 | When diarizer is unavailable, system audio falls back to 5s chunks attributed to Other | ✓ VERIFIED | `onSystemBatch` now branches to `accumulateSystemFallback(samples, atTime:)` when `speakerBufferManager` is nil in `Sources/MeetingRecorder.swift:157-165`; fallback buffering dispatches `.system` chunks in `Sources/MeetingRecorder.swift:336-368`; `stopRecording()` flushes the remainder with `isFinal: true` in `Sources/MeetingRecorder.swift:228-241`; `processAudioChunk` maps `.system` to `.other` in `Sources/MeetingRecorder.swift:406-425`; seam tests passed in `Tests/MeetingRecorderTests.swift:151-244`. |
| 6 | Dead code (`resolveSpeaker`, `speakerLabelMap`, `nextSpeakerNumber`, `processedSystemTexts`) is removed from MeetingRecorder | ✓ VERIFIED | `rg` found none of these stale symbols in `Sources/MeetingRecorder.swift`; speaker-label state remains only in the diarization path, not in the recorder. |

**Score:** 6/6 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
| --- | --- | --- | --- |
| `Tests/MeetingRecorderTests.swift` | Integration and seam tests for pipeline behaviors plus fallback proof | ✓ VERIFIED | Exists, substantive, and includes the original queue/ordering tests plus fallback coverage in `Tests/MeetingRecorderTests.swift:32-244`. Focused test run passed 6/6. |
| `Sources/TranscriptionQueue.swift` | `enqueue(buffer:processor:)` overload for `ClosedSpeakerBuffer` | ✓ VERIFIED | Exists and remains wired for serialized diarized-buffer processing in `Sources/TranscriptionQueue.swift:23-37`; `drain()` covers both request queues in `Sources/TranscriptionQueue.swift:58-62`. |
| `Sources/MeetingRecorder.swift` | Buffer consumer loop, `activeSpeakerLabel`, fallback system routing, and dead code removal | ✓ VERIFIED | Exists, substantive, and now includes both diarized buffer consumption and recorder-owned non-diarized fallback handling in `Sources/MeetingRecorder.swift:29-49` and `Sources/MeetingRecorder.swift:113-165` and `Sources/MeetingRecorder.swift:228-368`. |

### Key Link Verification

| From | To | Via | Status | Details |
| --- | --- | --- | --- | --- |
| `Sources/MeetingRecorder.swift` | `SpeakerBufferManager.buffers` | `bufferConsumerTask` consuming `AsyncStream` | ✓ WIRED | `for await buffer in managerRef.buffers` remains present in `Sources/MeetingRecorder.swift:119-120`. |
| `Sources/MeetingRecorder.swift` | `Sources/TranscriptionQueue.swift` | `enqueue(buffer:)` call in consumer loop | ✓ WIRED | `await self.transcriptionQueue.enqueue(buffer: buffer)` remains present in `Sources/MeetingRecorder.swift:125-126`. |
| `Sources/MeetingRecorder.swift` | `activeSpeakerLabel` | `MainActor.run` before enqueue | ✓ WIRED | `self.activeSpeakerLabel = buffer.speakerLabel` still precedes queueing in `Sources/MeetingRecorder.swift:122-125`. |
| `Sources/MeetingRecorder.swift (onSystemBatch callback)` | `Sources/MeetingRecorder.swift (processAudioChunk)` | `systemFallbackBuffer` accumulation plus `TranscriptionQueue.enqueue(source: .system, ...)` | ✓ WIRED | `onSystemBatch` now falls back to `accumulateSystemFallback(...)` when no manager exists in `Sources/MeetingRecorder.swift:157-165`; fallback dispatches `.system` chunks in `Sources/MeetingRecorder.swift:343-366`; stop flush routes remainder through `processAudioChunk(..., isFinal: true)` in `Sources/MeetingRecorder.swift:228-241`. |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
| --- | --- | --- | --- | --- |
| `PIPE-01` | `08-01-PLAN.md` | System accumulates per-speaker audio continuously instead of fixed 5s chunks | ✓ SATISFIED | Diarized system audio still goes through `SpeakerBufferManager.onAudioBatch` from `Sources/MeetingRecorder.swift:157-161`, preserving the continuous per-speaker path. |
| `PIPE-02` | `08-01-PLAN.md` | Speaker change closes the current buffer and triggers Whisper on accumulated audio | ✓ SATISFIED | Closed buffers from `managerRef.buffers` still feed `transcriptionQueue.enqueue(buffer:)` in `Sources/MeetingRecorder.swift:119-127`. |
| `PIPE-03` | `08-01-PLAN.md` | >30s speaker buffer is force-closed and reopened | ✓ SATISFIED | Phase 8 still consumes whatever `SpeakerBufferManager` closes and emits, so the force-close path remains integrated into recorder ASR handling. |
| `PIPE-04` | `08-01-PLAN.md` | Each closed buffer is an atomic Whisper task attributed to one speaker | ✓ SATISFIED | `transcribeClosedBuffer(_:)` creates exactly one `MeetingSegment` per `ClosedSpeakerBuffer` with `.labeled(buffer.speakerLabel)` in `Sources/MeetingRecorder.swift:460-470`. |
| `PIPE-05` | `08-01-PLAN.md`, `08-02-PLAN.md` | Mic audio is separate from system audio and always "Me" | ✓ SATISFIED | Mic path remains `.microphone -> .me`; no-diarizer system fallback now routes `.system -> .other` via `AudioSource.speaker`, restoring the intended split in `Sources/DualChannelAudioCapture.swift:8-15` and `Sources/MeetingRecorder.swift:406-425`. |
| `PIPE-06` | `08-01-PLAN.md` | Buffers shorter than 0.5s are rejected without Whisper | ✓ SATISFIED | Diarized system path still depends on `SpeakerBufferManager` emission rules, and recorder-side source processing still rejects non-final chunks under the 2s ASR floor in `Sources/MeetingRecorder.swift:376-378`. |
| `SPKR-01` | `08-01-PLAN.md` | Stable diarizer speaker IDs across the session | ✓ SATISFIED | Recorder still consumes resolved `ClosedSpeakerBuffer.speakerLabel` values directly without remapping in `Sources/MeetingRecorder.swift:119-127`. |
| `SPKR-02` | `08-01-PLAN.md` | `clusteringThreshold` is 0.3 (`speakerThreshold=0.36`) | ✓ SATISFIED | `DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.3))` remains in `Sources/MeetingRecorder.swift:100-101`. |
| `SPKR-03` | `08-01-PLAN.md` | Stable "Speaker 1", "Speaker 2" labels across buffers | ✓ SATISFIED | Recorder still preserves `buffer.speakerLabel` into both `activeSpeakerLabel` and the emitted `MeetingSegment` in `Sources/MeetingRecorder.swift:122-126` and `Sources/MeetingRecorder.swift:460-470`. |

Phase 8 has no orphaned requirement IDs in `.planning/REQUIREMENTS.md`; it is explicitly documented there as an integration phase over Phase 6 and Phase 7 requirements.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
| --- | --- | --- | --- | --- |
| `Sources/DiarizationProvider.swift` | 18 | `TODO` for retroactive `Sendable` conformance cleanup | ℹ️ Info | Existing warning only; unrelated to Phase 8 goal achievement. |

### Human Verification Required

### 1. Two-Speaker Live Recording Attribution

**Test:** Record a short meeting with two distinct remote speakers and inspect the live transcript.
**Expected:** Speaker turns stay consistently labeled and match the real speakers through the session.
**Why human:** Seam tests confirm recorder wiring, not live diarizer quality on captured audio.

### 2. Label-First UI Timing

**Test:** Start a meeting and watch the UI element driven by `activeSpeakerLabel` while speakers alternate.
**Expected:** The label changes before transcript text for that turn is rendered.
**Why human:** Code ordering is verified, but perceptible UI timing still requires an end-to-end run.

### Gaps Summary

The previous blocker is closed. The non-diarized system-audio path no longer drops audio when `speakerBufferManager` is absent: batches are accumulated in recorder-owned state, dispatched as 5-second `.system` chunks through `TranscriptionQueue`, flushed on stop, and attributed to `.other` by the existing source-based segment path.

Automated verification is complete at 6/6 must-haves, including the previously failed fallback truth. The phase remains `human_needed` rather than `passed` only because live diarizer behavior and visible UI timing are not provable through static inspection and focused seam tests alone.

---

_Verified: 2026-03-22T20:17:37Z_
_Verifier: Claude (gsd-verifier)_
