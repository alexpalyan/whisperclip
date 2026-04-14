# Pitfalls Research

**Domain:** Streaming per-speaker audio buffer management in macOS AVAudioEngine pipeline
**Researched:** 2026-03-22
**Confidence:** HIGH — all pitfalls derived directly from reading the existing codebase, not from general assumptions

---

## Critical Pitfalls

### Pitfall 1: Calling DiarizerManager Synchronously Inside the Audio Tap Callback

**What goes wrong:**
The new design must call `DiarizerManager.performCompleteDiarization()` to detect speaker changes and decide whether to flush a per-speaker buffer. If this call happens directly inside `processMicrophoneBuffer()` or `stream(_:didOutputSampleBuffer:)`, it blocks the audio engine's real-time callback thread. AVAudioEngine will underrun and drop audio frames silently; ScreenCaptureKit will drop CMSampleBuffers. The result is missing audio with no error thrown.

**Why it happens:**
`performCompleteDiarization()` runs a CoreML neural network inference that takes 20-100 ms per call on M-series chips. It looks synchronous. Developers insert it at the point where the decision "did the speaker change?" needs to be made, which is inside the callback where samples arrive.

The existing `processMicrophoneBuffer` already spawns `Task { await audioBuffers.appendMicSamples(...) }` to leave the tap thread immediately — but this is only for buffer appending. The diarization call will require the same discipline.

**How to avoid:**
Never call `performCompleteDiarization()` from within the audio tap closure or `SCStreamOutput.stream(_:didOutputSampleBuffer:)`. The tap must only copy samples into the `AudioBufferActor` and return. A separate `Task` or dedicated serial `DispatchQueue` must pull from the buffer actor and run diarization at a cadence the ML model can sustain (e.g., every 100-200 ms on a background queue).

Concretely: extend `AudioBufferActor` (or create a `SpeakerBufferActor`) that accumulates samples and exposes a polling method. A `Task` loop with a brief sleep (50-100 ms) or a Combine timer calls the actor, runs diarization, and closes/opens buffers — entirely off the audio thread.

**Warning signs:**
- Audio levels drop or freeze during diarization-dense passages
- `AVAudioEngine` console warnings: "Required condition is false: IsFormatSampleRateAndChannelCountValid"
- Total audio sample count at session end is less than expected recording duration × 16000
- `SCStreamDelegate.stream(_:didStopWithError:)` fires unexpectedly

**Phase to address:** Phase 1 (PIPE-01/PIPE-02 — per-speaker buffer accumulation). This is a load-bearing constraint for the entire architecture.

---

### Pitfall 2: Actor Reentrancy on `MeetingRecorder` State During Concurrent ASR Tasks

**What goes wrong:**
`MeetingRecorder` is `@MainActor`. When a speaker-change event fires a new ASR task while the previous task is still awaiting `asrManager.transcribe()`, both tasks have concurrent access to `speakerLabelMap`, `nextSpeakerNumber`, `processedSystemTexts`, and `segmentCount` on the main actor. Because Swift's `@MainActor` serializes synchronous code but yields at every `await`, a second task can interleave between the first task's `await asrManager.transcribe()` and the subsequent `speakerLabelMap[dominantId] = label` write.

The observed failure: two speaker-change events in quick succession (e.g., < 500 ms apart) both enter `resolveSpeaker`, both diarize the same short overlap window, and both assign "Speaker 1" to different underlying `speakerId` values — corrupting `speakerLabelMap` with a duplicate label entry.

**Why it happens:**
The existing `TranscriptionQueue` actor serializes CoreML predictions (prevents concurrent CoreML crashes), but its `drain()` mechanism uses a busy-wait poll (`Task.sleep` loop). More critically, when diarization-driven buffer flushing creates multiple rapid close events, each spawns a separate `Task` that jumps the queue or runs while the previous task is suspended at `await`.

The existing code comments note: "speakerIds (e.g. 'SPEAKER_00') are stable within a single performCompleteDiarization call but not guaranteed across calls." The label map guards against this — but only when writes are serialized.

**How to avoid:**
All `speakerLabelMap` mutations must happen inside a dedicated actor (not `@MainActor`) or must be protected by the `TranscriptionQueue` itself. Option A: move `speakerLabelMap` and `nextSpeakerNumber` into a new `SpeakerIdentityActor` whose `resolveLabel(rawId:)` is the sole write path. Option B: ensure the `TranscriptionQueue` processes the complete pipeline — diarization + label resolution + ASR — as a single non-reentrant unit per buffer.

The key insight: label resolution must happen *before* the `await asrManager.transcribe()` suspension point, or inside the actor-serialized unit, never after it.

**Warning signs:**
- Two segments in the same meeting labeled "Speaker 1" but clearly from different people
- `speakerLabelMap` log shows the same raw ID appearing twice with different labels across log lines
- "Speaker 1" and "Speaker 2" labels occasionally swapping roles mid-meeting

**Phase to address:** Phase 1 (SPKR-01 stable IDs). This must be designed into the buffer-close pipeline before any other speaker UI work.

---

### Pitfall 3: Unbounded Per-Speaker Audio Buffer Growth for Long Monologues

**What goes wrong:**
A speaker who talks for 10+ minutes without interruption accumulates `10 × 60 × 16000 = 9.6 million Float samples = ~38 MB` in a single buffer. At 30 minutes that is ~114 MB per speaker. With two system-audio speakers plus microphone, peak RSS during a 1-hour meeting can exceed 300 MB of audio data in memory simultaneously, before the existing WAV file writing in `writeWAVFile()` creates additional temporary copies.

The 30-second cap (PIPE-03) is the intended mitigation, but it is easy to implement incorrectly: if the cap is checked only at the moment the buffer is flushed, there is a window where a rapidly-speaking system-audio speaker can accumulate far more than 30 s worth of samples between diarization polls.

**Why it happens:**
The `AudioBufferActor` in `DualChannelAudioCapture` already accumulates `[Float]` with `append(contentsOf:)`. Swift arrays use doubling allocation, so each append beyond the current capacity reallocates the entire array. For large arrays this causes momentary 2× memory spikes (old + new allocation in-flight simultaneously).

**How to avoid:**
Implement the 30-second cap as a hard ceiling enforced at sample-append time, not only at flush time. Inside the per-speaker buffer actor, track `sampleCount`. When `sampleCount >= 30 × 16000`, set a `capReached: Bool` flag that the diarization polling loop checks before the next diarization call — immediately flushing and starting a new buffer.

Additionally, pre-allocate each per-speaker buffer with `reserveCapacity(30 * 16000 + 8192)` to prevent reallocation growth. This caps each buffer's maximum allocation at ~1.8 MB (30 s × 16000 × 4 bytes) and eliminates doubling spikes.

**Warning signs:**
- macOS Memory Report shows RSS growing monotonically during long meetings
- Xcode Memory Graph shows large `[Float]` heap allocations pinned to speaker buffer objects
- App is jettisoned by macOS under memory pressure during 45+ minute meetings
- `writeWAVFile()` call takes longer than expected (copying large arrays)

**Phase to address:** Phase 1 (PIPE-03 — 30s cap). The cap and pre-allocation must ship in the same phase as per-speaker accumulation, not as a follow-up.

---

### Pitfall 4: Out-of-Order ASR Task Completion Creating Mis-timed Segments

**What goes wrong:**
Speaker changes that occur in rapid succession (two speakers alternating every 2-3 seconds) flush multiple buffers quickly. Each buffer triggers an `asrManager.transcribe()` call taking 100-500 ms. If tasks are not strictly ordered by `startTime`, ASR task B (for the shorter buffer) can complete before task A (for the longer prior buffer). Both call `transcriptCallback?(segment)`, which calls `handleNewSegment()` in `MeetingSession`. `handleNewSegment` sorts `liveTranscript` by `startTime` — but `storage.addSegment()` calls `MeetingNote.addSegment()` which also sorts by `startTime`.

The failure: if ASR task B returns an empty or near-empty transcription (silence buffer), `segment.text` is empty and the guard `guard !transcriptionResult.text.isEmpty` drops it. But if ASR task B returns text that *overlaps in timestamp range* with task A (because diarization window overlap caused both to cover the same audio moment), both segments get stored with the same `startTime`, causing duplicate content in the meeting transcript.

**Why it happens:**
`TranscriptionQueue` serializes by queue order (FIFO), which is the right intent. But if the new per-speaker pipeline creates tasks outside the queue (e.g., direct `Task { await processAudioChunk(...) }` called from speaker-change detection), the serialization breaks. The current code in `MeetingRecorder.startRecording` does this correctly for the 5s chunk model, but a rewrite that calls `processAudioChunk` from speaker-change callbacks must explicitly re-enter through `transcriptionQueue.enqueue()`.

**How to avoid:**
Every buffer flush — whether triggered by speaker change or by the 30 s cap — must enter the existing `TranscriptionQueue.enqueue()` path. No direct `await processAudioChunk()` calls outside the queue. The queue's FIFO ordering ensures segments emerge in `startTime` order regardless of ASR latency variance.

Additionally, each flushed buffer should carry its `startTime` at the moment of flush (captured from the buffer actor's `bufferStartTime`), not recomputed from `Date()` at the time ASR returns. Timestamp must be captured at buffer-open time.

**Warning signs:**
- `liveTranscript` in MeetingSession occasionally shows segments out of order before the sort
- Two segments with identical or near-identical `startTime` values in `MeetingNote.segments`
- ASR log lines show "processing system chunk" out of buffer-open order
- Deduplication via `processedSystemTexts` hits false positives (text B matches prefix of text A from the same speaker)

**Phase to address:** Phase 1 (PIPE-04 — atomic ASR per buffer). The queue discipline and timestamp capture must be defined before speaker-change triggers are wired.

---

### Pitfall 5: Speaker ID Drift Across DiarizerManager Calls Due to Embedding Cluster Instability

**What goes wrong:**
`DiarizerManager` internally maintains a `SpeakerManager` that clusters audio embeddings. At `clusteringThreshold=0.3`, the threshold is aggressive — two embeddings are declared the same speaker only if cosine distance < 0.3. In a streaming context where each buffer contains only 2-10 seconds of audio, early buffers may not have enough speech to form stable centroids. Speaker 1 in buffer 3 gets assigned `SPEAKER_01`. In buffer 7, after more speech accumulation shifts the centroid, the same voice gets assigned `SPEAKER_00` instead. `speakerLabelMap["SPEAKER_01"]` correctly maps to "Speaker 1", but `speakerLabelMap["SPEAKER_00"]` maps to "Speaker 2" (created earlier) — the same real person now has two labels.

The current comment in `resolveSpeaker` acknowledges this: "speakerIds... are stable within a single performCompleteDiarization call but not guaranteed across calls."

**Why it happens:**
FluidAudio's `SpeakerManager` uses an online clustering algorithm. Early buffers have sparse embeddings; the cluster centroid is not yet stable. When a new buffer's embedding lands between two existing clusters and the clusteringThreshold creates a tie-breaking ambiguity, the assignment can flip. This is more likely at the session start (first 60 seconds) and after a long silence (embeddings expire or drift).

The existing single-call model (5 s chunks, all audio in one `performCompleteDiarization` call) is relatively stable because the full 5 s provides richer context. Per-speaker buffers of 2-3 s will exacerbate this instability.

**How to avoid:**
Two concrete mitigations:

1. **Minimum buffer duration before diarization.** Do not call `performCompleteDiarization` on buffers shorter than 3 s (48000 samples at 16 kHz). For very short speech turns (< 3 s), extend the buffer by prepending the tail of the previous buffer for the same speaker ("context padding"). This gives the model enough audio to form a stable embedding.

2. **Embedding-level identity tracking.** After the `speakerLabelMap` is populated, track the last known `dominantId` per label. If a new call returns a `dominantId` that is not in `speakerLabelMap`, and `result.segments.count == 1` (only one speaker in this window), check if it is plausible that this is a known speaker by comparing the raw embedding distance — if `FluidAudio` exposes it. Fall back to the previous label for that channel when confidence is low.

**Warning signs:**
- Meeting transcript shows "Speaker 1" and "Speaker 2" alternating within a single person's monologue
- Log shows `speakerLabelMap` growing beyond expected speaker count (> 2 entries for a 2-person call)
- Speaker label assignment is unstable in the first 60 seconds of recording
- Session logs show `new system-audio speaker` messages for the same voice being assigned multiple times

**Phase to address:** Phase 1 (SPKR-01, SPKR-02, SPKR-03). Context padding for short buffers should be a design constraint from the start, not a hotfix after label drift is observed.

---

### Pitfall 6: SwiftUI Updates from Background Audio Tasks Without Main Actor Hop

**What goes wrong:**
The new pipeline will have diarization running on a background `Task` that detects speaker changes and updates the active speaker state. If this Task updates any `@Published` property on `MeetingRecorder` (which is `@MainActor`) without an explicit `MainActor.run {}` or `await MainActor.run {}` boundary, Swift 5.10 will emit a sendability warning that can become a runtime crash in strict concurrency mode. More critically for the RT-01/RT-03 waveform color requirements: updating `activeSpeakers` from a non-main context causes SwiftUI to skip the animation frame, producing a visible color flicker or delayed transition.

**Why it happens:**
The current `processMicrophoneBuffer` already correctly uses `Task { @MainActor in self.micLevel = db }` for level updates. But the new speaker-change callback path is more complex: it will involve awaiting diarization results in a background Task, then conditionally calling the transcriptCallback, then updating `activeSpeakers`. Developers often forget the `@MainActor` hop at the end of a long async chain when the intermediate steps are background-context.

`MeetingRecorder` is `@MainActor`, so any method called on it from a non-isolated Task will cross the actor boundary correctly — but only if called with `await`. If any property is accessed directly (e.g., via a closure captured in a non-isolated context), the Swift compiler may not catch it without `SWIFT_STRICT_CONCURRENCY=complete`.

**How to avoid:**
Enable `SWIFT_STRICT_CONCURRENCY=complete` in the project build settings immediately before starting the v1.1 rewrite. This promotes all sendability and actor isolation warnings to errors, preventing the silent threading issues that only manifest at runtime. With strict concurrency, the compiler will flag every incorrect cross-actor access.

For the waveform color update (RT-01): `activeSpeakers` updates must happen inside `MainActor.run {}` and should be published before the `transcriptCallback` fires (so the UI color transition precedes the text segment appearing).

**Warning signs:**
- Purple thread sanitizer warnings in Xcode: "Publishing changes from background threads"
- Waveform color transition lags 200-500 ms behind actual speaker change
- `activeSpeakers` is updated but SwiftUI views do not re-render until the next frame
- Xcode shows sendability warnings on `DiarizerManager` or `[Float]` passed across task boundaries

**Phase to address:** Phase 1 (PIPE-01/RT-01). Enabling strict concurrency should be the first commit of the v1.1 rewrite branch, before any new pipeline code is written.

---

## Technical Debt Patterns

Shortcuts that seem reasonable but create long-term problems.

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Calling `performCompleteDiarization` every 5 s (reusing the old timer) instead of on speaker change | Reuses existing `DualChannelAudioCapture` timer infrastructure | Speaker attribution is still wrong — 5 s chunks may contain 3+ speaker turns, collapsed to dominant | Never for v1.1 — defeats the entire pipeline redesign |
| Using `String` equality on raw `speakerId` values (e.g. "SPEAKER_00") across calls | Simple, readable | IDs are not guaranteed stable across calls; equality checks produce false positives | Never — use the `speakerLabelMap` pattern already in place |
| Pre-allocating a single shared `[Float]` accumulator for all speakers | Reduces allocation count | Requires manual index management; race conditions if two speakers flush concurrently | Never — per-speaker actors are the right boundary |
| Skipping context-padding for short turns (< 3 s) | Simpler buffer management | Embedding instability causes speaker ID drift at start of session | MVP-acceptable if clusteringThreshold is tuned higher (0.4), but revisit in v1.2 |
| Using `drain()` busy-wait poll in `TranscriptionQueue` for stop-recording flush | Simple to implement | 10 ms poll interval can add up to 100 ms latency at session end; Combine continuation would be cleaner | Acceptable for v1.1 — document as known tech debt |
| Hardcoding `confidence: 0.95` on every `MeetingSegment` | No logic needed | Misleads downstream consumers (summary AI, QA) into treating all segments as equally reliable | Acceptable until FluidAudio exposes per-segment confidence scores |

---

## Integration Gotchas

Common mistakes when connecting to external services/components.

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| `DiarizerManager.performCompleteDiarization` | Passing the full accumulated buffer (30 s) expecting N speaker segments in return, then using all of them to drive future splits | Only the *new* audio since last diarization call should be passed; passing the full buffer re-processes old audio and inflates `speakerLabelMap` with phantom IDs |
| `DiarizerManager` across recording sessions | Re-using the same `DiarizerManager` instance between meetings | `speakerLabelMap` and `nextSpeakerNumber` are session-scoped; `diarizerManager = nil` in `cleanup()` is correct — verify new pipeline maintains this |
| `asrManager.transcribe(tempURL)` | Calling from inside the `TranscriptionQueue` actor's own async context (creating nested actor reentrancy) | `transcribe()` must be called on a non-isolated context — current pattern (processor closure passed to `enqueue`) is correct; preserve it |
| `AudioBufferActor.getMicSamples()` / `getSystemSamples()` | Calling get + append concurrently from two different Tasks without awaiting | Actor serializes access; safe. But a Task doing `get` while another is mid-`append` will see a partial buffer. Ensure flush only happens from the poller Task, not from the tap closure |
| `SCStreamOutput.stream(_:didOutputSampleBuffer:)` | Bridging `CMSampleBuffer` to `[Float]` by assuming 32-bit float PCM — current code does this correctly but without format validation | If ScreenCaptureKit returns a different sample format (e.g., Int16 under some macOS versions), the raw memory cast produces garbage audio. Add a format assertion on `CMSampleBuffer.formatDescription` |
| `FluidAudio` DiarizerManager `clusteringThreshold` | Setting threshold below 0.2 thinking lower = better separation | Below ~0.25, most speech embeddings fall into distinct clusters even from the same speaker (breath sounds, phoneme variation), creating phantom speakers per sentence |

---

## Performance Traps

Patterns that work at small scale but fail as usage grows.

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| `Array<Float>.append(contentsOf:)` with no pre-allocation for per-speaker buffers | Each ~4096-sample tap callback triggers a reallocation when the array doubles; 16 reallocations needed to reach 30 s | Pre-allocate with `reserveCapacity(30 * 16_000)` at buffer-open time | Every chunk; degrades at start when allocations are frequent |
| Running diarization on every new tap callback (~128 calls/second at 4096-sample blocks) | CoreML queue saturation; audio drops; CPU pegged at 100% | Diarization poll at 100-200 ms cadence only, not per-tap | From first tap; invisible until tested on real hardware |
| Sorting `liveTranscript` in `MeetingSession.handleNewSegment()` on every segment | O(n log n) per segment; for a 200-segment meeting this runs 200 times | Use `insertSorted` (binary search + insert) — `MeetingNote.addSegment()` already does this correctly; ensure `MeetingSession.liveTranscript` uses the same pattern | > 50 segments; noticeable on live transcript scroll during fast speaker alternation |
| Temporary WAV file creation per flushed buffer | I/O write per speaker turn; for 2-person meeting at 5 s/turn that's 24 writes/minute | Acceptable for now; future optimization is in-memory `AVAudioPCMBuffer` passed directly to ASR if `asrManager.transcribe()` gains a buffer overload | Not a problem for v1.1 meetings (< 60 min), revisit in v1.2 |
| `Task { @MainActor in self.micLevel = db }` per tap callback in `processMicrophoneBuffer` | One Task creation per 4096-sample buffer ≈ 4 Task/s for 16 kHz audio — acceptable | This rate is fine; do not replicate this pattern for diarization-triggered events which could fire much more often | Fine at current rate; would break if tap buffer size were reduced to 256 samples |

---

## Security Mistakes

Domain-specific security issues beyond general web security.

| Mistake | Risk | Prevention |
|---------|------|------------|
| Writing per-speaker buffers to `FileManager.default.temporaryDirectory` without restricting permissions | Another local process can read temporary WAV files during recording | Use `URL.temporaryDirectory` with `FileProtectionType.complete` on macOS (via extended attributes), or create files in app sandbox container — current code uses `/tmp/meeting_{source}_{UUID}.wav` which is sandboxed by default on macOS App Store builds |
| Logging `samples.count` and `startTime` at `.debug` level | Reveals meeting timing metadata in log files | Current code uses `Logger.log` which respects `GenericHelper.logSensitiveData()` flag — ensure speaker segment text is gated the same way |
| Using `nonisolated(unsafe) var startTime` in `DualChannelAudioCapture` | Accessed from SCStreamOutput callback thread without synchronization — technically a data race | Current usage is read-only after write (written once in `startCapture`, only read in callbacks after that) — correct for this pattern; document this constraint explicitly if the pipeline rewrite needs to reset startTime mid-session |

---

## UX Pitfalls

Common user experience mistakes in this domain.

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Waveform color change fires on every diarization poll (every 100-200 ms) even during stable speaker periods | Constant color flicker on waveform even when only one person is speaking | Only publish `activeSpeakers` update when the detected `dominantId` actually changes from the previous poll result; debounce with a minimum-change filter |
| Speaker label "Speaker 1" / "Speaker 2" assigned in diarization order (first detected first) instead of speaking-time order | In a meeting where the "other" person speaks first, they become "Speaker 1" even if the local user hears them as the remote participant | For v1.1 this is acceptable; note as known behavior for v1.2 where speaker naming UI can let users rename labels |
| Chat-style bubble grouping breaks when two diarization-driven segments from the same speaker have a gap > N seconds | Transcript looks fragmented; "Speaker 1" appears as separate bubble groups for the same continuous thought | Define grouping threshold (e.g., 3-second gap) explicitly as a constant, not hardcoded in the view layer |
| "Me" waveform bar stays its color while "Speaker 1" and "Speaker 2" share the remaining two palette slots | Users with more than 2 meeting participants see all non-local speakers collapse into two colors | For v1.1 (two-person meetings), acceptable; design `colorIndex` to scale to 6+ speakers gracefully in v1.2 (current `hashValue % 7` already supports this) |

---

## "Looks Done But Isn't" Checklist

Things that appear complete but are missing critical pieces.

- [ ] **Per-speaker buffer accumulation (PIPE-01):** Buffer appears to accumulate correctly in unit tests but no stress test verifies behavior when both channels flush simultaneously — verify concurrent flush safety in `AudioBufferActor`
- [ ] **Speaker change trigger (PIPE-02):** Speaker change is detected in diarization logs but `activeSpeakers` @Published property is not updated before the next UI frame — verify with Xcode Instruments Frame Debugger
- [ ] **30-second cap (PIPE-03):** Cap fires in testing but only when tested in isolation; under combined load (active diarization + ASR + mic level updates), cap enforcement may be delayed by Task scheduling — verify with real 30+ min meeting recording
- [ ] **Atomic ASR attribution (PIPE-04):** Each buffer produces exactly one ASR segment in unit tests, but overlapping diarization windows can produce two segments from one buffer when a speaker change occurs mid-buffer — verify segment count matches buffer count in integration test
- [ ] **Speaker ID stability (SPKR-01):** `speakerLabelMap` grows to exactly N entries for an N-speaker meeting — verify by asserting map size after a full recording with known speakers
- [ ] **clusteringThreshold=0.3 (SPKR-02):** Threshold chosen from observation; verify on at least 3 different speaker pairs (male/female, different accents, different audio quality) before shipping as default
- [ ] **Stable labels across chunks (SPKR-03):** Labels do not flip during a 10-minute meeting — verify by recording a known 2-person conversation and checking that neither speaker's label changes mid-session
- [ ] **Waveform color per speaker (RT-01):** Color changes are visible in real-time — verify that the `@Published activeSpeakers` update happens within 200 ms of actual speaker change (diarization latency budget)

---

## Recovery Strategies

When pitfalls occur despite prevention, how to recover.

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Audio thread blocked by diarization | HIGH | Move diarization to polling Task; requires rearchitecting the tap closure — cannot be hot-patched |
| Actor reentrancy corrupting speakerLabelMap | MEDIUM | Introduce `SpeakerIdentityActor`; requires extracting labelMap from `MeetingRecorder` — existing sessions produce bad data until fix ships |
| Memory exhaustion from unbounded buffers | LOW-MEDIUM | Add cap check to buffer-append path in the actor; no API change needed; one-file change |
| Out-of-order segments in transcript | LOW | `MeetingNote.addSegment()` already sorts by `startTime`; fix is ensuring all callers use it; post-hoc re-sort of stored meetings is possible |
| Speaker ID drift / wrong labels | MEDIUM | Clear `speakerLabelMap` and reset `nextSpeakerNumber` will not fix already-stored segments; would need a post-processing re-labeling pass over stored `MeetingNote` — expensive |
| SwiftUI updates from wrong context | LOW | Add `MainActor.run {}` wrappers; caught at compile time with strict concurrency enabled |
| CMSampleBuffer format mismatch | MEDIUM | Add format assertion early; if hit in production, must add Int16→Float conversion branch |

---

## Pitfall-to-Phase Mapping

How roadmap phases should address these pitfalls.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Audio thread blocked by diarization | Phase 1 — PIPE-01/02 design | Instruments Time Profiler: audio thread CPU < 5% during diarization |
| Actor reentrancy on speakerLabelMap | Phase 1 — SPKR-01 | Thread Sanitizer clean run + `speakerLabelMap.count == N` assertion for N-speaker meeting |
| Unbounded buffer memory growth | Phase 1 — PIPE-03 | Memory Graph: no `[Float]` array > 2 MB after 30 s cap fires |
| Out-of-order ASR segment completion | Phase 1 — PIPE-04 | Segment `startTime` values are monotonically increasing in stored meeting |
| Speaker ID drift across diarization calls | Phase 1 — SPKR-01/02/03 | 10-min 2-speaker test recording produces exactly 2 unique labels |
| SwiftUI threading violations | Phase 1 — RT-01 (precondition: SWIFT_STRICT_CONCURRENCY=complete) | Zero purple Xcode thread warnings during any recording session |
| Waveform color flicker | Phase 3 — RT-01/RT-02/RT-03 | Color transition fires once per speaker change, not on every diarization poll |
| Chat bubble grouping threshold | Phase 4 — CHAT-01/02/03 | Constant defined in model layer, not view layer; configurable |

---

## Sources

- Codebase analysis: `Sources/DualChannelAudioCapture.swift` — audio tap callback structure, AudioBufferActor, SCStreamOutput delegate
- Codebase analysis: `Sources/MeetingRecorder.swift` — TranscriptionQueue actor, resolveSpeaker(), speakerLabelMap, @MainActor isolation
- Codebase analysis: `Sources/MeetingSession.swift` — handleNewSegment(), liveTranscript sort, Task.detached summary generation
- Codebase analysis: `Sources/MeetingModels.swift` — MeetingNote.addSegment() sorted insert, Speaker.colorIndex
- Codebase analysis: `Sources/MeetingWaveformView.swift` — activeSpeakers display path, timer-driven update model
- Swift concurrency documentation: actor reentrancy at suspension points (official Swift Evolution SE-0306)
- AVAudioEngine documentation: installTap callback thread requirements (real-time constraint)
- FluidAudio project comments in `resolveSpeaker()`: explicit acknowledgment of cross-call speakerId instability

---

*Pitfalls research for: WhisperClip v1.1 Speaker Diarization pipeline rewrite*
*Researched: 2026-03-22*
