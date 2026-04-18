# Phase 11: Live Transcription Stream - Research

**Researched:** 2026-04-18
**Domain:** Real-time ASR (WhisperKit/FluidAudio) & UI Streaming (@Observable)
**Confidence:** HIGH

## Summary

This phase implements live feedback during transcription. Instead of waiting for a 5-30s audio chunk to be fully processed, tokens are streamed to the UI as they are decoded. We will utilize the internal callback mechanisms of WhisperKit and the streaming capabilities of FluidAudio (Parakeet) to achieve this. The `TranscriptionQueue` will continue to serialize CoreML execution to maintain system stability, while the `@Observable` pattern in `MeetingSegment` will handle the high-frequency UI updates efficiently.

**Primary recommendation:** Use WhisperKit's `transcribe` callback and FluidAudio's `StreamingEouAsrManager` to feed partial text to `MeetingSegment.text` in real-time while the segment is in the `isPending` state.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Audio Collection | MeetingRecorder | DualChannelAudioCapture | Raw samples gathered from hardware. |
| Task Scheduling | TranscriptionQueue | — | Ensures CoreML (Neural Engine) isn't overloaded. |
| Live Decoding | VoiceToTextModel | WhisperKit / FluidAudio | Converts audio to tokens with partial feedback. |
| UI State Sync | MeetingSegment (@Observable) | MeetingSession | Live text updates trigger SwiftUI re-renders. |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| WhisperKit | 0.8.0+ | ASR Engine (Whisper) | Best-in-class local ASR for Apple Silicon. |
| FluidAudio | 0.3.0+ | ASR Engine (Parakeet) | High-speed streaming ASR with low latency. |
| Observation | iOS 17+/macOS 14+ | State Management | Efficient property-level tracking for UI updates. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|--------------|
| AVFoundation | — | Audio Processing | WAV writing and sample management. |

**Installation:**
Existing packages in `Package.swift` are sufficient.

## Architecture Patterns

### Token Streaming Workflow
1. **Partitioning:** `MeetingRecorder` slices continuous audio into 5s chunks (System) or awaits Diarizer boundaries (Mic/System).
2. **Enqueuing:** Chunks are sent to `TranscriptionQueue`.
3. **Partial Updates:** `VoiceToTextModel` starts transcription and invokes a callback for every new token/segment.
4. **Reactive Rendering:** The callback updates `MeetingSegment.text` directly. Since it's `@Observable`, the UI updates instantly.

### System Architecture Diagram
```
[Microphone/System Audio] 
      │
[MeetingRecorder] ───> [SpeakerBufferManager] (Diarizer)
      │                       │
      │                  [ClosedBuffer]
      │                       │
      └──────────────> [TranscriptionQueue] (Serial Actor)
                              │
                      [VoiceToTextModel]
                              │
                    ┌─────────┴─────────┐
             (Streaming Tokens)   (Final Text)
                    │                   │
             [MeetingSegment.text] <────┘
                    │
             [SwiftUI View] (Auto-refresh via @Observable)
```

### Recommended Project Structure
```
Sources/
├── VoiceToTextProtocol.swift  # Add streaming callback support
├── VoiceToTextModel.swift     # Implement WhisperKit streaming
├── ParakeetVoiceToTextModel.swift # Implement FluidAudio streaming
└── MeetingRecorder.swift      # Wire streaming callbacks to UI
```

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Word deduplication | — | `isPending` state | Live streaming naturally handles sequence; don't try to "merge" tokens manually. |
| UI update throttling | Custom timers | `@Observable` | SwiftUI 5+ optimized for high-frequency updates to single properties. |
| CoreML concurrency | DispatchQueues | `TranscriptionQueue` (Actor) | Prevents Neural Engine crashes on M-chips. |

### Architectural Alignment (CRITICAL)
- **Problem:** `MeetingRecorder` жорстко використовує `AsrManager` (Parakeet), ігноруючи налаштування `sttEngine`. `WhisperKit` наразі не задіяний у процесі запису зустрічей.
- **Solution:** `MeetingRecorder` має використовувати `VoiceToTextProtocol` через `VoiceToTextFactory`.
- **Protocol Update:** `VoiceToTextProtocol` потребує розширення для підтримки стрімінгу токенів (`onToken` callback).

## Common Pitfalls

### Pitfall 1: Architectural Misalignment
**What goes wrong:** Стрімінг імплементовано для WhisperKit, але `MeetingRecorder` продовжує викликати Parakeet напряму, ігноруючи нову логіку.
**How to avoid:** Першим кроком фази має бути рефакторинг `MeetingRecorder` для використання `VoiceToTextFactory`.

### Pitfall 2: CoreML Contention
**What goes wrong:** Незважаючи на стрімінг, `TranscriptionQueue` повинна залишатися послідовною, щоб не перевантажити Neural Engine.

### Pitfall 3: UI Flicker/Jumping
**What goes wrong:** Текст "jumps" як Whisper re-decodes and improves the transcript with context.
**Why it happens:** Whisper is a non-autoregressive model that can change previous words in a segment.
**How to avoid:** Accept the "flicker" as a feature of high-accuracy local ASR (documented in `D-09`). Use a fixed-height container or soft animations to minimize visual jars.

### Pitfall 4: Audio Gaps
**What goes wrong:** Missing 100-200ms of audio between chunks.
**Why it happens:** Stopping and starting capture or using non-continuous buffers.
**How to avoid:** Use the existing `systemFallbackBuffer` and `SpeakerBufferManager` which are fed continuously from the capture callback.

### Pitfall 5: Main Thread Blocking
**What goes wrong:** UI hangs during transcription.
**Why it happens:** Performing heavy decoding or WAV writing on the MainActor.
**How to avoid:** Ensure `VoiceToTextModel.process` runs on a background task. Only the final assignment to `segment.text` should hit the MainActor.


## Code Examples

### WhisperKit Streaming Callback
```swift
// Source: https://context7.com/argmaxinc/argmax-oss-swift/llms.txt
let results = try await whisperKit.transcribe(
    audioPath: tempURL.path,
    decodeOptions: options
) { progress in
    // Extract currently decoded text from all segments
    let currentText = progress.segments.map { $0.text }.joined()
    
    // Update UI model (MainActor.run if inside background task)
    Task { @MainActor in
        pendingSegment.text = currentText
    }
    return true // Continue transcription
}
```

### FluidAudio Streaming (Parakeet EOU)
```swift
// Source: https://context7.com/fluidinference/fluidaudio/llms.txt
let manager = StreamingEouAsrManager(chunkSize: .ms320)
// ... feed audio ...
let partialResult = try await manager.process(audioBuffer: buffer)
if !partialResult.isEmpty {
    Task { @MainActor in
        pendingSegment.text += partialResult
    }
}
```

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `@Observable` can handle 10-20 updates/sec without lag. | Architecture Patterns | UI might feel sluggish on older M1 machines. |
| A2 | `TranscriptionProgress.segments` contains cumulative text. | Code Examples | Might need extra logic to handle segments mapping. |

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| CoreML | ASR Engines | ✓ | — | — |
| Neural Engine | M-series performance | ✓ | — | CPU/GPU (Slow) |

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest |
| Quick run command | `swift test --filter StreamingTests` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command |
|--------|----------|-----------|-------------------|
| RT-01 | Tokens appear in Segment.text | Unit | `swift test --filter testTokenStreaming` |
| ARCH-01| Sequential Queue preserved | Integration | `swift test --filter testQueueSerialExecution` |

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | yes | Validate file paths for `tempURL`. Use `FileManager.default.temporaryDirectory`. |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Resource Exhaustion | Denial of Service | `TranscriptionQueue` prevents spawning 100s of CoreML tasks. |

## Sources

### Primary (HIGH confidence)
- `/argmaxinc/argmax-oss-swift` - WhisperKit transcribe callback API. [VERIFIED: context7]
- `/fluidinference/fluidaudio` - StreamingEouAsrManager partial results. [VERIFIED: context7]
- `Sources/MeetingModels.swift` - Observable MeetingSegment definition. [VERIFIED: codebase]

### Secondary (MEDIUM confidence)
- Community forums on WhisperKit "flicker" corrections. [ASSUMED]

## Metadata
**Confidence breakdown:**
- Standard stack: HIGH
- Architecture: HIGH
- Pitfalls: MEDIUM (requires validation on M1/M2)

**Research date:** 2026-04-18
**Valid until:** 2026-05-18
