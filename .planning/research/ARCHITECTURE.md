# Architecture Research

**Domain:** Real-time diarization-driven audio pipeline — macOS SwiftUI/AppKit app
**Researched:** 2026-03-22
**Confidence:** HIGH — derived entirely from direct source reading, no inference

---

## Current Architecture (v1.0 / v1.1 start state)

### System Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                         View Layer                               │
│  MeetingNotesView  ──  MeetingWaveformView  ──  MeetingDetailView│
│        │                       │                      │          │
│  (observes MeetingSession) (observes MeetingRecorder) │          │
│                                              TranscriptContent   │
│                                         (ForEach segments list)  │
└──────────────────────┬───────────────────────────────────────────┘
                       │ @Published
┌──────────────────────▼───────────────────────────────────────────┐
│                    Manager Layer                                  │
│                                                                  │
│  MeetingSession.shared ──────────────────────────────────────┐   │
│    @Published liveTranscript: [MeetingSegment]               │   │
│    onTranscript callback → handleNewSegment()                │   │
│                                                              │   │
│  MeetingRecorder.shared (@MainActor)                         │   │
│    processAudioChunk()                                       │   │
│      → resolveSpeaker() → DiarizerManager.performComplete    │   │
│      → asrManager.transcribe(tempURL)                        │   │
│      → transcriptCallback(segment)                           │   │
│                                                              │   │
│  TranscriptionQueue (private Actor)                          │   │
│    serializes CoreML: enqueue → drain                        │   │
└───────────────────────────────┬──────────────────────────────┘   │
                                │ audio chunks (5s timer)           │
┌───────────────────────────────▼──────────────────────────────────┐
│                    Service Layer                                  │
│                                                                  │
│  DualChannelAudioCapture (@MainActor)                            │
│    chunkTimer (5.0s) → processChunks()                           │
│    AudioBufferActor { micBuffer, systemBuffer }                  │
│    AVAudioEngine tap → appendMicSamples                          │
│    SCStream callback → appendSystemSamples                       │
│                                                                  │
│  DiarizerManager (FluidAudio)                                    │
│    performCompleteDiarization([Float], sampleRate, atTime)       │
│    → DiarizationResult { segments: [TimedSpeakerSegment] }       │
│    TimedSpeakerSegment { speakerId, startTimeSeconds,            │
│                          endTimeSeconds, durationSeconds }        │
│                                                                  │
│  AsrManager (FluidAudio / LocalParakeet)                         │
│    transcribe(URL) → TranscriptionResult { text }                │
└──────────────────────────────────────────────────────────────────┘
```

### Current Data Flow (what changes in v1.1)

```
SCStream callback
  → AudioBufferActor.appendSystemSamples()
      [5s wall-clock timer fires]
  → DualChannelAudioCapture.processChunks()
  → audioCallback(.system, [Float], startTime)
  → TranscriptionQueue.enqueue()
  → MeetingRecorder.processAudioChunk()
  → resolveSpeaker():
      DiarizerManager.performCompleteDiarization(chunk)
      pick dominant speaker by total duration
      map speakerId → "Speaker N" label
  → AsrManager.transcribe(WAV temp file)
  → MeetingSegment(speaker, text, startTime, endTime)
  → transcriptCallback → MeetingSession.handleNewSegment()
  → MeetingStorage.addSegment()
  → liveTranscript.append() → SwiftUI re-render
```

**Core problem with current flow:** One fixed 5s chunk contains multiple speakers.
`resolveSpeaker` picks the dominant speaker for the *whole chunk* — minority speaker
speech is mis-attributed. The fix is to split at speaker boundaries before ASR.

---

## Target Architecture (v1.1)

### Design Principle

Diarize continuously on the system audio stream; when a speaker boundary is detected,
close the current speaker's buffer and dispatch ASR as an atomic task. Each buffer
maps to exactly one speaker, so ASR output has 100% correct attribution.

### New System Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                         View Layer                               │
│                                                                  │
│  MeetingNotesView                                                │
│    activeMeetingView                                             │
│      MeetingWaveformView(recorder:)                              │
│        ← recorder.activeSpeakerColor  [RT-01, RT-02, RT-03]     │
│      LiveSegmentRow (ForEach liveTranscript)                     │
│                                                                  │
│  MeetingDetailView                                               │
│    transcriptContent                                             │
│      ChatBubbleGroup (NEW)  [CHAT-01..04]                        │
│        consecutive same-speaker segments → one bubble group      │
│        "Me" aligned right, others left                           │
└───────────────┬──────────────────────────────────────────────────┘
                │ @Published
┌───────────────▼──────────────────────────────────────────────────┐
│                    Manager Layer                                  │
│                                                                  │
│  MeetingSession.shared (unchanged public API)                    │
│    liveTranscript: [MeetingSegment]                              │
│    onTranscript callback → handleNewSegment()                    │
│                                                                  │
│  MeetingRecorder.shared (@MainActor)  [MODIFIED]                 │
│    @Published activeSpeakerColor: Color  (new — RT-01)           │
│    speakerLabelMap: [String:String]  (kept, moved to here)       │
│    startRecording() → creates SpeakerBufferManager              │
│    stopRecording() → flushAllBuffers() → drain                   │
│                                                                  │
│  SpeakerBufferManager (NEW Actor)                                │
│    perSpeakerBuffers: [String: SpeakerBuffer]                    │
│    currentSpeakerId: String?                                      │
│    onSpeakerChange(newId, samples, chunkTime)                    │
│      → closeBuffer(oldId) → dispatch ASR Task                    │
│      → openBuffer(newId)                                         │
│    onCapTimeout()  (30s cap — PIPE-03)                           │
│      → closeBuffer(current) → dispatch ASR → reopenBuffer        │
│    flushAll() → closeBuffer for every open buffer                │
│                                                                  │
│  TranscriptionQueue (private Actor)  [kept, no changes]          │
└───────────────┬──────────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────────┐
│                    Service Layer                                  │
│                                                                  │
│  DualChannelAudioCapture (@MainActor)  [MODIFIED]                │
│    Remove: chunkTimer (5s wall-clock batching)                   │
│    Keep: AVAudioEngine mic tap → AudioBufferActor.appendMic      │
│    Keep: SCStream callback → AudioBufferActor.appendSystem       │
│    Add: streamingCallback: (AudioSource,[Float],TimeInterval)→() │
│         fires on every SCStream buffer (continuous, not chunked) │
│         fires on every mic AVAudioEngine tap callback            │
│    Mic path stays chunked (simple: accumulate → 2s min → flush)  │
│    System path: raw samples forwarded to SpeakerBufferManager   │
│                                                                  │
│  DiarizerManager (FluidAudio)  [API unchanged]                   │
│    performCompleteDiarization([Float], sampleRate, atTime)       │
│    → DiarizationResult.segments: [TimedSpeakerSegment]           │
│    Called by SpeakerBufferManager on small rolling windows       │
│    (not once per 5s chunk — on every incoming audio batch)       │
│                                                                  │
│  AsrManager (FluidAudio / LocalParakeet)  [API unchanged]        │
│    transcribe(URL) → TranscriptionResult { text }                │
│    Called per closed speaker buffer, not per fixed interval      │
└──────────────────────────────────────────────────────────────────┘
```

---

## Component Integration Map

### What Changes, What Stays, What Is New

| Component | Status | Change Description |
|-----------|--------|--------------------|
| `DualChannelAudioCapture` | MODIFIED | Remove 5s chunkTimer; add continuous streaming callback for system audio path |
| `AudioBufferActor` | MODIFIED or REPLACED | Mic side stays; system side replaced by SpeakerBufferManager's per-speaker buffers |
| `MeetingRecorder` | MODIFIED | Remove `processAudioChunk` fixed-chunk flow; drive new buffer/dispatch logic; add `activeSpeakerColor: @Published Color` |
| `resolveSpeaker()` | REPLACED | Logic moves into `SpeakerBufferManager.onSpeakerChange()` |
| `TranscriptionQueue` | KEPT | Still serializes CoreML calls — more important than ever with concurrent per-speaker Tasks |
| `MeetingSession` | KEPT UNCHANGED | onTranscript callback API is identical; still calls handleNewSegment() |
| `MeetingStorage` | KEPT UNCHANGED | addSegment() API unchanged |
| `Speaker` enum | KEPT UNCHANGED | .labeled("Speaker N") already exists; colorIndex already defined |
| `speakerPaletteColor()` | KEPT UNCHANGED | Already in SharedViews.swift; waveform view will reuse it |
| `MeetingWaveformView` | MODIFIED | barGradient() uses `recorder.activeSpeakerColor` instead of fixed level thresholds |
| `MeetingDetailView.transcriptContent` | MODIFIED | Replace `ForEach(segments) { TranscriptSegmentRow }` with grouped bubble layout |
| `SpeakerBufferManager` | NEW | Swift Actor; owns per-speaker ring buffers, speaker-change detection, 30s cap timer |
| `ChatBubbleGroup` (view) | NEW | SwiftUI view for iMessage-style bubble grouping |

---

## SpeakerBufferManager — Detailed Design

This is the central new component. Everything else is a modification of existing code.

### Responsibilities

1. Receive raw system audio samples continuously from DualChannelAudioCapture
2. Run `DiarizerManager.performCompleteDiarization()` on each incoming batch to detect speaker changes
3. Accumulate audio in a per-speaker buffer keyed by speakerId
4. On speaker change: close current buffer, dispatch `Task { await transcribe(closedBuffer) }`, open new buffer for new speaker
5. On 30s cap: same close/dispatch/reopen flow for the active speaker
6. Map raw speakerIds to stable "Speaker N" labels (this logic currently lives in `MeetingRecorder.resolveSpeaker()` and moves here)
7. Publish `currentSpeakerId` and `currentSpeakerLabel` so MeetingRecorder can update `activeSpeakerColor`

### State Machine

```
State: idle
  → onStart() → State: buffering(currentSpeakerId: X)

State: buffering(currentSpeakerId: X)
  → onAudioBatch(samples):
      run diarizer on batch
      if dominant speaker == X:
          append to buffer[X]
          if buffer[X].duration >= 30s → cap trigger → State: flushing(X) → State: buffering(X, new open)
      if dominant speaker != X (change detected):
          → State: flushing(X) → State: buffering(newSpeaker)

State: flushing(speakerId: X)
  → closeBuffer(X) → copy samples
  → Task { await dispatchASR(samples, speaker, startTime) }
  → (async, non-blocking from buffer manager's perspective)
```

### Speaker Change Detection Strategy

DiarizerManager is called on each incoming audio batch (100-500ms of audio from SCStream
callbacks, approximately 1600-8000 samples at 16kHz). The diarizer is stateful — using the
same `DiarizerManager` instance across calls preserves speaker embeddings, so speakerIds
will be consistent. The dominant speaker in each small window is compared to `currentSpeakerId`.

A speaker change is confirmed when:
- The new dominant speaker differs from `currentSpeakerId`
- The new speaker has been dominant for at least N consecutive batches (configurable hysteresis,
  suggested 2-3 batches = 300-750ms, to avoid thrashing on cross-talk)

### Buffer Structure

```swift
struct SpeakerBuffer {
    let speakerId: String
    let speakerLabel: String   // "Speaker 1", "Speaker 2", ...
    let sessionStartTime: TimeInterval  // absolute offset from recording start
    var samples: [Float]
    var openedAt: TimeInterval  // for 30s cap calculation
}
```

### ASR Dispatch Contract

When a buffer closes, the dispatcher does:
1. Write buffer.samples to a temp WAV file (same `writeWAVFile()` helper as current MeetingRecorder)
2. Call `transcriptionQueue.enqueue(source: .system, samples:, startTime:, processor:)`
3. Inside processor: `asrManager.transcribe(tempURL)` → text
4. Build `MeetingSegment(speaker: .labeled(buffer.speakerLabel), text:, startTime: buffer.sessionStartTime, endTime:)`
5. Call `transcriptCallback(segment)` on MainActor

This is identical to the current processAudioChunk flow except:
- Speaker is determined *before* ASR (buffer is already mono-speaker by construction)
- No post-hoc deduplication is needed (buffer is atomic: one speaker, one utterance)

---

## Microphone Path (unchanged)

Mic audio is always `.me`. No diarization needed. The current flow:

```
AVAudioEngine tap → AudioBufferActor.appendMicSamples
  → (kept) 5s chunk timer OR 2s min sample guard
  → processAudioChunk(source: .microphone, ...)
  → transcribe → MeetingSegment(speaker: .me, ...)
```

This path does NOT go through SpeakerBufferManager. It remains a separate, simpler path
in MeetingRecorder exactly as today. No changes required for PIPE-05.

---

## UI Integration Points

### RT-01/02/03: Waveform Speaker Color

**Current:** `MeetingWaveformView.barGradient()` picks colors based on audio level thresholds
(teal → orange → red by dB). Speaker-agnostic.

**Target:** Color reflects the active speaker using the same `speakerPaletteColor()` already
in `SharedViews.swift`.

**Change in MeetingRecorder:**
```swift
@Published private(set) var activeSpeakerColor: Color = .gray
```
Updated by SpeakerBufferManager whenever `currentSpeakerId` changes, via a callback or
Combine publisher. Since MeetingRecorder is `@MainActor`, a simple closure from
SpeakerBufferManager to `Task { @MainActor in recorder.updateActiveSpeaker(newLabel) }`
is sufficient.

**Change in MeetingWaveformView:**
Replace fixed level-based gradient with `speakerPaletteColor(recorder.activeSpeaker)`.
The transition happens at the moment of detection (RT-03 is automatic — no extra work).

### CHAT-01/02/03/04: Chat Bubble Grouping

**Current:** `MeetingDetailView.transcriptContent` renders:
```swift
ForEach(currentMeeting.segments) { segment in
    TranscriptSegmentRow(segment: segment)
}
```

**Target:** Group consecutive segments from the same speaker into a `ChatBubbleGroup`.

**Grouping logic (pure Swift, no new state):**
```swift
// Computed property on MeetingNote or local to the view
func chatGroups(from segments: [MeetingSegment]) -> [SpeakerGroup] {
    // Reduce: if segment.speaker == last group's speaker, append; else start new group
}

struct SpeakerGroup: Identifiable {
    let id: UUID
    let speaker: Speaker
    let segments: [MeetingSegment]
    var startTime: TimeInterval { segments.first?.startTime ?? 0 }
    var endTime: TimeInterval { segments.last?.endTime ?? 0 }
}
```

**ChatBubbleGroup view layout:**
- Speaker name + avatar badge: once at top of group
- Each segment's text: in a rounded bubble
- Timestamp: only at bottom of group (CHAT-03)
- `.me` speaker: `HStack { Spacer(); bubble }` (right-aligned — CHAT-04)
- Other speakers: `HStack { bubble; Spacer() }` (left-aligned — CHAT-04)

**Existing `speakerPaletteColor()` in SharedViews.swift is reused directly.**
No new color infrastructure needed.

---

## Data Flow: Target Pipeline

### System Audio (diarization-driven)

```
SCStream callback (nonisolated, ~100ms intervals)
  → appendSystemSamples(batch, elapsed)
      ↓
SpeakerBufferManager.onAudioBatch(batch, atTime)
  → DiarizerManager.performCompleteDiarization(batch, sampleRate, atTime)
  → if speaker changed (with hysteresis):
      closeBuffer(prevSpeaker) → [Float] snapshot
      Task { await TranscriptionQueue.enqueue(...) }
        → writeWAVFile(samples)
        → AsrManager.transcribe(url)
        → MeetingSegment(speaker: .labeled(label), ...)
        → Task { @MainActor in transcriptCallback(segment) }
      openBuffer(newSpeaker)
      Task { @MainActor in recorder.updateActiveSpeaker(newLabel) }
  → if 30s cap:
      closeBuffer(currentSpeaker) → same ASR dispatch
      reopenBuffer(currentSpeaker, newStart)
  → else: append batch to currentBuffer
```

### Mic Audio (simple, unchanged)

```
AVAudioEngine tap (nonisolated)
  → AudioBufferActor.appendMicSamples(batch, elapsed)
      [2s minimum or stop flush]
  → MeetingRecorder.processAudioChunk(source: .microphone, ...)
  → AsrManager.transcribe()
  → MeetingSegment(speaker: .me, ...)
  → transcriptCallback(segment)
```

### Segment → UI

```
transcriptCallback(segment)           [on MainActor]
  → MeetingSession.handleNewSegment()
      → liveTranscript.append(segment)   [triggers MeetingNotesView re-render]
      → MeetingStorage.addSegment()      [triggers MeetingDetailView re-render]
```

---

## Build Order (dependency-first)

Build phases should follow this dependency chain to maintain compile-and-record at every step:

**Phase 1 — SpeakerBufferManager (pure actor, no UI, no DualCapture changes)**
- Implement SpeakerBufferManager actor with in-memory buffer accumulation and speaker-change detection
- Wire to a test stub; no integration yet
- Deliverable: unit-testable actor, compiles, no regressions

**Phase 2 — DualChannelAudioCapture streaming callback**
- Add a continuous streaming path for system audio (alongside or replacing the 5s timer)
- Mic path untouched
- SpeakerBufferManager receives raw batches
- Deliverable: audio flows into SpeakerBufferManager during recording

**Phase 3 — MeetingRecorder pipeline rewire (PIPE-01..05)**
- Remove processAudioChunk fixed-chunk flow for system audio
- SpeakerBufferManager closes buffers and dispatches ASR via TranscriptionQueue
- Mic path unchanged
- Add activeSpeakerColor @Published property
- Deliverable: recording works end-to-end with diarization-driven splits; existing meeting storage untouched

**Phase 4 — Waveform color (RT-01..03)**
- MeetingWaveformView reads recorder.activeSpeakerColor
- No pipeline changes
- Deliverable: waveform bar color changes on speaker transitions during recording

**Phase 5 — Chat bubble UI (CHAT-01..04)**
- Add chatGroups() grouping logic
- Add ChatBubbleGroup SwiftUI view
- Replace TranscriptSegmentRow ForEach in MeetingDetailView.transcriptContent
- Deliverable: iMessage-style transcript in detail view

---

## Architectural Patterns

### Pattern 1: Actor-gated Buffer Accumulation

**What:** Swift Actor owns all mutable buffer state. Audio callbacks (from nonisolated SCStream
and AVAudioEngine delegates) route through `Task { await actor.append() }`.
**When to use:** Any state shared between the audio capture thread and the main actor.
**Trade-offs:** Small async overhead per callback; eliminates all data races without locks.

The existing `AudioBufferActor` in DualChannelAudioCapture already uses this pattern.
`SpeakerBufferManager` extends the same pattern with multiple named buffers.

### Pattern 2: Atomic Buffer → ASR Task

**What:** When a buffer closes (speaker change or cap), copy its samples and launch
`Task { await transcriptionQueue.enqueue(...) }`. The buffer is immediately cleared and
reopened; transcription runs concurrently with new audio accumulation.
**When to use:** Any pipeline where processing time (ASR ~1-3s) must not block audio capture.
**Trade-offs:** Segments arrive out of strict wall-clock order if ASR tasks complete in different
order. Mitigation: `MeetingNote.addSegment()` already inserts by `startTime`, not append order.

### Pattern 3: Publisher Chain for Active Speaker Color

**What:** SpeakerBufferManager publishes current speaker change via a simple callback closure
(not Combine — avoids retain cycles across actor boundaries). MeetingRecorder stores the result
as `@Published activeSpeakerColor: Color`. MeetingWaveformView observes via `@ObservedObject recorder`.
**When to use:** Crossing the actor → MainActor boundary for UI state.
**Trade-offs:** Simpler than Combine PassthroughSubject across actor boundaries; sufficient for
one property.

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Running Diarization on 5s Accumulated Chunks

**What people do:** Keep the existing 5s timer and run diarization post-hoc to split segments.
**Why it's wrong:** You still get one ASR transcription covering multiple speakers. Splitting
transcription results after the fact is unreliable (word boundaries don't align with speaker
boundaries).
**Do this instead:** Accumulate per-speaker buffers and dispatch ASR only when a buffer closes
with a known single speaker.

### Anti-Pattern 2: One Global System Audio Buffer

**What people do:** Keep `AudioBufferActor.systemBuffer` as a single flat array and split at
dispatch time.
**Why it's wrong:** The split point is a speaker boundary — you need to know when the speaker
changed, which requires tracking it *during* accumulation.
**Do this instead:** SpeakerBufferManager maintains `[speakerId: SpeakerBuffer]` — each buffer
is opened when its speaker starts talking and closed when they stop.

### Anti-Pattern 3: Calling Diarize + ASR Serially per Batch

**What people do:** For each incoming 100ms audio batch: diarize, then if speaker changed, ASR.
**Why it's wrong:** ASR takes 1-3 seconds. Serial processing means audio buffers grow unbounded
during ASR runs.
**Do this instead:** Diarization happens synchronously in SpeakerBufferManager (it's fast —
embedding extraction only). ASR is dispatched as a concurrent Task through TranscriptionQueue
(which already exists for this purpose). Accumulation continues unblocked.

### Anti-Pattern 4: Removing TranscriptionQueue

**What people do:** Since segments are now atomic (one speaker), assume concurrent ASR is safe.
**Why it's wrong:** CoreML models are NOT thread-safe. Concurrent predictions from multiple
closed buffers arriving close together will crash.
**Do this instead:** Keep TranscriptionQueue. All closed-buffer ASR Tasks go through it. The
queue serializes them. This was the original reason for building TranscriptionQueue.

### Anti-Pattern 5: Speaker Change Detection Without Hysteresis

**What people do:** Switch speaker on the first diarizer batch that shows a different speaker.
**Why it's wrong:** During cross-talk or brief hesitations, the diarizer may briefly attribute
a few frames to the wrong speaker before correcting. This creates spurious micro-segments.
**Do this instead:** Require N consecutive batches (2-3, ~300-750ms) showing the new speaker
before committing to a speaker change. Only then close the old buffer and open the new one.

---

## Integration Points

### FluidAudio API Constraints (HIGH confidence — read directly from source)

| API | Signature | Notes |
|-----|-----------|-------|
| `DiarizerManager.performCompleteDiarization` | `(_ samples: [Float], sampleRate: Int, atTime: TimeInterval) throws -> DiarizationResult` | Synchronous/throws; call on background; stateful — same instance preserves embeddings across calls |
| `DiarizationResult.segments` | `[TimedSpeakerSegment]` | Each segment has `.speakerId` (String), `.startTimeSeconds`, `.endTimeSeconds`, `.durationSeconds` |
| `DiarizerConfig.clusteringThreshold` | `0.3` (set in current code) | Lower = more speaker splits; 0.7 default collapses multi-speaker into one |
| `AsrManager.transcribe` | `(_ url: URL) async throws -> TranscriptionResult` | Requires WAV file on disk; result has `.text` |
| `AsrManager.isAvailable` | `Bool` | Check before use |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| DualChannelAudioCapture → SpeakerBufferManager | Closure callback per batch (system audio only) | Must be nonisolated-safe → use `Task { await manager.onAudioBatch() }` |
| SpeakerBufferManager → MeetingRecorder | Closure callback on speaker change + segment ready | `Task { @MainActor in recorder.updateActiveSpeaker() }` |
| SpeakerBufferManager → TranscriptionQueue | Direct actor call inside Task | `await transcriptionQueue.enqueue(...)` |
| MeetingRecorder → MeetingSession | `transcriptCallback` closure (unchanged) | Already MainActor-isolated |
| MeetingRecorder → MeetingWaveformView | `@Published activeSpeakerColor` (new) | @ObservedObject already in place |

---

## Sources

- Direct source reading: `MeetingRecorder.swift`, `DualChannelAudioCapture.swift`,
  `MeetingModels.swift`, `MeetingSession.swift`, `MeetingDetailView.swift`,
  `MeetingWaveformView.swift`, `MeetingNotesView.swift`, `SharedViews.swift`,
  `LocalParakeet.swift`, `RecordingCoordinator.swift` — all in `Sources/`
- Codebase architecture doc: `.planning/codebase/ARCHITECTURE.md`
- Project requirements: `.planning/PROJECT.md`

---

*Architecture research for: WhisperClip v1.1 Speaker Diarization pipeline rewrite*
*Researched: 2026-03-22*
