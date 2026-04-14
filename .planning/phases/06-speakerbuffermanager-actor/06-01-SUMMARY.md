---
phase: 06-speakerbuffermanager-actor
plan: "01"
subsystem: diarization-contracts
tags: [concurrency, protocol, tdd, swift-actor]
dependency_graph:
  requires: []
  provides: [DiarizationProvider, ClosedSpeakerBuffer, MockDiarizationProvider, SpeakerBufferManagerTests-stubs]
  affects: [06-02-PLAN.md, 06-03-PLAN.md]
tech_stack:
  added: [strict-concurrency-complete]
  patterns: [protocol-wrapping, unchecked-sendable-actor-ownership, tdd-red-stubs]
key_files:
  created:
    - Sources/DiarizationProvider.swift
    - Tests/MockDiarizationProvider.swift
    - Tests/SpeakerBufferManagerTests.swift
  modified:
    - Package.swift
decisions:
  - "DiarizerManager uses @unchecked Sendable extension because FluidAudio does not yet add its own conformance; the actor's serialization makes this safe"
  - "DiarizationResult(segments: []) is the correct empty-result initializer — speakerDatabase and timings default to nil"
  - "Test files placed at Tests/ (not Tests/WhisperClipTests/) to match the existing project convention"
metrics:
  duration_seconds: 115
  completed_date: "2026-03-22"
  tasks_completed: 2
  tasks_total: 2
  files_created: 3
  files_modified: 1
---

# Phase 06 Plan 01: Strict Concurrency Baseline and Type Contracts Summary

**One-liner:** DiarizationProvider protocol + ClosedSpeakerBuffer type + DiarizerManager @unchecked Sendable extension + 10 pending test stubs with strict concurrency enabled.

## What Was Built

Established the full type-contract foundation for Phase 6 before any actor implementation:

1. `Package.swift` — added `-strict-concurrency=complete` to WhisperClip swiftSettings so all subsequent Phase 6 code is written against Swift's strictest concurrency model from the start.

2. `Sources/DiarizationProvider.swift` — three declarations:
   - `protocol DiarizationProvider: Sendable` wrapping FluidAudio's `DiarizerManager` to allow unit testing without model loading
   - `extension DiarizerManager: @unchecked Sendable {}` + `extension DiarizerManager: DiarizationProvider` enabling the real diarizer to satisfy the protocol
   - `struct ClosedSpeakerBuffer: Sendable, Equatable` — the value type emitted by `SpeakerBufferManager` carrying `samples: [Float]`, `speakerLabel: String`, `startTime: TimeInterval`

3. `Tests/MockDiarizationProvider.swift` — configurable mock with `setResults(_:)` and `diarizeCallCount` for deterministic unit tests without CoreML model loading.

4. `Tests/SpeakerBufferManagerTests.swift` — 10 pending test stubs covering all Phase 6 pipeline requirements (PIPE-01 through PIPE-06, SPKR-01 through SPKR-03), each failing with `XCTFail("Not yet implemented — Plan 02")`.

## Verification Results

- `swift build` exits with 0 errors
- `swift test --filter SpeakerBufferManagerTests` reports exactly 10 test failures (XCTFail), 0 compilation errors
- `grep -c "strict-concurrency=complete" Package.swift` returns 1
- `grep -c "protocol DiarizationProvider" Sources/DiarizationProvider.swift` returns 1

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| Task 1 | 10ee239 | feat(06-01): enable strict concurrency flag and add DiarizationProvider protocol |
| Task 2 | 83ee053 | test(06-01): add MockDiarizationProvider and SpeakerBufferManagerTests stubs |

## Deviations from Plan

**1. [Rule 3 - Deviation] Test files placed at Tests/ not Tests/WhisperClipTests/**

- **Found during:** Task 2
- **Issue:** The plan referenced `Tests/WhisperClipTests/` but that directory does not exist. The project's Package.swift maps `testTarget` to `path: "Tests"` and all existing test files live directly in `Tests/`.
- **Fix:** Created `MockDiarizationProvider.swift` and `SpeakerBufferManagerTests.swift` at `Tests/` matching the existing convention.
- **Files modified:** Tests/MockDiarizationProvider.swift, Tests/SpeakerBufferManagerTests.swift
- **Commit:** 83ee053

## Self-Check: PASSED

- `Sources/DiarizationProvider.swift` — FOUND
- `Tests/MockDiarizationProvider.swift` — FOUND
- `Tests/SpeakerBufferManagerTests.swift` — FOUND
- Commit 10ee239 — FOUND
- Commit 83ee053 — FOUND
