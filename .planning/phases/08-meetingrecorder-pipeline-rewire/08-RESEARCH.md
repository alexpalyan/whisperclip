# Phase 08: MeetingRecorder Pipeline Rewire - Research

**Researched:** 2026-03-22
**Domain:** Asynchronous Audio Pipelining & Speaker Attribution
**Confidence:** HIGH

## Summary

This phase integrates the components built in Phases 6 and 7 (`SpeakerBufferManager`, `DualChannelAudioCapture`, `TranscriptionQueue`) into a cohesive, high-performance recording pipeline. The primary architectural challenge is coordinating multiple asynchronous streams to ensure zero data loss during teardown and correct real-time speaker attribution for UI updates.

The pipeline transitions from a 5s-chunk-based model to an atomic per-speaker-buffer model. `SpeakerBufferManager` acts as the producer for system audio, while `DualChannelAudioCapture` provides a separate microphone path. `MeetingRecorder` coordinates these into a single `TranscriptionQueue` for serialized ASR.

**Primary recommendation:** Use a dedicated `bufferConsumerTask` to drain the `SpeakerBufferManager.buffers` stream, updating `activeSpeakerLabel` immediately upon buffer arrival to ensure visual feedback precedes text appearance.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **activeSpeakerLabel publisher**: Publish `@Published private(set) var activeSpeakerLabel: String = ""` on `MeetingRecorder`.
- **AsyncStream consumer loop**: Own the loop in `private var bufferConsumerTask: Task<Void, Never>?`. Hop to `@MainActor` for label updates.
- **Zero Data Loss teardown sequence**: 
  1. `await speakerBufferManager.stop()` (flushes remaining buffers).
  2. Await `bufferConsumerTask` (drains flushed buffers).
  3. `await transcriptionQueue.drain()` (waits for ASR completion).
  4. Process final mic chunk.
- **TranscriptionQueue extension**: Add `enqueue(buffer: ClosedSpeakerBuffer, processor: ...)` overload.
- **Fallback Mode**: If `SpeakerBufferManager` is nil, fallback to channel-based attribution with "Other" label and 2s chunking.
- **Dead code removal**: Remove `resolveSpeaker()`, `speakerLabelMap`, `nextSpeakerNumber`, and `processedSystemTexts` from `MeetingRecorder`.

### Claude's Discretion
- Exact name and signature details for the new `TranscriptionQueue` overload.
- How `bufferConsumerTask` awaits completion.
- Whether `cancelRecording()` cancels the task directly (data loss is acceptable on cancel).
- Internal helper name for the new system-buffer transcription path.

### Deferred Ideas (OUT OF SCOPE)
- Waveform color (Phase 9).
- Chat bubble UI (Phase 10).
- Speaker naming UI.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| PIPE-01..04 | Per-speaker buffers & 30s cap | Handled by `SpeakerBufferManager` actor. |
| PIPE-06 | 0.5s floor for buffers | Handled by `SpeakerBufferManager` actor. |
| SPKR-01..03 | Stable speaker labels | Handled by `SpeakerBufferManager` actor. |
| RT-01..03 | Real-time waveform color (Infrastructure) | `activeSpeakerLabel` provides the state for these future features. |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Swift Concurrency | Native | AsyncStream / Task / Actor | Modern, thread-safe coordination of audio buffers. |
| MainActor | Native | UI State Management | Ensures thread-safety for `@Published` properties. |
| TranscriptionQueue | Internal | ASR Serialization | Prevents concurrent CoreML calls (existing project pattern). |

## Architecture Patterns

### Recommended Project Structure
`MeetingRecorder` serves as the coordinator for the following flow:
```
[DualChannelAudioCapture] 
   ├─> (Mic) -> TranscriptionQueue.enqueue(source:samples:...)
   └─> (System) -> SpeakerBufferManager.onAudioBatch(...)
                      └─> buffers (AsyncStream)
                            └─> MeetingRecorder.bufferConsumerTask
                                  └─> Update activeSpeakerLabel
                                  └─> TranscriptionQueue.enqueue(buffer:...)
```

### Pattern 1: Serialized Consumer Task
**What:** Use a non-cancelling `Task` to consume an `AsyncStream` until it is finished by the producer.
**When to use:** When processing stream items involves side effects (UI updates) and further async work (ASR).
**Example:**
```typescript
// Sources/MeetingRecorder.swift
bufferConsumerTask = Task {
    for await buffer in manager.buffers {
        await MainActor.run {
            self.activeSpeakerLabel = buffer.speakerLabel
        }
        await transcriptionQueue.enqueue(buffer: buffer) { [weak self] b in
            await self?.transcribeClosedBuffer(b)
        }
    }
}
```

### Anti-Patterns to Avoid
- **Implicit Data Loss**: Cancelling the consumer task before the producer has finished flushing. This drops the last speaker's turn.
- **Concurrent CoreML Prediction**: Bypassing the `TranscriptionQueue` and calling Whisper directly from multiple tasks.
- **Duplicate Identifiers**: Storing speaker labels in both `MeetingRecorder` and `SpeakerBufferManager`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Buffer Splitting | Custom chunking logic | `SpeakerBufferManager` | Handles 30s cap, 0.5s floor, and speaker changes correctly. |
| Speaker Attribution | Label mapping in Recorder | `SpeakerBufferManager` | Centralizes identity management; prevents drift between components. |
| ASR Serialization | Custom Semaphores | `TranscriptionQueue` (Actor) | Native Swift way to serialize access to sensitive resources like CoreML. |

## Common Pitfalls

### Pitfall 1: Teardown Race Condition
**What goes wrong:** `stopRecording()` returns before the last audio segment is transcribed.
**Why it happens:** The `AsyncStream` finishes, but the `transcriptionQueue` is still processing.
**How to avoid:** Explicitly `await transcriptionQueue.drain()` after the consumer task finishes.

### Pitfall 2: MainActor Deadlock/Lag
**What goes wrong:** Heavy UI updates block the audio ingestion path.
**Why it happens:** Updating `@Published` properties from the same task that processes audio.
**How to avoid:** Use `Task { await MainActor.run { ... } }` or ensure the consumer task is decoupled from the capture callback.

### Pitfall 3: Falling behind ASR
**What goes wrong:** ASR takes longer than audio duration, causing `TranscriptionQueue` to grow indefinitely.
**Why it happens:** High-resolution models on slower hardware.
**How to avoid:** Monitor queue size and consider falling back to faster models or skipping segments (though not for v1.1).

## Code Examples

### Zero Data Loss Teardown Sequence
Verified sequence from official Swift Concurrency patterns:
```swift
// Source: .planning/phases/08-meetingrecorder-pipeline-rewire/08-CONTEXT.md
func stopRecording() async {
    // 1. Stop producer (flushes final buffer)
    await speakerBufferManager?.stop()
    
    // 2. Await consumer completion (drains the stream)
    _ = await bufferConsumerTask?.result
    
    // 3. Stop capture & get final mic data
    let finalMic = await dualCapture?.stopCapture()
    
    // 4. Drain ASR queue (ensures all tasks finish)
    await transcriptionQueue.drain()
    
    // 5. Final mic processing
    if let mic = finalMic { await processAudioChunk(...) }
    
    cleanup()
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| 5s Fixed Chunks | Atomic Per-Speaker Buffers | Phase 8 | Correct attribution, no overlapping text. |
| RESOLVE in Recorder | RESOLVE in BufferManager | Phase 8 | Decoupled identity logic. |
| deduplicate processedTexts | Unique buffers by construction | Phase 8 | Simpler logic, fewer bugs. |

## Open Questions

1. **"Me" vs "Other" priority for `activeSpeakerLabel`**
   - What happens when both talk?
   - Recommendation: Since mic (`onAudioChunk`) is high-frequency, it should set `activeSpeakerLabel = "Me"`. If system audio buffer arrives, it overwrites with the speaker label. In Phase 9, this priority logic will be refined.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest |
| Config file | None |
| Quick run command | `swift test --filter MeetingRecorderTests` |
| Full suite command | `swift test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PIPE-08-01 | AsyncStream Consumer Loop | Integration | `swift test --filter MeetingRecorderTests` | ❌ Phase 8 |
| PIPE-08-02 | Zero Data Loss Teardown | Integration | `swift test --filter MeetingRecorderTests` | ❌ Phase 8 |
| PIPE-08-03 | activeSpeakerLabel updates | UI-unit | `swift test --filter MeetingRecorderTests` | ❌ Phase 8 |

### Wave 0 Gaps
- [ ] `Tests/MeetingRecorderTests.swift` — needs to mock `DualChannelAudioCapture` and `SpeakerBufferManager` to verify the pipeline wiring.

## Sources

### Primary (HIGH confidence)
- `Sources/SpeakerBufferManager.swift` - AsyncStream interface.
- `Sources/TranscriptionQueue.swift` - Actor serialization pattern.
- `.planning/phases/08-meetingrecorder-pipeline-rewire/08-CONTEXT.md` - Implementation decisions.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Native Swift Concurrency.
- Architecture: HIGH - Defined in 08-CONTEXT.
- Pitfalls: HIGH - Common in async audio pipelines.

**Research date:** 2026-03-22
**Valid until:** 2026-04-22
