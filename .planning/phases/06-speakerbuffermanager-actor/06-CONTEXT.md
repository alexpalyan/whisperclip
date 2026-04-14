# Phase 6: SpeakerBufferManager Actor - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Create `SpeakerBufferManager` as a standalone, unit-testable Swift actor. It accumulates per-speaker audio buffers, drives periodic diarization polling to detect speaker changes, enforces the 30s cap and 0.5s floor, resolves stable speaker labels, and emits closed buffers as an `AsyncStream<ClosedSpeakerBuffer>`.

Phase 6 does NOT touch `DualChannelAudioCapture` (Phase 7), `MeetingRecorder` wiring (Phase 8), waveform color (Phase 9), or chat UI (Phase 10).

</domain>

<decisions>
## Implementation Decisions

### Diarization Polling Strategy
- **Periodic Polling** — NOT batch-triggered. A `while !Task.isCancelled` loop with `Task.sleep(nanoseconds:)` drives the diarization cadence.
- `pollingInterval` is a configurable property — **default 150ms** (High Profile for M4). Must be easy to change for a future Low Profile mode (e.g. 600ms for Air).
- **Natural serialization**: the poll loop `await`s the diarizer call. If CoreML takes >150ms the cadence stretches accordingly — no backlog, no skipping, no extra guard flag needed.
- **Sliding window per poll**: each poll runs diarization on the last 1 second of accumulated audio (not a delta since last poll). Simpler — no `lastPolledIndex` tracking required.
- Rationale: decouples high-priority audio ingestion (SCStreamOutput) from variable-latency ML inference. Zero audio dropouts on constrained hardware; scaling is a single constant change.

### Buffer Flush Interface
- Output type: `AsyncStream<ClosedSpeakerBuffer>` — caller does `for await buffer in manager.buffers { ... }`.
- `ClosedSpeakerBuffer` struct contains: `samples: [Float]`, `speakerLabel: String`, `startTime: TimeInterval`. Label is fully resolved inside the actor before emitting — caller gets a ready-to-transcribe buffer.
- On `stop()`: auto-flush the open buffer **if ≥ 0.5s (8,000 samples)**; discard silently if shorter. Mirrors cap/floor logic — consistent behavior.

### TranscriptionQueue Ownership
- Promote `TranscriptionQueue` from private-in-`MeetingRecorder.swift` to a **top-level internal type** in its own `TranscriptionQueue.swift`.
- `SpeakerBufferManager` knows nothing about `TranscriptionQueue`. The actor only emits `AsyncStream<ClosedSpeakerBuffer>`.
- Phase 8 (`MeetingRecorder` Rewire) owns the stream-consumption loop and enqueues into `TranscriptionQueue`.

### DiarizerManager Injection
- Define a `DiarizationProvider` **protocol**: `func diarize(_ samples: [Float], sampleRate: Int, atTime: TimeInterval) throws -> DiarizationResult`.
- `DiarizerManager` conforms to `DiarizationProvider`. Tests use `MockDiarizationProvider` — no FluidAudio dependency in unit tests.
- `SpeakerBufferManager.init` accepts `diarizer: any DiarizationProvider`.
- **MeetingRecorder owns model loading**: loads `DiarizerModels`, creates `DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.3))`, passes it as the protocol-typed reference into the actor at recording start. Matches current initialization pattern.

### Speaker Label Resolution
- Label map (`[String: String]` — rawSpeakerId → "Speaker N") lives **inside** the actor. `resolveSpeaker()` logic moves from `MeetingRecorder` into `SpeakerBufferManager`.
- Labels are stable within a session — same rawSpeakerId always maps to the same label.
- Counter starts at 1 per session: "Speaker 1", "Speaker 2", ...

### Concurrency Constraints
- `SWIFT_STRICT_CONCURRENCY=complete` **must be enabled** before writing the first line of Phase 6.
- Actor compiles with **zero warnings** under strict concurrency.
- `onAudioBatch()` must not block the SCStreamOutput caller — append samples only, no inference on the hot path.

### Locked Parameters (from prior sessions)
- `clusteringThreshold = 0.3` → `speakerThreshold = 0.36`
- Never reset `DiarizerManager` between speaker turns — doing so destroys `SpeakerManager` embedding state.
- Hybrid split: speaker change detection AND 30s max duration cap
- Min floor: 0.5s = 8,000 samples at 16kHz — discard without invoking Whisper

### Claude's Discretion
- Exact `ClosedSpeakerBuffer` struct conformances (`Sendable`, `Equatable` etc.)
- `AsyncStream` continuation/buffer capacity
- How the polling Task is started and stored (e.g. stored as `Task<Void, Never>?`)
- Internal `[String: SpeakerBufferSlot]` dictionary key (rawSpeakerId vs session-assigned label)
- Whether `DiarizationResult` is a new type or reuses `FluidAudio`'s result type wrapped behind the protocol

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Pipeline & speaker requirements
- `.planning/REQUIREMENTS.md` — PIPE-01..04, PIPE-06, SPKR-01..03 (all Phase 6 requirements with acceptance criteria)
- `.planning/ROADMAP.md` §"Phase 6: SpeakerBufferManager Actor" — success criteria (5 items), phase dependencies

### Existing implementation to understand before changing
- `Sources/MeetingRecorder.swift` — current `resolveSpeaker()`, `speakerLabelMap`, `TranscriptionQueue` (private actor to be promoted), `DiarizerManager` initialization pattern
- `Sources/DualChannelAudioCapture.swift` — existing `AudioBufferActor` pattern; `chunkTimer` (to be removed in Phase 7, not Phase 6); SCStreamOutput callback cadence

### Project constraints
- `.planning/PROJECT.md` §"Key Decisions" — `clusteringThreshold` history, hybrid splitting decision, never-reset-DiarizerManager rule
- `.planning/STATE.md` §"Diarization Debug Session" — diagnostic log of threshold tuning, root problem statement

No external ADRs — all decisions fully captured above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `TranscriptionQueue` (MeetingRecorder.swift:486): Private actor to be promoted to top-level. Serializes CoreML predictions with `enqueue()` and `drain()`. Phase 6 researcher should read its interface before proposing the new file.
- `AudioBufferActor` (DualChannelAudioCapture.swift:373): Pattern for a simple append/get actor — use as reference for `SpeakerBufferManager`'s internal buffer slot design.
- `DiarizerManager.performCompleteDiarization(_:sampleRate:atTime:)`: Current synchronous call site (MeetingRecorder.swift:355). This becomes the implementation of `DiarizationProvider.diarize()`.

### Established Patterns
- Swift actors with `nonisolated(unsafe)` for pre-capture state (see `DualChannelAudioCapture.startTime`)
- `@MainActor` on `MeetingRecorder` and `DualChannelAudioCapture` — `SpeakerBufferManager` is a plain actor (not `@MainActor`)
- Logger calls: `Logger.log("...", log: Logger.general, type: .error)` — use same pattern

### Integration Points
- Phase 6 only creates the actor and its supporting types (`ClosedSpeakerBuffer`, `DiarizationProvider`, `TranscriptionQueue.swift`)
- Phase 7 wires the stream callback from `DualChannelAudioCapture` → `SpeakerBufferManager.onAudioBatch()`
- Phase 8 wires `MeetingRecorder` to consume the `AsyncStream<ClosedSpeakerBuffer>` and enqueue into `TranscriptionQueue`
- No changes to `MeetingRecorder`, `DualChannelAudioCapture`, or any UI in Phase 6

</code_context>

<specifics>
## Specific Ideas

- **"Elastic Link" framing**: periodic polling is the elastic buffer between high-priority audio ingestion and variable-latency ML inference. On M4 @ 150ms it feels real-time; on Air it degrades gracefully by adjusting `pollingInterval` alone.
- pollingInterval should be a `let` constant on the actor with a clear comment marking it as the tuning knob for hardware profiles — easy to find and change.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within Phase 6 scope.

</deferred>

---

*Phase: 06-speakerbuffermanager-actor*
*Context gathered: 2026-03-22*
