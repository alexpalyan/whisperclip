# Phase 07: DualChannelAudioCapture Streaming Callback - Research

**Researched:** 2026-03-22
**Domain:** Real-time Audio Streaming (macOS ScreenCaptureKit)
**Confidence:** HIGH

## Summary
This research focuses on replacing the 5-second chunking timer for system audio with a real-time streaming callback using `SCStreamOutput`. The microphone path remains isolated in `AVAudioEngine`. The primary challenge is maintaining "real-time safety" in the audio callback to prevent glitches while bridging to the `SpeakerBufferManager` actor.

**Primary recommendation:** Use `CMSampleBuffer.withAudioBufferList` for zero-copy access to PCM data and immediately hand off to a detached Task to bridge the nonisolated callback to the Actor-based pipeline.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- `startCapture()` gains `onSystemBatch: @escaping ([Float], TimeInterval) -> Void`.
- Existing `AudioChunkCallback` remains for the mic path.
- `onSystemBatch` is required; throw `DualChannelError.systemBatchCallbackRequired` if missing.
- Verification of 32-bit float PCM format on every buffer.
- `stopCapture()` returns only mic samples.

### Claude's Discretion
- `DualChannelError` case name: `systemBatchCallbackRequired`.
- Remove `AudioBufferActor.getSystemSamples()` as it becomes dead code.
- Handle Task hop from `nonisolated` to `onSystemBatch` via `Task { await onSystemBatch(...) }`.

### Deferred Ideas (OUT OF SCOPE)
- None.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| PIPE-05 | Mic audio is always "Me", processed separately | Architecture pattern ensures mic path remains in AVAudioEngine/AudioBufferActor, while system audio bypasses it. |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| ScreenCaptureKit | macOS 14+ | System Audio Capture | Native, high-performance API for capturing system/display audio. |
| AVFoundation | macOS 14+ | Audio Format/Buffers | Standard types for PCM processing (`AVAudioPCMBuffer`). |

## Architecture Patterns

### Recommended Project Structure
- `Sources/DualChannelAudioCapture.swift` (Producer): Extracts samples from `SCStreamOutput`.
- `Sources/MeetingRecorder.swift` (Coordinator): Wires the callback to the manager.
- `Sources/SpeakerBufferManager.swift` (Consumer): Actor-based buffer management and diarization.

### Pattern 1: Real-Time Safe Extraction
**What:** Accessing raw data from `CMSampleBuffer` without heap allocations.
**Example:**
```swift
// Source: Official Apple Documentation / ScreenCaptureKit Samples
nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio, sampleBuffer.isValid else { return }
    
    try? sampleBuffer.withAudioBufferList { audioBufferList, blockBuffer in
        // Access mBuffers[0].mData directly
        // Bridge to Swift Array or process via UnsafeBufferPointer
    }
}
```

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Sample Extraction | Manual pointer math | `withAudioBufferList` | Handles `CMBlockBuffer` lifecycle and provides safe access to `AudioBufferList`. |
| Format Validation | Hardcoded assumptions | `CMSampleBufferGetFormatDescription` | System audio format can change if the output device (e.g., AirPods) is switched mid-session. |

## Common Pitfalls

### Pitfall 1: Priority Inversion / Deadlocks
**What goes wrong:** The `SCStreamOutput` callback runs on a high-priority real-time thread. If it waits for an Actor or a Lock, and that lock is held by a lower-priority thread (e.g., UI), audio capture will stall.
**Prevention:** Always use `Task { await callback(...) }` to hop from the real-time thread to the Actor world. Never use `DispatchQueue.sync`.

### Pitfall 2: ARC Traffic (Retain/Release)
**What goes wrong:** Passing class instances into the closure inside the callback can trigger atomic reference counting, which uses locks.
**Prevention:** Use `weak self` or capture necessary values (like `startTime`) as `nonisolated(unsafe)` primitives if verified safe.

## Code Examples

### Verified 32-bit Float Extraction
```swift
// Source: ScreenCaptureKit SOTA
guard let description = CMSampleBufferGetFormatDescription(sampleBuffer)?.audioStreamBasicDescription else { return }
// Verify: kAudioFormatLinearPCM, kAudioFormatFlagIsFloat, 32 bits
        
try? sampleBuffer.withAudioBufferList { audioBufferList, blockBuffer in
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for buffer in buffers {
        guard let mData = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = Array(UnsafeBufferPointer(start: mData.assumingMemoryBound(to: Float.self), count: count))
        
        let elapsed = self.startTime.map { Date().timeIntervalSince($0) } ?? 0
        Task { [onSystemBatch] in
            onSystemBatch(samples, elapsed)
        }
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Chunking Timer | Streaming Callback | Phase 07 | Zero-latency ingestion, better diarization accuracy. |
| AudioBufferActor (System) | Direct Dispatch | Phase 07 | Reduced memory footprint, simpler pipeline. |

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest |
| Quick run command | `swift test --filter DualChannelAudioCaptureTests` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command |
|--------|----------|-----------|-------------------|
| PIPE-05 | Mic path unchanged | Regression | `swift test --filter AudioRecorderTests` |
| PHASE-07 | Callback fires | Unit | `swift test --filter DualChannelAudioCaptureTests/testStreamingCallback` |

## Sources
- Apple Documentation: SCStreamOutput
- Apple Documentation: CMSampleBuffer
- Real-time Audio Safety (WWDC sessions)
