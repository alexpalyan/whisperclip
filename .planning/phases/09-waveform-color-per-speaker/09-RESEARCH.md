# Phase 09: Waveform Color Per Speaker - Research

**Researched:** 2026-03-22
**Domain:** SwiftUI Real-time Graphics & Color Palette Management
**Confidence:** HIGH

## Summary

This phase focuses on visual feedback for speaker attribution. The primary goal is to make the waveform in the recording bar reflect the active speaker's identity using a shared color palette. Research confirms that for high-frequency UI updates (10Hz-20Hz), SwiftUI's `Canvas` is significantly more performant than a view-based `HStack` of `RoundedRectangle`s. 

To satisfy the "real-time" requirement (RT-03), we must avoid the "one speaker behind" pitfall caused by the current buffer-based publishing logic. We recommend promoting `activeSpeaker` to a first-class `@Published` property in `MeetingRecorder` that switches based on a combination of raw channel levels (for "Me") and live diarization polling (for system audio).

**Primary recommendation:** Use `Canvas` to render the scrolling waveform and implement a real-time `dominantSpeaker` resolution logic in `MeetingRecorder` to drive the current bar's color without chunk delay.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **Scrolling history**: each new bar appended to the waveform carries the speaker label active at that timer tick
- Storage: parallel arrays — `levels: [Float]` + `speakerLabels: [String]` — derive `Color` at render time via `speakerPaletteColor(Speaker(label))`
- Each bar renders as **solid fill**: `RoundedRectangle(cornerRadius: 2).fill(speakerPaletteColor(Speaker(label)))`
- No gradient — solid color per bar, unambiguous speaker attribution
- Old bars retain their original speaker color permanently (scrolling history visible)
- `activeSpeakerLabel == ""` → gray: `speakerPaletteColor(.unknown)` → `.gray`
- On recording stop: existing bars **retain** their speaker colors (no fade to gray on stop)
- Bars reset (levels + labels cleared) only when a **new recording starts**
- **Immediate snap** — no animation on color change
- Replace SwiftUI semantic colors with explicit hex values
- Add `Color+Hex.swift` extension (`Color.init(hex: String)`)
- Update the **shared** `speakerPaletteColor()` in `SharedViews.swift`

### Claude's Discretion
- Exact minimum bar height when idle (before `isRecording`)
- Whether to keep the existing sine-wave idle animation when not recording
- Whether to preserve `AudioLevelIndicator` and `SpeakerBadge` existing components untouched

### Deferred Ideas (OUT OF SCOPE)
- None — discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| RT-01 | Waveform in recording bar reflects active speaker's color | Architecture: `Canvas` rendering with history storage. |
| RT-02 | Each speaker has unique color from shared palette | Palette: `speakerPaletteColor()` update with hex values. |
| RT-03 | Color transition occurs at moment of detection | Optimization: Real-time speaker resolution (mic vs live system detection). |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SwiftUI Canvas | Native | Immediate-mode rendering | High performance for 60FPS drawing; avoids view-diffing overhead. |
| Color+Hex | Custom | Hex-based color initialization | Ensures high contrast across Light/Dark modes without OS interference. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| TimelineView | Native | Drawing heartbeat | Alternative to `Timer` for perfectly synced 60Hz/120Hz updates. |

**Version verification:**
- SwiftUI `Canvas` (macOS 12.0+) - Current
- `TimelineView` (macOS 12.0+) - Current

## Architecture Patterns

### Recommended Project Structure
```
Sources/
├── Extensions/
│   └── Color+Hex.swift      # Hex parsing logic
├── Waveform/
│   └── MeetingWaveformView.swift # Modified to use Canvas + Speaker history
└── Shared/
    └── SharedViews.swift    # Updated speakerPaletteColor with hex values
```

### Pattern 1: Waveform History Struct
Instead of parallel arrays (`[Float]` and `[String]`), use a unified struct to prevent desync during high-frequency appends.
```typescript
struct WaveformPoint {
    let level: Float
    let speaker: Speaker
}

// In View:
@State private var history: [WaveformPoint] = []
```

### Pattern 2: Immediate-Mode Drawing (Canvas)
Draw the history in a single pass. This is O(n) where n is the number of visible bars (e.g., 50-100), which is extremely cheap for the GPU.

### Anti-Patterns to Avoid
- **HStack of Views:** Creating 50+ `RoundedRectangle` views and updating their heights at 10Hz-20Hz causes layout thrash and high CPU usage.
- **Buffer-Delayed Labels:** Don't wait for `ClosedSpeakerBuffer` to update the UI color. The UI will be one speaker "behind". Use live detection.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Hex Parsing | Custom regex | Standard `Scanner` extension | More robust, handles alpha/shorthand, fewer edge cases. |
| Scrolling logic | `ScrollView` | Index-based drawing | `ScrollView` is too heavy for 10Hz updates of many small elements. |
| Color Animation | `withAnimation` | Instant state update | Per requirements (RT-03), transitions should be "snappy" and immediate. |

## Common Pitfalls

### Pitfall 1: The "One Speaker Behind" Delay
**What goes wrong:** UI color changes only when a speaker *stops* talking, because labels are published from closed buffers.
**Why it happens:** `SpeakerBufferManager` flushes on detection, but the published `activeSpeakerLabel` is the label of the flushed (old) buffer.
**How to avoid:** `SpeakerBufferManager` must publish a "Live Speaker" signal as soon as the diarizer identifies a dominant ID in its 150ms window.

### Pitfall 2: Mic vs System Ambiguity
**What goes wrong:** "Me" (mic) color doesn't show up in the waveform because the system audio diarizer is dominant.
**Why it happens:** Mic audio doesn't go through the diarizer.
**How to avoid:** Use channel power comparison. If `micLevel > systemLevel` and above a noise floor (-50dB), force the current point's speaker to `.me`.

### Pitfall 3: Palette Readability
**What goes wrong:** Emerald and Mint look identical in Dark Mode.
**How to avoid:** Use the specific hex values provided in CONTEXT.md. They were chosen for high contrast.

## Code Examples

### Hex Color Extension
```swift
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
```

### Canvas Drawing Loop
```swift
Canvas { context, size in
    let barWidth = (size.width - CGFloat(maxSamples - 1) * spacing) / CGFloat(maxSamples)
    
    for (index, point) in history.enumerated() {
        let x = CGFloat(index) * (barWidth + spacing)
        let height = max(4, CGFloat(point.level) * size.height)
        let y = (size.height - height) / 2
        
        let rect = CGRect(x: x, y: y, width: barWidth, height: height)
        let path = RoundedRectangle(cornerRadius: 2).path(in: rect)
        
        context.fill(path, with: .color(speakerPaletteColor(point.speaker)))
    }
}
```

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest |
| Config file | WhisperClip.xcodeproj |
| Quick run command | `swift test` |
| Full suite command | `./build.sh test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| RT-01 | Waveform color updates in real-time | Integration | `N/A (Visual/Manual)` | ❌ |
| RT-02 | Correct palette color for Speaker ID | Unit | `swift test --filter SharedViewsTests` | ❌ |
| RT-03 | Instant transition on speaker change | Manual | `N/A` | ❌ |

### Waveform Logic Validation (Unit Test)
While UI is hard to test automatically, the **Speaker Resolution Logic** should be tested:
- `testSpeakerResolution_MicDominant_ReturnsMe()`
- `testSpeakerResolution_SystemDominant_ReturnsSpeakerLabel()`
- `testSpeakerResolution_Silence_ReturnsUnknown()`

## Sources

### Primary (HIGH confidence)
- SwiftUI Documentation - `Canvas` performance characteristics.
- `Sources/SharedViews.swift` - Existing palette implementation.
- `Sources/MeetingRecorder.swift` - Current publishing architecture.

### Secondary (MEDIUM confidence)
- Apple Developer Forums - Discussions on high-frequency UI updates in SwiftUI.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Canvas is the proven solution for this domain.
- Architecture: HIGH - Level-based switching is standard for dual-channel capture.
- Pitfalls: HIGH - Identified a major implementation gap (buffer delay).

**Research date:** 2026-03-22
**Valid until:** 2026-04-22
