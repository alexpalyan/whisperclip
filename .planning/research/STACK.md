# Stack Research

**Domain:** Streaming per-speaker audio buffer management, concurrent ASR dispatch, real-time speaker color updates — WhisperClip v1.1
**Researched:** 2026-03-22
**Confidence:** HIGH (all findings verified against FluidAudio source, existing codebase, and Apple platform knowledge)

---

## Context: What Already Exists (Do Not Re-research)

| Component | Version | Status |
|-----------|---------|--------|
| Swift | 5.10 | Locked by Package.swift |
| SwiftUI + AppKit | macOS 14+ | Production |
| FluidAudio | >=0.10.0 | Integrated |
| DiarizerManager | FluidAudio internal | Wired into MeetingRecorder |
| DualChannelAudioCapture | Custom | Working — mic + system audio |
| TranscriptionQueue (actor) | Custom | Serializes CoreML |
| AudioBufferActor | Custom | Per-channel [Float] accumulation |
| KeyboardShortcuts | 2.4.0 | Production |
| speakerPaletteColor() | Custom | Shared palette — 9 colors |

This research covers **only what must change or be added** for the v1.1 pipeline rewrite.

---

## Recommended Stack Additions

### Core: Per-Speaker Buffer Accumulation

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `AudioBufferActor` (extended) | Custom | Replace per-channel buffer with per-speakerId dict | Already proven actor pattern in DualChannelAudioCapture — extend `[String: SpeakerBuffer]` keyed on speakerId instead of single mic/system arrays |
| `[Float]` (plain array) | Swift stdlib | Accumulate samples for one speaker turn | Existing pipeline passes `[Float]` throughout; AVAudioPCMBuffer would require frame-capacity pre-allocation which is unnecessary for variable-length turns |
| `ContiguousArray<Float>` | Swift stdlib | Pass speaker buffer to `performCompleteDiarization` | FluidAudio `DiarizerManager.performCompleteDiarization` accepts any `RandomAccessCollection<Float>` — ArraySlice or ContiguousArray enable zero-copy slicing without extra allocation |

**Pattern:** Do NOT use `AVAudioPCMBuffer` as the accumulation container. `AVAudioPCMBuffer` requires pre-declared `frameCapacity` and does not grow dynamically. The existing pipeline already converts to `[Float]` for FluidAudio and to `AVAudioPCMBuffer` only when writing temp WAV files before ASR — keep that boundary.

**Buffer concatenation (HIGH confidence — from DualChannelAudioCapture.AudioBufferActor):**
```swift
// Append pattern already used in codebase:
micBuffer.append(contentsOf: samples)  // O(n) amortized
```
For per-speaker buffers, the same pattern applies. No third-party library needed.

---

### Core: Speaker-Change Detection Trigger

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `DiarizerManager.performCompleteDiarization` | FluidAudio >=0.10.0 | Detect dominant speaker in current window | Already called per-chunk in `resolveSpeaker()`. The new pipeline calls it on a sliding window (e.g., last 2–3s) to detect transitions, not on the full accumulated buffer |
| `TimedSpeakerSegment.speakerId` | FluidAudio >=0.10.0 | Compare current dominant speakerId to previous | `speakerId` is a stable `String` ("1", "2", ...) from `SpeakerManager` across calls on the same `DiarizerManager` instance. This is the change-detection signal |
| `SpeakerManager` (via `diarizerManager.speakerManager`) | FluidAudio >=0.10.0 | Cross-chunk speaker identity continuity | `SpeakerManager` is the source of stable IDs — it persists within a `DiarizerManager` instance. No reset between chunks |

**Key finding from FluidAudio source:** `SpeakerManager.assignSpeaker(_:speechDuration:confidence:)` returns a `Speaker` with `.id` as a numeric string starting from "1". These IDs are stable across `performCompleteDiarization` calls on the same `DiarizerManager` instance because `SpeakerManager` is held as a stored property of `DiarizerManager`.

**Pattern:**
```swift
// Run diarization on most-recent N seconds (sliding detection window)
let detectionWindow = systemBuffer.suffix(sampleRate * 3)  // last 3s
let result = try diarizer.performCompleteDiarization(detectionWindow, atTime: windowStartTime)
let dominant = result.segments.max(by: { $0.durationSeconds < $1.durationSeconds })?.speakerId
if dominant != currentSpeakerId {
    // Speaker change detected — flush current buffer, dispatch ASR
}
```

---

### Core: 30s Max-Duration Cap (Fallback Trigger)

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `DispatchSourceTimer` or `Task.sleep` loop inside actor | Swift stdlib / Dispatch | Fire max-duration cap | `DispatchSourceTimer` is the correct choice for a real-time audio callback context because it fires on a background queue without blocking the audio thread. A `Task` with `Task.sleep` inside the `SpeakerBufferActor` is equally valid given existing actor patterns |

**Why not Timer.scheduledTimer:** The main run loop timer pattern used for `chunkTimer` in `DualChannelAudioCapture` requires `@MainActor` dispatch. A per-speaker cap is more naturally owned by the actor that holds the buffer, avoiding a round-trip to main actor.

**Pattern:**
```swift
// Inside SpeakerBufferActor — track accumulation start
var bufferStartTime: TimeInterval = 0
var sampleCount: Int = 0
let maxDurationSamples: Int = sampleRate * 30  // 30s cap

func append(_ samples: [Float], atTime time: TimeInterval) {
    if sampleCount == 0 { bufferStartTime = time }
    buffer.append(contentsOf: samples)
    sampleCount += samples.count
}

func needsFlush() -> Bool {
    return sampleCount >= maxDurationSamples
}
```

---

### Core: Async ASR Dispatch from Audio Callback Thread

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `Task { }` (unstructured) | Swift 5.5+ concurrency | Dispatch ASR job from `nonisolated` audio callback | The `SCStreamOutput` and `AVAudioEngine` tap callbacks are `nonisolated` — they cannot `await` directly. `Task { }` creates an unstructured task from a synchronous context, correctly bridging to Swift concurrency |
| `TranscriptionQueue` (existing actor) | Custom | Serialize CoreML predictions | Already prevents concurrent CoreML predictions. The new pipeline dispatches one `Task { await transcriptionQueue.enqueue(...) }` per completed speaker buffer — same pattern as current `processChunks()` |
| `actor SpeakerBufferActor` | Swift 5.5+ concurrency | Isolate per-speaker buffer state | Replaces current `AudioBufferActor` with speaker-keyed storage. Actor isolation is the correct pattern — no `@unchecked Sendable`, no locks. FluidAudio itself uses the same pattern (`AudioBuffer` is an `actor`) |

**Critical pattern — audio callback to actor:**
```swift
// In nonisolated SCStreamOutput callback (existing pattern in DualChannelAudioCapture):
Task {
    // 1. Append to speaker buffer (actor-isolated)
    let speakerId = await speakerBufferActor.detectAndAppend(samples, atTime: elapsed)
    // 2. If speaker changed or cap hit, actor returns the completed buffer
    if let completedBuffer = await speakerBufferActor.flush(for: previousSpeakerId) {
        // 3. Dispatch ASR (goes through existing TranscriptionQueue)
        await transcriptionQueue.enqueue(source: .system, samples: completedBuffer, ...)
    }
}
```

**Why not `Task.detached`:** `Task.detached` does not inherit actor context. Since the enqueue call needs `@MainActor` for `processAudioChunk`, inheriting the current task's context (which is already correct) is simpler. The existing code uses `Task { }` for this reason.

---

### Core: Real-Time Waveform Color Per Active Speaker

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `@Published var activeSpeaker: Speaker` on `MeetingRecorder` | Swift/Combine | Broadcast current speaker to `MeetingWaveformView` | `MeetingRecorder` is already `@MainActor ObservableObject`. Adding a single `@Published var activeSpeaker` property costs nothing and integrates with existing `@ObservedObject var recorder: MeetingRecorder` in `MeetingWaveformView` |
| `speakerPaletteColor()` (existing) | Custom/SharedViews.swift | Map `Speaker` → `Color` for waveform bars | Already used in `SpeakerBadge`, `TranscriptSegmentRow`, `MeetingNotesView`. Same function wired into `MeetingWaveformView.barGradient(for:)` replaces the hardcoded level-based gradient |
| `withAnimation(.easeInOut(duration: 0.15))` | SwiftUI | Smooth color transition at speaker change | SwiftUI animates `Color` changes on `Canvas` fills when driven by `@State` update within `withAnimation`. The 0.1s timer in `MeetingWaveformView` already drives updates — wrap the speaker color assignment in `withAnimation` |

**Integration point — `MeetingWaveformView.barGradient(for:)`:**
```swift
// Replace current level-based color logic:
private func barGradient(for index: Int) -> LinearGradient {
    // Was: if level > 0.7 { red } elif level > 0.4 { orange } else { teal }
    // Now:
    let color = speakerPaletteColor(recorder.activeSpeaker)
    return LinearGradient(colors: [color.opacity(0.7), color], startPoint: .bottom, endPoint: .top)
}
```

**Why not `@State var speakerColor: Color` in the view:** The speaker identity lives in `MeetingRecorder` (it's the authoritative source). Deriving color in the view from `recorder.activeSpeaker` — which is already `@Published` — avoids a second source of truth and works within the existing 0.1s polling timer.

---

### Core: iMessage-Style Chat Bubble Grouping

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Computed `[[MeetingSegment]]` grouping | Swift stdlib | Group consecutive same-speaker segments | No library needed. A simple `reduce` or loop that collects consecutive segments with the same `speaker` into sub-arrays. Computed in `MeetingDetailView.transcriptContent` or as a `var` on `MeetingNote` |
| `HStack` + `Spacer()` alignment | SwiftUI | iMessage left/right alignment | `.me` segments: `HStack { Spacer(); bubble }`. Others: `HStack { bubble; Spacer() }`. Standard SwiftUI pattern, no geometry math required |
| Existing `speakerPaletteColor()` | SharedViews.swift | Bubble background tint | Same function — `.me` gets `.blue.opacity(0.2)`, others get their palette color |

**Grouping pattern:**
```swift
// Computed property on MeetingNote or in the view:
var segmentGroups: [[MeetingSegment]] {
    segments.sorted { $0.startTime < $1.startTime }.reduce([[MeetingSegment]]()) { groups, segment in
        var groups = groups
        if groups.last?.last?.speaker == segment.speaker {
            groups[groups.count - 1].append(segment)
        } else {
            groups.append([segment])
        }
        return groups
    }
}
```

**Timestamp/avatar display:** Only the first segment in a group shows the speaker name/avatar; only the last shows the timestamp. This is a `ForEach` on groups with index-based conditionals — no additional state or library.

---

## Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `Accelerate` (vDSP) | System | RMS level calculation per speaker for active-speaker detection | Already used by FluidAudio internally. If per-speaker level monitoring is needed beyond `normalizedLevel`, add `vDSP_rmsqv` for the current speaker's most-recent samples |
| `Combine` | System | Drive `@Published activeSpeaker` updates | Already used in AppDelegate for hotkey subscriptions. `MeetingRecorder` is already `ObservableObject` — Combine is the existing propagation mechanism |

**No new SPM dependencies required** for any v1.1 feature.

---

## Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| Instruments (Time Profiler) | Measure actor hop overhead between audio callback and `SpeakerBufferActor` | Actor hops are cheap (~microseconds) but accumulate on high-frequency audio callbacks (every 4096 frames @ 16kHz = every 256ms) |
| Instruments (Allocations) | Verify [Float] append does not fragment heap | `[Float].append(contentsOf:)` doubles capacity when needed — pre-reserve with `reserveCapacity(sampleRate * 35)` to avoid reallocation during a 30s turn |

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Plain `[Float]` accumulation in actor | `AVAudioPCMBuffer` as accumulation container | Never for this use case — `AVAudioPCMBuffer` requires fixed `frameCapacity` at init, cannot grow dynamically, and adds AVFoundation overhead for an intermediate buffer that is immediately flattened to `[Float]` for FluidAudio |
| `Task { }` unstructured from audio callback | `DispatchQueue.async` | Only if migrating away from Swift concurrency entirely — would require removing all `actor` usage in the codebase, which is the wrong direction |
| `@Published var activeSpeaker` on `MeetingRecorder` | Notification.Name / NotificationCenter | Notifications bypass `@Published` reactivity and require manual `objectWillChange` calls. The `@Published` path is simpler and already the project pattern |
| Computed `segmentGroups` property | Storing groups as a separate model property | Groups are derived data — computing from `segments` ensures no synchronization bugs between the two. Groups are O(n) and fast enough to compute on-demand in `transcriptContent` |
| Sliding detection window (last 3s) for speaker change | Running diarization on full accumulated buffer | Full-buffer diarization at every new audio chunk is O(n * chunk_count) — cost grows with session length. A fixed sliding window keeps detection cost constant at ~O(30_000 samples) |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `AVAudioPCMBuffer` as the accumulation type | Fixed frameCapacity — cannot grow with variable-length speaker turns | `[Float]` array with `reserveCapacity` |
| `@unchecked Sendable` | FluidAudio explicitly prohibits it; bypasses correctness guarantees | `actor` isolation or `@MainActor` |
| `Timer.scheduledTimer` for the 30s cap inside an actor | Requires main run loop — creates unnecessary actor hop overhead | `Task { try await Task.sleep(...) }` inside the actor, or a `nonisolated` DispatchSourceTimer |
| Reset `DiarizerManager` between speaker turns | Destroys `SpeakerManager` state — speaker IDs start over, collapsing multi-speaker sessions | Keep one `DiarizerManager` alive for the full recording session; only reset `speakerLabelMap` and `nextSpeakerNumber` if explicitly restarting |
| Hungarian algorithm / retroactive speaker remapping | Incompatible with real-time streaming — produces ID instability between chunks | `SpeakerManager.assignSpeaker()` uses cosine similarity online clustering, which is stable forward-only |

---

## Stack Patterns by Variant

**For system audio (diarization-driven splits):**
- Use `SpeakerBufferActor` with `[String: [Float]]` keyed on `speakerId`
- Detection window = last 3s of system audio buffer (ArraySlice — zero copy into `performCompleteDiarization`)
- Flush trigger = speaker change detected OR `sampleCount >= sampleRate * 30`

**For microphone audio (always "Me", PIPE-05):**
- No diarization — mic always returns `.me`
- Keep existing channel-based accumulation; apply the same 30s cap
- No speaker-change detection needed

**For waveform color during mic-only mode (no system audio permission):**
- `activeSpeaker = .me` for the full session
- Waveform shows persistent `.blue` from `speakerPaletteColor(.me)`

---

## Version Compatibility

| Component | Compatible With | Notes |
|-----------|-----------------|-------|
| `FluidAudio >= 0.10.0` | Swift 5.10, macOS 14.0+ | `AudioBuffer` actor and `TimedSpeakerSegment.speakerId` as stable String confirmed in source |
| `DiarizerManager.performCompleteDiarization` | Any `RandomAccessCollection<Float>` | `ArraySlice`, `ContiguousArray`, `Array` all accepted — no copy needed for detection window |
| `SpeakerManager.assignSpeaker` | Called through `DiarizerManager` internally | Do NOT call `speakerManager.assignSpeaker` directly from `MeetingRecorder` — use `performCompleteDiarization` which routes through the internal pipeline |
| Swift structured concurrency (`actor`, `Task`) | Swift 5.5+, in use via Swift 5.10 | `AudioBufferActor` in `DualChannelAudioCapture` already proves compatibility |

---

## Sources

- FluidAudio source (local checkout): `.build/checkouts/FluidAudio/Sources/FluidAudio/` — DiarizerManager.swift, DiarizerTypes.swift, AudioBuffer.swift — HIGH confidence
- FluidAudio CLAUDE.md (`.build/checkouts/FluidAudio/CLAUDE.md`) — architecture, threading model, `SpeakerManager` behavior — HIGH confidence
- FluidAudio tests: `StreamingAsrManagerTests.swift`, `SpeakerManagerTests.swift` — confirms `AudioBuffer` actor API, `speakerId` as numeric String — HIGH confidence
- WhisperClip codebase: `DualChannelAudioCapture.swift`, `MeetingRecorder.swift`, `MeetingWaveformView.swift`, `SharedViews.swift` — existing patterns verified — HIGH confidence
- Package.swift — exact dependency versions confirmed — HIGH confidence
- Apple platform knowledge: AVAudioEngine tap callback threading, `nonisolated` audio callbacks, `Task {}` from synchronous context — MEDIUM confidence (Apple docs require JS, but behavior is well-established and consistent with existing codebase patterns)

---

*Stack research for: WhisperClip v1.1 Speaker Diarization pipeline rewrite*
*Researched: 2026-03-22*
