---
phase: 06-speakerbuffermanager-actor
plan: 02
subsystem: audio
tags: [swift-actor, async-stream, diarization, speaker-detection, unit-testing]

requires:
  - phase: 06-01
    provides: DiarizationProvider protocol, ClosedSpeakerBuffer struct, MockDiarizationProvider stub, SpeakerBufferManagerTests stubs

provides:
  - SpeakerBufferManager actor with hot-path audio ingestion and diarization polling loop
  - AsyncStream<ClosedSpeakerBuffer> output for downstream ASR consumption
  - 10 passing unit tests covering all PIPE and SPKR requirements
  - flushCappedBuffer() handling overflow when batch exceeds 30s cap in one call

affects:
  - 06-03-integration (MeetingRecorder wiring)
  - 07-dualchannelaudiocapture (feeds onAudioBatch)
  - 08-meetingrecorder-rewire (replaces resolveSpeaker logic)

tech-stack:
  added: []
  patterns:
    - "Actor with nonisolated AsyncStream let property using synchronous closure init"
    - "Polling loop: while !Task.isCancelled + try await Task.sleep catch-break"
    - "Hot path isolation: onAudioBatch() is append-only, zero ML inference"
    - "flushCappedBuffer() splits buffer at cap boundary, keeps overflow"

key-files:
  created:
    - Sources/SpeakerBufferManager.swift
  modified:
    - Tests/SpeakerBufferManagerTests.swift
    - Tests/MockDiarizationProvider.swift

key-decisions:
  - "flushCappedBuffer() created to handle the case where a single onAudioBatch() call exceeds maxSamplesPerBuffer — yields exactly 480,000 samples and keeps remainder in accumulatedSamples"
  - "pollDiarizer() uses while loop (not if) for the cap check to handle >2x overflow from large batches"
  - "pollDiarizer() is a non-async actor method called without await from the polling Task body"

patterns-established:
  - "AsyncStream init pattern: var cap; self.buffers = AsyncStream { cap = $0 }; self.continuation = cap"
  - "Test pattern: MockDiarizationProvider.setResults([...]) + pollingInterval: 50_000_000 (50ms) for fast tests"
  - "collectBuffers() helper waits for stream to finish, used across all tests"

requirements-completed: [PIPE-01, PIPE-02, PIPE-03, PIPE-04, PIPE-06, SPKR-01, SPKR-03]

duration: 4min
completed: 2026-03-22
---

# Phase 06 Plan 02: SpeakerBufferManager Actor Summary

**SpeakerBufferManager Swift actor with hot-path audio ingestion, 150ms diarization polling, speaker-change buffer flushing, 30s cap / 0.5s floor enforcement, and stable Speaker N label resolution — all verified by 10 passing unit tests**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-22T13:48:56Z
- **Completed:** 2026-03-22T13:52:39Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- SpeakerBufferManager actor fully implemented with all behaviors specified in Plan 06-02
- All 10 unit tests pass in 2.2 seconds (no CoreML model loading, mock-only)
- Fixed cap-overflow edge case: single large batch exceeding 480,000 samples now correctly split at boundary

## Task Commits

1. **Task 1: Implement SpeakerBufferManager actor** - `dc975ac` (feat)
2. **Task 2: Implement 10 SpeakerBufferManagerTests + fix cap flush** - `ce66ef4` (feat)

## Files Created/Modified

- `Sources/SpeakerBufferManager.swift` - Actor with onAudioBatch, start, stop, pollDiarizer, flushCappedBuffer, flushCurrentBuffer, resolveLabel
- `Tests/SpeakerBufferManagerTests.swift` - 10 passing tests covering PIPE-01..06, SPKR-01..03
- `Tests/MockDiarizationProvider.swift` - Added `makeDiarizationResult()` helper for constructing FluidAudio DiarizationResult with TimedSpeakerSegment (requires embedding: [Float] parameter)

## Decisions Made

- `flushCappedBuffer()` (not `flushCurrentBuffer()`) handles the 30s cap: yields exactly `maxSamplesPerBuffer` samples, keeps overflow in `accumulatedSamples`, advances `bufferStartTime`. This correctly handles the case where a single `onAudioBatch()` call exceeds the cap (e.g., test feeds 490,000 samples at once).
- `pollDiarizer()` uses a `while` loop for the cap check so back-to-back overflow is handled without waiting for the next 150ms tick.
- `TimedSpeakerSegment` in FluidAudio requires `embedding: [Float]` — test helper passes `[]` since mock doesn't use embeddings.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] flushCurrentBuffer() emitted oversized buffers when batch exceeded cap**

- **Found during:** Task 2 (testMaxDurationCapForceFlush failure)
- **Issue:** `flushCurrentBuffer()` yielded all `accumulatedSamples` regardless of count. When 490,000 samples were fed in one batch, the emitted buffer had 490,000 samples — violating the 480,000-sample cap invariant.
- **Fix:** Added `flushCappedBuffer()` that slices `accumulatedSamples.prefix(maxSamplesPerBuffer)`, keeps `dropFirst(maxSamplesPerBuffer)` as overflow, advances `bufferStartTime`. `pollDiarizer()` now calls this in a `while` loop.
- **Files modified:** Sources/SpeakerBufferManager.swift
- **Verification:** testMaxDurationCapForceFlush passes; all buffers assert `<= 480,000 samples`
- **Committed in:** ce66ef4 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - Bug)
**Impact on plan:** Fix was necessary for correctness — the 30s cap is a core invariant. No scope creep.

## Issues Encountered

- FluidAudio `TimedSpeakerSegment` init requires `embedding: [Float]` parameter (not in plan's interface listing). Resolved inline by passing `[]` in the test helper.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- SpeakerBufferManager actor is complete and tested — ready for Plan 06-03 integration wiring
- MeetingRecorder can wire up by creating SpeakerBufferManager, calling start(), feeding audio via onAudioBatch(), consuming buffers AsyncStream for ASR
- Concern carried forward: polling cadence (50ms in tests, 150ms in production) should be validated against CoreML latency on target hardware before Phase 8 integration

---
*Phase: 06-speakerbuffermanager-actor*
*Completed: 2026-03-22*

## Self-Check: PASSED

- Sources/SpeakerBufferManager.swift: FOUND
- Tests/SpeakerBufferManagerTests.swift: FOUND
- Tests/MockDiarizationProvider.swift: FOUND
- 06-02-SUMMARY.md: FOUND
- Commit dc975ac: FOUND
- Commit ce66ef4: FOUND
