# Phase 8: MeetingRecorder Pipeline Rewire - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Connect the pieces built in Phases 6 and 7: wire `SpeakerBufferManager.buffers` (AsyncStream<ClosedSpeakerBuffer>) into `TranscriptionQueue`, publish `activeSpeakerLabel` at the moment of speaker-change detection (before ASR text arrives), and remove the old 5s system-audio path from `MeetingRecorder`.

Phase 8 does NOT touch waveform color (Phase 9) or chat bubble UI (Phase 10). It does NOT add speaker naming UI. It does NOT change `MeetingSession`, `MeetingStorage`, or `addSegment()` — those APIs are frozen.

</domain>

<decisions>
## Implementation Decisions

### activeSpeakerLabel publisher
- Publish `@Published private(set) var activeSpeakerLabel: String = ""` — a new property on `MeetingRecorder`
- Type is `String` (speaker label: `"Me"`, `"Speaker 1"`, `"Speaker 2"`, …), NOT `Color` and NOT `Int` index
- Phase 9 converts label → Color via `speakerPaletteColor()` — Phase 8 has no palette dependency
- Update timing: **on buffer arrival**, before ASR is enqueued — satisfies success criterion 2 (color precedes text)
- Separate property from `activeSpeakers` — `activeSpeakers` is a static capability list (permission-based), not the live speaker
- Reset to `""` (empty string) in `cleanup()` when recording stops — Phase 9 decides how to render the idle state

### AsyncStream consumer loop
- Own the loop in `private var bufferConsumerTask: Task<Void, Never>?` — stored property, mirrors `pollingTask` in `SpeakerBufferManager`
- Started after `speakerBufferManager.start()` in `startRecording()`
- Loop body hops to `@MainActor` explicitly for `activeSpeakerLabel` update (`await MainActor.run { activeSpeakerLabel = buffer.speakerLabel }`), then enqueues into `TranscriptionQueue`
- Safe under `SWIFT_STRICT_CONCURRENCY=complete`

### Zero Data Loss teardown sequence
**CRITICAL — this order is non-negotiable:**

1. `await speakerBufferManager.stop()` — flushes remaining open buffer, finishes the AsyncStream
2. Await `bufferConsumerTask` to complete — consumer loop drains all remaining `ClosedSpeakerBuffer` items emitted by step 1's final flush
3. `await transcriptionQueue.drain()` — waits for all in-flight and pending ASR predictions to finish
4. Process final mic chunk (existing behavior, unchanged)

Rationale: cancelling the consumer before `speakerBufferManager.stop()` would silently drop the last speaker turn. This ordering guarantees every closed buffer reaches ASR before `stopRecording()` returns.

### TranscriptionQueue extension
- Add a new overload: `enqueue(buffer: ClosedSpeakerBuffer, processor: @escaping @MainActor (ClosedSpeakerBuffer) async -> Void) async`
- Existing `enqueue(source:samples:startTime:processor:)` unchanged — mic path continues to use it
- No generic refactor — two overloads is the minimal change for Phase 8

### Fallback when SpeakerBufferManager is nil
- When diarizer models are not downloaded, `speakerBufferManager` is nil
- System audio continues to flow through `processAudioChunk(source:samples:startTime:)` via the existing `onAudioChunk` 5s-timer path — **unchanged**
- All system audio in fallback mode is attributed to `.other` (static "Other" speaker label)
- Minimum sample check stays at **2s = 32,000 samples** — proven v1.0 threshold. Lowering to 0.5s risks Whisper hallucinations and empty results on short batches without smart segmentation
- Fallback path is serialized through `TranscriptionQueue` — no concurrent CoreML predictions

### Dead code removal (burn the ships)
Remove entirely from `MeetingRecorder`:
- `resolveSpeaker(source:samples:chunkStartTime:)` — owned by `SpeakerBufferManager` now
- `speakerLabelMap: [String: String]` — owned by `SpeakerBufferManager` now
- `nextSpeakerNumber: Int` — owned by `SpeakerBufferManager` now
- `processedSystemTexts: Set<String>` — deduplication was for overlapping 5s chunks; atomic per-speaker buffers are unique by construction

`processedMicTexts` stays — mic still uses the 5s path and can produce overlapping text.

Rationale: `SpeakerBufferManager` is the single owner of speaker identity. Leaving duplicates in `MeetingRecorder` creates architectural drift and confusion.

### Claude's Discretion
- Exact name and signature details for the new `TranscriptionQueue` overload
- How `bufferConsumerTask` awaits completion (e.g., `await bufferConsumerTask?.value` vs Task cancellation + join pattern)
- Whether `cancelRecording()` cancels `bufferConsumerTask` directly (data loss acceptable on cancel) or follows the same teardown order as `stopRecording()`
- Internal helper name for the new system-buffer transcription path (e.g., `transcribeClosedBuffer(_:)`)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Source files being modified
- `Sources/MeetingRecorder.swift` — The primary file: add consumer loop, activeSpeakerLabel, new TranscriptionQueue overload call; remove dead code
- `Sources/TranscriptionQueue.swift` — Add new `enqueue(buffer:processor:)` overload

### Source files to read but NOT modify in Phase 8
- `Sources/SpeakerBufferManager.swift` — Output type: `AsyncStream<ClosedSpeakerBuffer>`, `ClosedSpeakerBuffer` struct, `.start()` / `.stop()` lifecycle
- `Sources/DualChannelAudioCapture.swift` — `startCapture(onAudioChunk:onSystemBatch:)` and `stopCapture()` signatures (Phase 7 output)

### Requirements & roadmap
- `.planning/REQUIREMENTS.md` — Phase 8 is an integration phase (no new requirements); exercises PIPE-01..04, PIPE-06, SPKR-01..03 end-to-end
- `.planning/ROADMAP.md` §"Phase 8" — 4 success criteria, especially criterion 2 (activeSpeakerLabel before ASR text) and criterion 3 (MeetingSession/MeetingStorage unchanged)

### Prior phase decisions
- `.planning/phases/06-speakerbuffermanager-actor/06-CONTEXT.md` — `ClosedSpeakerBuffer` struct, `DiarizationProvider` protocol, label resolution ownership, `DiarizerManager` initialization pattern
- `.planning/phases/07-dualchannelaudiocapture-streaming-callback/07-CONTEXT.md` — `onSystemBatch` callback interface, `speakerBufferManager` lifecycle ownership in `MeetingRecorder`

No external specs — requirements fully captured in decisions above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `TranscriptionQueue` (`Sources/TranscriptionQueue.swift`): Already top-level actor. Add one new overload; existing `enqueue(source:samples:startTime:processor:)` stays for mic path. `drain()` unchanged.
- `SpeakerBufferManager.buffers` (nonisolated let): The AsyncStream to consume. Already emitting `ClosedSpeakerBuffer` with `samples`, `speakerLabel`, `startTime`.
- `processAudioChunk(source:samples:startTime:isFinal:)`: Mic-only after Phase 8. The `source == .microphone` guard at the top of the function body will be the cleanup anchor.

### Established Patterns
- `@MainActor` on `MeetingRecorder` — all mutations to `@Published` properties happen on MainActor
- `Task { await self.speakerBufferManager?.onAudioBatch(...) }` in `onSystemBatch` — same fire-and-forget Task pattern for the consumer Task start
- `pollingTask: Task<Void, Never>?` in `SpeakerBufferManager` — exact pattern to replicate for `bufferConsumerTask`
- `Logger.log("...", log: Logger.general, type: .error)` — logging style throughout

### Integration Points
- `startRecording()` line ~117: after `await manager.start()`, add `startBufferConsumer(manager:)` or inline the consumer Task
- `stopRecording()` line ~189: after `await manager.stop()`, await `bufferConsumerTask?.value`, then proceed to `transcriptionQueue.drain()`
- `cancelRecording()`: cancel `bufferConsumerTask` directly (data loss on cancel is acceptable — recording was aborted)
- `cleanup()`: set `bufferConsumerTask = nil`, `activeSpeakerLabel = ""`

</code_context>

<specifics>
## Specific Ideas

- **"Zero Data Loss" teardown**: The exact phrase and contract from the user. The teardown order (stop manager → await consumer → drain mic) must be documented inline in `stopRecording()` with a comment block explaining why this order is non-negotiable.
- The "burn the ships" cleanup philosophy applies here — no commented-out old code, no fallback for removed methods. If `SpeakerBufferManager` owns it, `MeetingRecorder` no longer has it at all.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within Phase 8 scope.

</deferred>

---

*Phase: 08-meetingrecorder-pipeline-rewire*
*Context gathered: 2026-03-22*
