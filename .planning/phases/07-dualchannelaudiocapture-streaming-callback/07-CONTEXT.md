# Phase 7: DualChannelAudioCapture Streaming Callback - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Replace the 5-second `chunkTimer` for system audio in `DualChannelAudioCapture` with a streaming callback that delivers samples directly to the caller as they arrive from ScreenCaptureKit. Mic path (AVAudioEngine → AudioBufferActor → AudioChunkCallback) is completely untouched. The caller (MeetingRecorder) is responsible for wiring the streaming output into SpeakerBufferManager.

</domain>

<decisions>
## Implementation Decisions

### Callback interface design
- `startCapture()` gains a second parameter: `onSystemBatch: @escaping ([Float], TimeInterval) -> Void`
- Full new signature: `func startCapture(onAudioChunk: @escaping AudioChunkCallback, onSystemBatch: @escaping ([Float], TimeInterval) -> Void) async throws`
- The existing `AudioChunkCallback` (`(AudioSource, [Float], TimeInterval) -> Void`) remains unchanged — mic still flows through it on the 5s timer
- `onSystemBatch` is **required**: if system audio capture starts but `onSystemBatch` is nil (e.g., not provided / default nil overload not supported), throw a `DualChannelError` — no silent fallback
- `DualChannelAudioCapture` calls `onSystemBatch` directly from the `SCStreamOutput` callback (nonisolated context) — no intermediate buffer, no timer

### SpeakerBufferManager lifecycle
- `DualChannelAudioCapture` is unaware of `SpeakerBufferManager` — it only calls `onSystemBatch` with raw samples
- `MeetingRecorder` calls `speakerBufferManager.start()` before `startCapture()` and `speakerBufferManager.stop()` after `stopCapture()`
- Clear separation: capture class handles I/O, recorder handles pipeline coordination

### CMSampleBuffer format check
- Verify format on **every** CMSampleBuffer in `SCStreamOutput` — catches mid-session audio device switches
- Check: `CMSampleBufferGetFormatDescription` → verify 32-bit float PCM (`kAudioFormatLinearPCM`, `kLinearPCMFormatFlagIsFloat`, 32-bit)
- On mismatch: log a warning + discard the buffer — recording continues, no crash
- On match: proceed to extract samples and call `onSystemBatch`

### stopCapture() return type
- Remove system samples from return type — system audio bypasses `AudioBufferActor` entirely after this phase
- New signature: `func stopCapture() async -> (samples: [Float], startTime: TimeInterval)`
- Returns only remaining mic samples (for final "Me" transcription flush at recording end)
- `AudioBufferActor.clearAll()` is called on stop as before; system buffer removal is a simplification

### Claude's Discretion
- Exact `DualChannelError` case name for missing `onSystemBatch`
- Whether to keep `AudioBufferActor.getSystemSamples()` (now dead code) or remove it
- How to handle the `Task` hop from `nonisolated` SCStreamOutput into `onSystemBatch` (likely `Task { onSystemBatch(...) }` with Sendable closure)
- Exact logging format for format mismatches

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Existing source files (read before modifying)
- `Sources/DualChannelAudioCapture.swift` — The file being modified: chunkTimer, AudioBufferActor, SCStreamOutput, startCapture/stopCapture
- `Sources/MeetingRecorder.swift` — Caller that must be updated to pass onSystemBatch and manage SpeakerBufferManager lifecycle
- `Sources/SpeakerBufferManager.swift` — Target of onSystemBatch: `actor.onAudioBatch(_ samples: [Float], atTime: TimeInterval)`

### Requirements
- `PIPE-05` in `.planning/REQUIREMENTS.md` — Mic is always "Me", processed separately, no diarization
- Phase 7 success criteria in `.planning/ROADMAP.md` — CMSampleBuffer format assertion, mic regression-free

No external specs — decisions fully captured above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `AudioBufferActor` (private, inside DualChannelAudioCapture.swift): mic buffer stays; system buffer becomes dead code and can be removed
- `DualChannelError` enum: add a new case for missing `onSystemBatch` (e.g., `systemBatchCallbackRequired`)
- Existing `AudioChunkCallback` typealias: unchanged, still used for mic path

### Established Patterns
- `nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer ...)` — the SCStreamOutput handler where `onSystemBatch` will be called directly instead of `Task { await audioBuffers.appendSystemSamples(...) }`
- `-strict-concurrency=complete` is enforced (Phase 6): `onSystemBatch` closure must be `Sendable` or captured via `nonisolated(unsafe)` pattern consistent with `startTime`
- `chunkTimer` lives in `startChunkProcessing()` / `processChunks()` — system audio path is removed from `processChunks()`; mic path in `processChunks()` stays intact

### Integration Points
- `MeetingRecorder.startRecording()` line ~121: `try await capture.startCapture { ... }` → becomes `try await capture.startCapture(onAudioChunk: { ... }, onSystemBatch: { samples, time in await speakerBufferManager.onAudioBatch(samples, atTime: time) })`
- `MeetingRecorder.stopRecording()` line ~176: `finalAudio = await capture.stopCapture()` → return type changes, only mic now
- Test target: `Tests/SpeakerBufferManagerTests.swift` already has `MockDiarizationProvider` — new tests for `DualChannelAudioCapture` streaming path will need a mock or integration approach

</code_context>

<specifics>
## Specific Ideas

No specific references or "I want it like X" moments — decisions are implementation-driven.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 07-dualchannelaudiocapture-streaming-callback*
*Context gathered: 2026-03-22*
