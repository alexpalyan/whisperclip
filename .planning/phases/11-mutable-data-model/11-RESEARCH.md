# Phase 11: Mutable Data Model + Diarizer Micro-Windows - Research

**Researched:** 2026-03-23
**Domain:** macOS 14 SwiftUI, @Observable, AVFoundation PCM Splitting, Diarization Pipeline
**Confidence:** HIGH

## Summary

Phase 11 focuses on modernizing the data model to support real-time reactive updates and improving diarization accuracy using 7-second "micro-windows" with sample-accurate audio splitting. The transition from `struct MeetingSegment` to an `@Observable class` is the architectural linchpin, enabling a "Pending" state UI where segments appear immediately and update as transcription finishes.

**Primary recommendation:** Use a "Reference-based Reactive Model" where `MeetingRecorder` emits `@Observable` class instances immediately in a `.pending` state, allowing the `TranscriptionQueue` to update the `text` property on the same object, triggering surgical UI updates without full list re-renders.

## User Constraints (from CONTEXT.md)

### Locked Decisions
- **MUT: Mutable Data Model**: `MeetingSegment` becomes an `@Observable class` (macOS 14+).
- **Identity**: Each segment has a stable `id: UUID`.
- **Persistence**: Maintain `Codable` compatibility for `MeetingStorage`.
- **DIAR: Diarizer Micro-Windows**: 7-second windows.
- **Splitting**: Pre-ASR audio splitting if speaker change is detected within a window.
- **UI: Pending State**: Neutral gray color for segments with no text, "..." animation.
- **ARCH: Async Reconciliation**: Use a background `actor` (Reconciler) for updates.

### the agent's Discretion
- **Splitting Logic**: Recommendation to replace one segment with two during a split.
- **Animation**: Use `withAnimation(.easeInOut)` for state transitions.

### Deferred Ideas (OUT OF SCOPE)
- **SwiftData Migration**: Postponed to v1.2.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Observation | macOS 14+ | Reactive state | Replaces ObservableObject; surgical UI updates. |
| FluidAudio | Current | Diarization | High-performance speaker embedding extraction. |
| AVFoundation | Current | PCM Audio | Native macOS audio processing. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|--------------|
| Foundation | Current | Persistence | JSON encoding/decoding for class-based models. |

## Architecture Patterns

### Recommended Project Structure (Phase 11 Changes)
```
Sources/
├── MeetingModels.swift       # MeetingSegment: struct -> @Observable class
├── MeetingSession.swift      # Manages the list of segments
├── MeetingRecorder.swift     # Emits segments early (Pending state)
└── Reconciler.swift          # (New) Actor to handle async transcription updates
```

### Pattern 1: The "Early Emission" Pending Pattern
Instead of waiting for transcription to finish before adding a segment to the UI, `MeetingRecorder` creates and emits the segment object *before* calling the ASR engine.

**What:** Create `@Observable` instance -> Add to Session -> Start ASR -> Update property on success.
**When to use:** Long-running async operations (like transcription) where the user expects immediate visual feedback.

### Pattern 2: Sample-Accurate Splitting
When `DiarizerManager` detects a speaker change at offset `T` within a 7s buffer, the buffer must be sliced exactly at `sampleIndex = T * sampleRate`.

**Example:**
```swift
// Sample-accurate slice for [Float]
func splitBuffer(_ samples: [Float], atSeconds offset: Double, sampleRate: Int) -> ([Float], [Float]) {
    let splitIndex = Int(offset * Double(sampleRate))
    let first = Array(samples.prefix(splitIndex))
    let second = Array(samples.dropFirst(splitIndex))
    return (first, second)
}
```

### Anti-Patterns to Avoid
- **Manual ObservedObject**: Don't use `ObservableObject` in macOS 14; it causes too many re-renders for large lists.
- **Struct Replacement**: Don't replace the entire segment struct in an array; it breaks scroll position and causes jitter. Update class properties instead.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| PCM Slicing | Custom loop | `Array` slicing / `memcpy` | Native methods are highly optimized for SIMD. |
| Reactive List | Custom notification | `@Observable` | Built-in surgical observation in SwiftUI. |
| ID Generation | Random strings | `UUID` | RFC-compliant uniqueness. |

## Common Pitfalls

### Pitfall 1: @Observable + Codable Leakage
**What goes wrong:** Synthesized `Codable` includes internal macro properties like `_$observationRegistrar` and uses underscored names (`_text`) in JSON.
**Why it happens:** The macro rewrites stored properties to be backed by underscored storage.
**How to avoid:** Define explicit `CodingKeys` and implement `init(from:)` and `encode(to:)` manually.

### Pitfall 2: Overlapping 7s Windows
**What goes wrong:** If polling every 150ms with a 7s window, the same speaker change is detected multiple times.
**How to avoid:** Only split based on the *first* detected change that falls within the "new" audio segment of the window, or maintain a "processed cursor".

### Pitfall 3: List Scroll Jitter
**What goes wrong:** Inserting multiple segments (e.g., during a split) can cause the List to jump.
**How to avoid:** Use `withAnimation` and ensures segments have stable IDs. If splitting, the first segment can inherit the original ID while the second gets a new one.

## Code Examples

### Manual Codable for @Observable class
```swift
@Observable class MeetingSegment: Identifiable, Codable {
    let id: UUID
    var text: String
    var isPending: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, text, isPending
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.text = try container.decode(String.self, forKey: .text)
        self.isPending = try container.decode(Bool.self, forKey: .isPending)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(isPending, forKey: .isPending)
    }
}
```

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Observation framework | @Observable | ✓ | macOS 14.0+ | N/A (Minimum Req) |
| FluidAudio | Diarization | ✓ | Current | Skip diarization |
| Apple Silicon | Real-time Diarization | ✓ | M1+ | Slower inference |

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest |
| Config file | None (Standard SPM) |
| Quick run command | `swift test --filter MeetingSegmentTests` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command |
|--------|----------|-----------|-------------------|
| MUT-01 | MeetingSegment updates triggers row re-render | UI / Integration | `swift test --filter ObservationTests` |
| DIAR-01 | Buffer splits accurately at timestamp | Unit | `swift test --filter BufferSplitTests` |
| COD-01 | Manual Codable preserves JSON structure | Unit | `swift test --filter PersistenceTests` |

## Sources

### Primary (HIGH confidence)
- **Apple Documentation**: "Managing model data in your app" (@Observable).
- **Swift Evolution Proposal SE-0395**: Observation macro implementation details.
- **FluidAudio SDK**: `DiarizerManager` and `TimedSpeakerSegment` API.

### Secondary (MEDIUM confidence)
- **Community Blogs**: "Pitfalls of Codable with @Observable" (Verified via local experiment hypothesis).

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Built-in Apple frameworks.
- Architecture: HIGH - Standard reactive patterns for SwiftUI 2024.
- Pitfalls: HIGH - Well-documented macro behavior.

**Research date:** 2026-03-23
**Valid until:** 2026-06-23 (Stable macOS 14 APIs)
