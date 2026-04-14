---
phase: 08-meetingrecorder-pipeline-rewire
plan: 01
subsystem: audio
tags: [swift, swift-concurrency, asr, diarization, macos, xctest]
requires:
  - phase: 06-speakerbuffermanager-actor
    provides: AsyncStream<ClosedSpeakerBuffer> emission with stable speaker labels
  - phase: 07-dualchannelaudiocapture-streaming-callback
    provides: onSystemBatch streaming callback and mic/system capture split
provides:
  - MeetingRecorder consumer loop for SpeakerBufferManager buffers
  - TranscriptionQueue ClosedSpeakerBuffer overload
  - activeSpeakerLabel publication before ASR result delivery
  - zero-data-loss stop ordering for system buffers and final mic audio
affects: [09-waveform-color-per-speaker, 10-chat-bubble-ui, meeting-storage]
tech-stack:
  added: []
  patterns: [AsyncStream consumer task, serialized ASR queue overloads, diarization-owned speaker attribution]
key-files:
  created: [Tests/MeetingRecorderTests.swift]
  modified: [Sources/TranscriptionQueue.swift, Sources/MeetingRecorder.swift]
key-decisions:
  - "MeetingRecorder updates activeSpeakerLabel on ClosedSpeakerBuffer arrival before queueing ASR work."
  - "stopRecording() stops SpeakerBufferManager, awaits the consumer, stops capture, then drains ASR to avoid dropping the final speaker turn."
  - "Legacy system-audio diarization state stays removed from MeetingRecorder; fallback attribution uses source.speaker and mic-only deduplication."
patterns-established:
  - "Per-speaker system audio is transcribed only through ClosedSpeakerBuffer -> TranscriptionQueue.enqueue(buffer:) -> transcribeClosedBuffer(_:)."
  - "Fallback 5-second chunk processing remains only for non-diarized system audio and microphone capture."
requirements-completed: [PIPE-01, PIPE-02, PIPE-03, PIPE-04, PIPE-05, PIPE-06, SPKR-01, SPKR-02, SPKR-03]
duration: 8 min
completed: 2026-03-22
---

# Phase 08 Plan 01: MeetingRecorder Pipeline Rewire Summary

**MeetingRecorder now drains diarized speaker buffers through a serialized ASR queue, publishes live speaker labels before transcript text, and tears down recording without dropping the final turn**

## Performance

- **Duration:** 8 min
- **Started:** 2026-03-22T21:23:58+02:00
- **Completed:** 2026-03-22T21:32:08+02:00
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments
- Added `MeetingRecorderTests` covering the consumer-loop contract, label timing, teardown ordering, and the new queue overload.
- Extended `TranscriptionQueue` with `enqueue(buffer:processor:)` so diarized system-audio buffers and mic chunks share one serialized ASR path.
- Rewired `MeetingRecorder` to consume `SpeakerBufferManager.buffers`, publish `activeSpeakerLabel`, transcribe closed speaker buffers, and stop in a zero-data-loss order.

## Task Commits

Each task was committed atomically:

1. **Task 0: Create MeetingRecorderTests with mocks for pipeline behaviors** - `4be7d3d` (`test`)
2. **Task 1: Add TranscriptionQueue overload and wire buffer consumer loop with activeSpeakerLabel** - `5c3e6c1` (`feat`)
3. **Task 2: Remove dead code and guard fallback path** - `be7af71` (`fix`)

## Files Created/Modified
- `Tests/MeetingRecorderTests.swift` - Exercises the pipeline seams without requiring the full recorder stack.
- `Sources/TranscriptionQueue.swift` - Adds buffered `ClosedSpeakerBuffer` serialization and drain awareness.
- `Sources/MeetingRecorder.swift` - Starts the consumer loop, updates `activeSpeakerLabel`, transcribes diarized buffers, and removes legacy speaker-resolution state.

## Decisions Made
- `activeSpeakerLabel` is updated from the consumer loop before the closed buffer is enqueued for ASR, giving Phase 9 a label-first UI signal.
- `stopRecording()` keeps the producer-stop -> consumer-join -> capture-stop -> queue-drain -> final-mic-processing sequence inline in code with rationale comments.
- `MeetingRecorder` no longer owns system speaker label mapping or system transcript deduplication; that ownership stays with `SpeakerBufferManager`.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- `swift test` initially failed inside the sandbox because SwiftPM could not write to the default module cache. Verification succeeded after rerunning the test commands outside the sandbox.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- `activeSpeakerLabel` is now available for waveform color updates in Phase 9.
- Meeting segments preserve existing `MeetingSession` and storage models while gaining diarized speaker attribution from the rewired pipeline.

## Self-Check: PASSED

- Verified summary file exists at `.planning/phases/08-meetingrecorder-pipeline-rewire/08-01-SUMMARY.md`.
- Verified task commits exist: `4be7d3d`, `5c3e6c1`, `be7af71`.

---
*Phase: 08-meetingrecorder-pipeline-rewire*
*Completed: 2026-03-22*
