# Phase 6: SpeakerBufferManager Actor - Research

**Researched:** 2026-03-22
**Domain:** Swift actor concurrency, FluidAudio DiarizerManager, AsyncStream
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **Diarization polling**: `while !Task.isCancelled` loop + `Task.sleep(nanoseconds:)`. Default interval 150ms. Natural serialization — poll `await`s diarizer, cadence stretches on slow hardware.
- **Sliding window per poll**: last 1 second of accumulated audio. No `lastPolledIndex` tracking.
- **Output**: `AsyncStream<ClosedSpeakerBuffer>`. `ClosedSpeakerBuffer` contains `samples: [Float]`, `speakerLabel: String`, `startTime: TimeInterval`. Labels resolved inside the actor.
- **On `stop()`**: auto-flush if ≥ 0.5s (8,000 samples), discard silently if shorter.
- **TranscriptionQueue promotion**: Promote from private-in-MeetingRecorder to top-level `TranscriptionQueue.swift` (internal). `SpeakerBufferManager` does not touch it — emits stream only.
- **DiarizationProvider protocol**: `func diarize(_ samples: [Float], sampleRate: Int, atTime: TimeInterval) throws -> DiarizationResult`. `DiarizerManager` conforms. Tests use `MockDiarizationProvider`.
- **`SpeakerBufferManager.init`** accepts `diarizer: any DiarizationProvider`.
- **MeetingRecorder owns model loading**: creates `DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.3))`, passes it as protocol-typed reference.
- **Speaker label map** lives inside the actor. `resolveSpeaker()` logic moves from `MeetingRecorder` into `SpeakerBufferManager`. Labels are "Speaker 1", "Speaker 2", counter starts at 1.
- **`SWIFT_STRICT_CONCURRENCY=complete`** must be enabled before writing first line. Zero warnings.
- **`clusteringThreshold = 0.3`** → `speakerThreshold = 0.36`. Never reset `DiarizerManager` between turns.
- **Hybrid split**: speaker change detection AND 30s max duration cap.
- **Min floor**: 0.5s = 8,000 samples at 16kHz.

### Claude's Discretion

- Exact `ClosedSpeakerBuffer` struct conformances (`Sendable`, `Equatable` etc.)
- `AsyncStream` continuation/buffer capacity
- How the polling Task is started and stored (e.g. stored as `Task<Void, Never>?`)
- Internal `[String: SpeakerBufferSlot]` dictionary key (rawSpeakerId vs session-assigned label)
- Whether `DiarizationResult` is a new type or reuses FluidAudio's result type wrapped behind the protocol

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within Phase 6 scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| PIPE-01 | Accumulate audio in per-speaker buffer continuously instead of fixed 5s chunks | AudioBufferActor pattern + actor append-only hot path |
| PIPE-02 | When diarizer detects speaker change — close current buffer, dispatch to Whisper | Polling loop + speaker change comparison + AsyncStream yield |
| PIPE-03 | If one speaker talks >30s without change — force-flush buffer (max duration cap) | Sample count arithmetic inside actor state |
| PIPE-04 | Each closed buffer sent to Whisper as atomic task — text 100% attributed to one speaker | ClosedSpeakerBuffer carries resolved speakerLabel before emission |
| PIPE-06 | Buffers shorter than 0.5s (8,000 samples) rejected without invoking Whisper | Guard on sample count at flush/discard decision point |
| SPKR-01 | System audio processed through DiarizerManager with stable speaker IDs across session | DiarizationProvider protocol wraps DiarizerManager; never reset between turns |
| SPKR-02 | clusteringThreshold=0.3 (speakerThreshold=0.36) for reliable differentiation | Already wired in MeetingRecorder; carried into SpeakerBufferManager config |
| SPKR-03 | Speakers assigned stable "Speaker 1", "Speaker 2" labels across all session buffers | Label map `[String: String]` inside actor; counter never resets |
</phase_requirements>

---

## Summary

Phase 6 creates three new files (`SpeakerBufferManager.swift`, `TranscriptionQueue.swift`, supporting types) as a standalone, zero-dependency layer between audio ingestion and Whisper invocation. No existing source files are modified in this phase.

The core challenge is bridging two different concurrency regimes: a high-frequency, nonisolated SCStreamOutput callback (arriving on a DispatchQueue-based thread) and a variable-latency CoreML diarization call. The actor model is the right tool — `onAudioBatch()` appends samples in O(n) without inference, the polling loop serializes diarizer calls naturally.

The second challenge is the `DiarizerManager` type itself: it is a `public final class` (not an actor) compiled in Swift 6 mode (`swift-tools-version: 6.0`), meaning the compiler treats it as non-Sendable unless wrapped. The `DiarizationProvider` protocol is the architectural firewall that keeps `SpeakerBufferManager` isolated from FluidAudio's class hierarchy. The actor owns the `DiarizerManager` reference and calls it exclusively from within actor isolation — this is the correct pattern under `SWIFT_STRICT_CONCURRENCY=complete`.

**Primary recommendation:** Implement `SpeakerBufferManager` as a plain Swift actor with a stored `Task<Void, Never>?` for the polling loop, an `AsyncStream.Continuation` stored on the actor for buffer emission, and the `DiarizationProvider` protocol reference also stored on the actor — all calls to the diarizer happen from within actor isolation, preventing any cross-isolation data race.

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| FluidAudio | 0.10.0+ (from Package.swift) | `DiarizerManager`, `DiarizationResult`, `TimedSpeakerSegment` | Already in project; only library available |
| Swift Concurrency | Swift 6.2.4 (toolchain) | `actor`, `AsyncStream`, `Task`, `Task.sleep` | Language-native; zero dependencies |
| XCTest | bundled | Unit tests for actor methods | Project standard (existing 18 tests) |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| OSLog / Logger.swift | project-local | Structured logging | All log calls — follow `Logger.log("...", log: Logger.general, type:)` |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `AsyncStream` | `Combine.PassthroughSubject` | Combine requires `ObservableObject` wiring; AsyncStream is pure Swift concurrency, no import needed |
| polling loop | `AsyncStream`-based audio triggers | Trigger-based approach couples diarization to audio arrival rate; polling decouples latency profiles |

**Installation:** No new packages required. Phase 6 uses only existing dependencies.

---

## Architecture Patterns

### Recommended Project Structure

```
Sources/
├── SpeakerBufferManager.swift   # actor SpeakerBufferManager + SpeakerBufferSlot
├── DiarizationProvider.swift    # protocol DiarizationProvider + ClosedSpeakerBuffer struct
├── TranscriptionQueue.swift     # actor TranscriptionQueue (promoted from MeetingRecorder.swift)
```

### Pattern 1: Actor with AsyncStream Output

**What:** The actor owns an `AsyncStream<ClosedSpeakerBuffer>.Continuation`. When the polling loop detects a speaker change or cap is reached, it calls `continuation.yield(closedBuffer)`. The caller does `for await buffer in manager.buffers { ... }`.

**When to use:** Any time a stateful actor needs to push events to an external consumer without the consumer calling back into the actor (avoiding deadlocks).

**Example:**
```swift
// Source: Apple developer docs — AsyncStream.makeStream(of:bufferingPolicy:)
actor SpeakerBufferManager {
    private var continuation: AsyncStream<ClosedSpeakerBuffer>.Continuation?
    nonisolated let buffers: AsyncStream<ClosedSpeakerBuffer>

    init(diarizer: any DiarizationProvider) {
        let (stream, continuation) = AsyncStream<ClosedSpeakerBuffer>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.buffers = stream
        // continuation stored in a Task to avoid init isolation escape
        // See Pattern 3 for the safe init approach
        _ = continuation  // stored via postInit or Task
    }
}
```

**Critical note on `makeStream`:** `AsyncStream.makeStream(of:bufferingPolicy:)` is available since Swift 5.9 / macOS 14. The project targets macOS 14+, so this is safe. It returns a `(AsyncStream<Element>, AsyncStream<Element>.Continuation)` tuple.

### Pattern 2: Non-Blocking Audio Ingestion

**What:** `onAudioBatch(_:atTime:)` is a plain `async` actor method that only appends to an internal `[Float]` buffer and records `bufferStartTime`. Zero inference on the hot path.

**When to use:** The SCStreamOutput callback fires on a DispatchQueue thread. It creates a `Task { await manager.onAudioBatch(...) }` — the `Task` returns immediately; the actor enqueues the work.

**Example:**
```swift
// Source: DualChannelAudioCapture.swift existing pattern (audioBuffers actor)
func onAudioBatch(_ samples: [Float], atTime time: TimeInterval) {
    if accumulatedSamples.isEmpty {
        bufferStartTime = time
    }
    accumulatedSamples.append(contentsOf: samples)
}
```

### Pattern 3: Storing AsyncStream.Continuation Under SWIFT_STRICT_CONCURRENCY=complete

**What:** The continuation is a `Sendable` struct (`AsyncStream<T>.Continuation` is `Sendable`), but storing it in an actor requires care during init because the actor's executor is not set up yet.

**Correct approach — two-phase init:**
```swift
// Source: Swift Evolution SE-0314 / WWDC22 "Meet Swift Async Algorithms"
actor SpeakerBufferManager {
    private var continuation: AsyncStream<ClosedSpeakerBuffer>.Continuation?
    nonisolated let buffers: AsyncStream<ClosedSpeakerBuffer>

    init(diarizer: any DiarizationProvider, pollingInterval: UInt64 = 150_000_000) {
        var cap: AsyncStream<ClosedSpeakerBuffer>.Continuation?
        self.buffers = AsyncStream { continuation in
            cap = continuation
        }
        // cap is captured synchronously by the closure before init returns
        self.continuation = cap
        self.diarizer = diarizer
        self.pollingInterval = pollingInterval
    }
}
```

The closure passed to `AsyncStream.init(_:)` is called synchronously, so the continuation is available before init returns. This is the canonical pattern and is safe under strict concurrency.

**Alternative using `makeStream`:**
```swift
// makeStream pattern avoids the captured-var dance:
let (stream, cont) = AsyncStream<ClosedSpeakerBuffer>.makeStream(bufferingPolicy: .unbounded)
self.buffers = stream
self.continuation = cont  // stored directly
```

Both approaches compile under `SWIFT_STRICT_CONCURRENCY=complete` because `AsyncStream<T>.Continuation` conforms to `Sendable`.

### Pattern 4: Polling Loop with Natural Serialization

**What:** A `Task<Void, Never>` stored as actor state runs the poll loop. The loop `await`s the diarizer call directly — if CoreML takes 300ms the loop simply runs at 300ms cadence that iteration.

```swift
// Source: Swift concurrency docs — structured tasks in actors
func start() {
    pollingTask = Task {
        while !Task.isCancelled {
            await pollDiarizer()
            try? await Task.sleep(nanoseconds: pollingInterval)
        }
    }
}

func stop() async {
    pollingTask?.cancel()
    pollingTask = nil
    await flushCurrentBuffer()
}
```

**Note:** `pollingTask` is stored as `Task<Void, Never>?` on the actor. Starting a `Task { }` from within an actor method inherits the actor's executor — the Task body runs on the actor. This is the correct pattern for actor-bound background work in Swift 6.

### Pattern 5: Sliding Window for Diarization Poll

**What:** Each poll takes the last `sampleRate * windowDuration` samples (1 second = 16,000 samples) from `accumulatedSamples` using an `ArraySlice` — no copy of the full buffer.

```swift
// Source: FluidAudio DiarizerManager.swift — ArraySlice is accepted by performCompleteDiarization
private func currentWindow() -> ArraySlice<Float> {
    let windowSize = sampleRate  // 1 second at 16kHz
    let start = max(0, accumulatedSamples.count - windowSize)
    return accumulatedSamples[start...]
}
```

`DiarizerManager.performCompleteDiarization` accepts `any RandomAccessCollection<Float>` where `C.Index == Int`. `ArraySlice<Float>` satisfies this constraint — zero-copy.

### Pattern 6: DiarizationProvider Protocol

**What:** Protocol wraps `DiarizerManager` to enable MockDiarizationProvider in tests without FluidAudio dependency.

```swift
// DiarizationProvider.swift
protocol DiarizationProvider: Sendable {
    func diarize(_ samples: [Float], sampleRate: Int, atTime: TimeInterval) throws -> DiarizationResult
}
```

**Critical: `DiarizationProvider` must conform to `Sendable`** so the actor can store `any DiarizationProvider` without a strict concurrency warning.

**DiarizerManager conformance:** `DiarizerManager` is a `public final class`. Under `SWIFT_STRICT_CONCURRENCY=complete`, a non-Sendable class stored in an actor triggers a warning. Two valid solutions:

1. **Conformance extension** (preferred if FluidAudio doesn't already mark it): Add `extension DiarizerManager: @unchecked Sendable {}` in WhisperClip source. This is acceptable here because `SpeakerBufferManager` is the sole actor that ever touches the DiarizerManager instance — the actor's serialization makes the access safe. Document this clearly.

2. **Nonisolated wrapper**: Wrap DiarizerManager in a separate actor. Adds complexity without benefit since the wrapping actor is just a pass-through.

The `@unchecked Sendable` approach is the pragmatic choice because the actor provides the synchronization guarantee. FluidAudio itself is compiled in Swift 6 mode, meaning the FluidAudio team is aware of concurrency requirements — and `DiarizerManager` is not marked `Sendable`, which is correct (it has mutable state).

### Anti-Patterns to Avoid

- **Calling `performCompleteDiarization` from `onAudioBatch()`**: Blocks the audio ingestion path. All diarizer calls must come exclusively from the polling task.
- **Resetting `DiarizerManager` between turns**: Destroys `SpeakerManager`'s embedding state, causing all speakers to become "Speaker 1". Never reset.
- **Storing `AsyncStream.Continuation` as `nonisolated(unsafe)`**: Unnecessary — `Continuation` is `Sendable`. Just store it as a normal actor property.
- **Using `Task.detached` for the polling loop**: Loses actor isolation. Use `Task { }` (unstructured but actor-inherited) so the loop body executes on the actor's executor.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Thread-safe queue | Custom `DispatchQueue` + `NSLock` | Swift `actor` | Actors serialize access by language contract; no manual locking |
| Async publisher | `Combine.PassthroughSubject` wiring | `AsyncStream` | AsyncStream is `Sendable`, works natively with `for await`, no Combine overhead |
| Speaker embedding comparison | Custom cosine similarity | `DiarizerManager` (via DiarizationProvider) | FluidAudio handles embedding + clustering; comparison is in `SpeakerManager.assignSpeaker()` |
| Segment type | Custom struct mirroring FluidAudio | `TimedSpeakerSegment` from FluidAudio directly in `DiarizationResult` | Already defined; `DiarizationResult` is `Sendable` |

**Key insight:** The `TranscriptionQueue` actor already exists and works — promote it exactly as-is. Do not redesign its interface.

---

## Common Pitfalls

### Pitfall 1: `DiarizerManager` Not Sendable Under Strict Concurrency

**What goes wrong:** Under `SWIFT_STRICT_CONCURRENCY=complete`, storing `any DiarizationProvider` in the actor will warn if the protocol itself is not `Sendable`. The actor compiler checks protocol conformance chains.

**Why it happens:** `DiarizerManager` is `public final class` with no `Sendable` conformance. The DiarizationProvider protocol must require `Sendable` so the actor storage is safe.

**How to avoid:** Declare `protocol DiarizationProvider: Sendable`. Add `extension DiarizerManager: @unchecked Sendable {}` in WhisperClip (not in FluidAudio). This is safe because the actor serializes all access.

**Warning signs:** `warning: sending 'self.diarizer' risks causing data races` during compilation.

### Pitfall 2: AsyncStream Continuation Escaping Actor Init

**What goes wrong:** If you try to store the continuation after init using `Task { self.continuation = cap }`, you get a warning about `self` captured before initialization is complete.

**Why it happens:** The actor executor isn't running during `init`, so deferred capture is flagged.

**How to avoid:** Use the synchronous closure form of `AsyncStream.init` or `makeStream` — both deliver the continuation synchronously before `init` returns.

### Pitfall 3: Speaker Change Detection False Positives on Silence

**What goes wrong:** When there is silence (no speech), `performCompleteDiarization` returns an empty `segments` array. If the previous poll had segments with speaker X, and the current poll returns empty, naively interpreting "no speaker" as a speaker change causes spurious buffer flushes.

**Why it happens:** Silence gaps are normal in conversation. An empty result means no detectable speech in the window, not a new speaker.

**How to avoid:** Only trigger a speaker change when the dominant speaker in the current poll result **differs from** the currently tracked speaker AND the current result is non-empty. Empty results should be ignored for speaker-change detection (buffer continues accumulating). Apply the 30s cap check regardless.

**Warning signs:** Very short, fragmented buffers with empty transcriptions reaching Whisper.

### Pitfall 4: `onAudioBatch()` Called Concurrently from Multiple Sources

**What goes wrong:** If Phase 7 eventually feeds both mic and system audio through the same actor, concurrent callers collide.

**Why it happens:** N/A for Phase 6 — `SpeakerBufferManager` only handles system audio. Mic is always `.me`. Document this boundary clearly so Phase 7 doesn't accidentally wire mic into the actor.

**How to avoid:** Add a comment and a `precondition` if desired: system audio only.

### Pitfall 5: `Task.sleep` Not Cancelling Cleanly on `stop()`

**What goes wrong:** `Task.sleep` throws `CancellationError` when the task is cancelled, but if the polling loop uses `try? await Task.sleep(...)` it swallows the error and continues looping for one extra iteration before `Task.isCancelled` is checked.

**Why it happens:** The `while !Task.isCancelled` check runs at the top of the loop; if sleep is at the bottom, one iteration runs after cancellation.

**How to avoid:** Use `try await Task.sleep(...)` and catch `CancellationError` explicitly to break, OR check `Task.isCancelled` immediately after the sleep before calling `pollDiarizer()`. The cleanest pattern:
```swift
while !Task.isCancelled {
    await pollDiarizer()
    do {
        try await Task.sleep(nanoseconds: pollingInterval)
    } catch {
        break  // Task cancelled
    }
}
```

### Pitfall 6: Minimum Speech Duration vs. Project Floor

**What goes wrong:** `DiarizerConfig.minSpeechDuration` defaults to `1.0s`. This means segments shorter than 1 second are **filtered out internally by FluidAudio** before being returned in `DiarizationResult.segments`. The project's 0.5s floor (PIPE-06) applies to the *accumulated buffer* before Whisper, not to diarization segments.

**Why it happens:** Two different "minimum duration" concepts: (a) FluidAudio's per-segment filter and (b) the project's buffer-level discard.

**How to avoid:** Do not confuse the two. The 8,000 sample check in `SpeakerBufferManager` is at buffer-flush time. The DiarizerConfig minimum affects what `performCompleteDiarization` returns — irrelevant to speaker change detection at the buffer level.

---

## Code Examples

Verified patterns from official sources and existing project code:

### DiarizerManager API (VERIFIED from source)

```swift
// Source: FluidAudio/Sources/FluidAudio/Diarizer/Core/DiarizerManager.swift
// Exact signature:
public func performCompleteDiarization<C>(
    _ samples: C, sampleRate: Int = 16000, atTime startTime: TimeInterval = 0
) throws -> DiarizationResult
where C: RandomAccessCollection, C.Element == Float, C.Index == Int

// DiarizationResult fields (from DiarizerTypes.swift):
public struct DiarizationResult: Sendable {
    public let segments: [TimedSpeakerSegment]  // empty when no speech detected
    public let speakerDatabase: [String: [Float]]?  // only in debugMode
    public let timings: PipelineTimings?             // only in debugMode
}

// TimedSpeakerSegment fields:
public struct TimedSpeakerSegment: Sendable, Identifiable {
    public let speakerId: String       // e.g. "SPEAKER_00", stable within session
    public let startTimeSeconds: Float
    public let endTimeSeconds: Float
    public var durationSeconds: Float  // computed property
    public let qualityScore: Float
}
```

### DiarizerConfig (VERIFIED from source)

```swift
// Source: FluidAudio/Sources/FluidAudio/Diarizer/Core/DiarizerTypes.swift
// For SpeakerBufferManager use clusteringThreshold=0.3 (locked decision):
let config = DiarizerConfig(clusteringThreshold: 0.3)
// Results in: speakerThreshold = 0.3 * 1.2 = 0.36 inside DiarizerManager.init
```

### Dominant Speaker Extraction (adapted from MeetingRecorder.resolveSpeaker)

```swift
// Source: Sources/MeetingRecorder.swift:376–387 (existing working code)
// Pick speakerId with most total speech time:
var durationBySpeaker: [String: Float] = [:]
for seg in result.segments {
    durationBySpeaker[seg.speakerId, default: 0] += seg.durationSeconds
}
let dominantId = durationBySpeaker.max(by: { $0.value < $1.value })?.key
```

### TranscriptionQueue Interface (VERIFIED from source)

```swift
// Source: Sources/MeetingRecorder.swift:486–528 — to be promoted verbatim
// Key methods:
func enqueue(
    source: AudioSource,
    samples: [Float],
    startTime: TimeInterval,
    processor: @escaping @MainActor (AudioSource, [Float], TimeInterval) async -> Void
) async

func drain() async
```

Phase 6 promotes this actor exactly as-is to `Sources/TranscriptionQueue.swift` with `internal` access. The only change is removing the `private` keyword from `private actor TranscriptionQueue`.

### AudioBufferActor Pattern (existing reference)

```swift
// Source: Sources/DualChannelAudioCapture.swift:373–415
// SpeakerBufferManager's internal buffer slot follows this exact pattern:
// - actor for isolation
// - simple append
// - startTime recorded on first append
// - drain returns (samples, startTime)
```

### Logging Pattern (from AGENTS.md and existing code)

```swift
// Source: AGENTS.md + Sources/MeetingRecorder.swift
Logger.log("SpeakerBufferManager: speaker change \(prev) → \(next), buffer \(sampleCount) samples", log: Logger.general)
Logger.log("SpeakerBufferManager: flushed buffer \(label) \(sampleCount) samples", log: Logger.general)
Logger.log("SpeakerBufferManager: discarded short buffer \(sampleCount) < 8000 samples", log: Logger.general)
```

### SWIFT_STRICT_CONCURRENCY Setup

```swift
// Package.swift — add swiftSettings to WhisperClip target:
.executableTarget(
    name: "WhisperClip",
    ...
    swiftSettings: [
        .unsafeFlags(["-strict-concurrency=complete"])
        // OR in Swift 5.10+ targets use:
        // .enableExperimentalFeature("StrictConcurrency")
    ]
)
// Swift 6 full mode via swiftLanguageVersions: [.v6] is more aggressive
// For Phase 6, -strict-concurrency=complete in Swift 5 mode is the locked decision
```

**Note:** The project's `Package.swift` currently uses `swiftLanguageVersions: [.v5]`. Adding `-strict-concurrency=complete` via `unsafeFlags` enables strict concurrency checking without migrating all existing code to Swift 6 mode. This is the correct scoped approach — it will surface warnings only in the WhisperClip target, and existing code may need minor annotation fixes.

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `chunkTimer` 5s fixed windows | Per-speaker accumulation + polling | Phase 6 introduces | Correct speaker attribution instead of dominant-speaker-per-chunk |
| `resolveSpeaker()` in `@MainActor MeetingRecorder` | `resolveSpeaker()` in plain `actor SpeakerBufferManager` | Phase 6 | Decouples CoreML from UI thread |
| `private actor TranscriptionQueue` in MeetingRecorder.swift | `internal actor TranscriptionQueue` in own file | Phase 6 | Testable, reusable, follows SRP |
| `DiarizerManager` called once per 5s chunk | `DiarizerManager` called every 150ms on 1s sliding window | Phase 6 | Near-real-time speaker change detection |

**Deprecated/outdated patterns in this phase:**
- `processAudioChunk(source:samples:startTime:isFinal:)`: MeetingRecorder's chunk processor is NOT touched in Phase 6. It remains as-is until Phase 8.
- `speakerLabelMap` and `nextSpeakerNumber` on `MeetingRecorder`: these move into `SpeakerBufferManager` in Phase 6, but `MeetingRecorder`'s copies stay until Phase 8 removes them.

---

## Open Questions

1. **`DiarizerManager` Sendable conformance**
   - What we know: `DiarizerManager` is `public final class` with no `Sendable` conformance in FluidAudio source
   - What's unclear: Whether adding `extension DiarizerManager: @unchecked Sendable {}` in WhisperClip source compiles without conflict if FluidAudio ever adds its own Sendable conformance
   - Recommendation: Add it in a `// TODO: remove when FluidAudio adds Sendable conformance` comment block. The actor-serialized access makes it factually safe.

2. **`-strict-concurrency=complete` flag ripple effect on existing sources**
   - What we know: Existing `MeetingRecorder`, `DualChannelAudioCapture` use `@MainActor` and `nonisolated(unsafe)` — patterns designed for strict concurrency but not yet enforced
   - What's unclear: Whether existing `Task { @MainActor in ... }` usages produce warnings under strict checking
   - Recommendation: Enable the flag, fix any warnings in existing files as part of Wave 0 of Phase 6. Do not defer — the locked decision requires zero warnings.

3. **CoreML latency on M-series hardware**
   - What we know: Diarization polling cadence (150ms) is unvalidated against actual CoreML latency (STATE.md blocker)
   - What's unclear: Whether M1 Air is ≥2x slower than M4 Pro for embedding extraction
   - Recommendation: Add `Logger.log("poll: \(Date().timeIntervalSince(pollStart))ms", ...)` in the poll loop during development. If latency > 300ms consistently, adjust `pollingInterval` or document the hardware profile.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (bundled) |
| Config file | `Package.swift` testTarget `WhisperClipTests` |
| Quick run command | `swift test --filter SpeakerBufferManagerTests` |
| Full suite command | `swift test --parallel --verbose` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PIPE-01 | `onAudioBatch()` appends to accumulation, does not block | unit | `swift test --filter SpeakerBufferManagerTests/testOnAudioBatchAppends` | ❌ Wave 0 |
| PIPE-01 | Multiple concurrent `onAudioBatch()` calls result in correct sample count | unit | `swift test --filter SpeakerBufferManagerTests/testConcurrentBatchIngestion` | ❌ Wave 0 |
| PIPE-02 | Speaker change triggers buffer close and emission | unit | `swift test --filter SpeakerBufferManagerTests/testSpeakerChangeFlushesPreviousBuffer` | ❌ Wave 0 |
| PIPE-03 | Buffer exceeding 30s (480,000 samples) is force-flushed | unit | `swift test --filter SpeakerBufferManagerTests/testMaxDurationCapForceFlush` | ❌ Wave 0 |
| PIPE-04 | Emitted `ClosedSpeakerBuffer.speakerLabel` matches resolved label | unit | `swift test --filter SpeakerBufferManagerTests/testEmittedBufferHasResolvedLabel` | ❌ Wave 0 |
| PIPE-06 | Buffer < 8,000 samples discarded without emission | unit | `swift test --filter SpeakerBufferManagerTests/testShortBufferDiscarded` | ❌ Wave 0 |
| PIPE-06 | Buffer ≥ 8,000 samples on `stop()` is flushed | unit | `swift test --filter SpeakerBufferManagerTests/testStopFlushesAdequateBuffer` | ❌ Wave 0 |
| SPKR-01 | Same rawSpeakerId across multiple polls maps to same label | unit | `swift test --filter SpeakerBufferManagerTests/testSpeakerLabelStability` | ❌ Wave 0 |
| SPKR-02 | `DiarizerConfig(clusteringThreshold: 0.3)` is used at init | unit (config inspection via mock) | `swift test --filter SpeakerBufferManagerTests/testDiarizerConfigThreshold` | ❌ Wave 0 |
| SPKR-03 | Labels are "Speaker 1", "Speaker 2" in order of first appearance | unit | `swift test --filter SpeakerBufferManagerTests/testSpeakerLabelOrdering` | ❌ Wave 0 |

**Manual-only tests:**
- CoreML latency measurement (requires hardware + model download)
- End-to-end diarization accuracy (requires Phase 7+8 integration)

### Sampling Rate

- **Per task commit:** `swift test --filter SpeakerBufferManagerTests`
- **Per wave merge:** `swift test --parallel --verbose`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `Tests/SpeakerBufferManagerTests.swift` — covers all 10 test cases above
- [ ] `Tests/MockDiarizationProvider.swift` — shared mock; used by SpeakerBufferManagerTests
- [ ] No framework install needed — XCTest already in `WhisperClipTests` target

**MockDiarizationProvider sketch:**
```swift
// Tests/MockDiarizationProvider.swift
// Source: project test pattern from HotkeySettingsViewModelTests.swift (NullHotkeyManager)
final class MockDiarizationProvider: DiarizationProvider, Sendable {
    var nextResult: DiarizationResult = DiarizationResult(segments: [])
    // Sendable: nextResult is set before concurrent access; or use actor if mutation needed
    func diarize(_ samples: [Float], sampleRate: Int, atTime: TimeInterval) throws -> DiarizationResult {
        return nextResult
    }
}
```

---

## Sources

### Primary (HIGH confidence)
- FluidAudio source — `.build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Core/DiarizerManager.swift` — exact `performCompleteDiarization` signature, `DiarizerManager` class structure
- FluidAudio source — `.build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Core/DiarizerTypes.swift` — `DiarizationResult`, `TimedSpeakerSegment`, `DiarizerConfig` verified field-by-field
- FluidAudio source — `.build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Clustering/SpeakerTypes.swift` — `Speaker` class, `SendableSpeaker` struct
- `Sources/MeetingRecorder.swift` — existing `resolveSpeaker()`, `TranscriptionQueue` actor, `DiarizerManager` initialization pattern
- `Sources/DualChannelAudioCapture.swift` — `AudioBufferActor` pattern, `nonisolated(unsafe) var startTime`, SCStreamOutput callback structure
- `Package.swift` — Swift tools version 5.10, `swiftLanguageVersions: [.v5]`, FluidAudio dependency `from: "0.10.0"`
- `AGENTS.md` — logger pattern, test runner commands, code style

### Secondary (MEDIUM confidence)
- FluidAudio `Package.swift` (swift-tools-version: 6.0) — confirms FluidAudio is compiled under Swift 6 strict concurrency; `DiarizerManager` is not `Sendable` by design
- `.planning/STATE.md` — diarization debug session log, threshold history, confirmed threshold 0.3 works

### Tertiary (LOW confidence — from training data, not verified against current docs)
- Swift Evolution SE-0314 (`AsyncStream`) — `makeStream` API, continuation `Sendable` conformance
- `Task.sleep` cooperative cancellation semantics in Swift 6

---

## Metadata

**Confidence breakdown:**
- FluidAudio API (`DiarizerManager`, `DiarizationResult`, `TimedSpeakerSegment`): HIGH — read from source in `.build/checkouts/`
- Architecture patterns (actor, AsyncStream, polling loop): HIGH — derived from existing project code and verifiable language semantics
- Strict concurrency approach (`@unchecked Sendable` for DiarizerManager): MEDIUM — correct approach but ripple effect on existing files is unvalidated until the flag is actually enabled
- Unit test patterns: HIGH — modeled directly on existing `HotkeySettingsViewModelTests` and `NullHotkeyManager` mock

**Research date:** 2026-03-22
**Valid until:** 2026-06-22 (FluidAudio API stable; Swift concurrency semantics stable)
