# Phase 9: Waveform Color Per Speaker - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Make `MeetingWaveformView` reflect the active speaker's palette color in real time. The waveform in the recording bar scrolls a color history — each bar carries the speaker's color from when it was drawn. Color identity is shared with chat bubbles via a single `speakerPaletteColor()` function.

Phase 9 does NOT touch chat bubble UI (Phase 10). Does NOT change recording pipeline or `activeSpeakerLabel` publishing (Phase 8). Does NOT add speaker naming/labeling UI.

</domain>

<decisions>
## Implementation Decisions

### Color rendering style
- **Scrolling history**: each new bar appended to the waveform carries the speaker label active at that timer tick
- Storage: parallel arrays — `levels: [Float]` + `speakerLabels: [String]` — derive `Color` at render time via `speakerPaletteColor(Speaker(label))`
- Each bar renders as **solid fill**: `RoundedRectangle(cornerRadius: 2).fill(speakerPaletteColor(Speaker(label)))`
- No gradient — solid color per bar, unambiguous speaker attribution
- Old bars retain their original speaker color permanently (scrolling history visible)

### Idle / pre-detection state
- `activeSpeakerLabel == ""` → gray: `speakerPaletteColor(.unknown)` → `.gray`
- On recording stop: existing bars **retain** their speaker colors (no fade to gray on stop)
- Bars reset (levels + labels cleared) only when a **new recording starts**

### Speaker change transition
- **Immediate snap** — no animation on color change
- New bars from the detection tick forward use the new speaker's color instantly
- No crossfade or easeOut on color — satisfies RT-03 strictly

### Speaker palette — high-contrast hex values
- Replace SwiftUI semantic colors (`.blue`, `.teal`, `.orange`, etc.) with explicit hex values
- Add `Color+Hex.swift` extension (`Color.init(hex: String)` parsing `#RRGGBB`)
- Update the **shared** `speakerPaletteColor()` in `SharedViews.swift` — one change benefits waveform + `MeetingDetailView` + `MeetingNotesView`
- Approved palette:
  ```
  Index 0 (Me):        #4A9EFF  — vivid blue
  Index 2 (Speaker 1): #00C896  — emerald
  Index 3 (Speaker 2): #FF7A00  — vivid orange
  Index 4 (Speaker 3): #E040FB  — vivid purple
  Index 5 (Speaker 4): #00BCD4  — cyan
  Index 6 (Speaker 5): #FF4081  — pink
  Index 7 (Speaker 6): #69F0AE  — mint
  Index 8 (Speaker 7): #FF6E40  — deep orange
  ```
- `.unknown` / idle → `.gray` (unchanged)

### Claude's Discretion
- Exact minimum bar height when idle (before `isRecording`)
- Whether to keep the existing sine-wave idle animation when not recording
- Whether to preserve `AudioLevelIndicator` and `SpeakerBadge` existing components untouched

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Waveform view
- `Sources/MeetingWaveformView.swift` — existing waveform implementation to modify (currently uses level-based gradient, needs speaker-label history)
- `Sources/SharedViews.swift` — `speakerPaletteColor()` function to update with hex palette; also contains `SpeakerBadge` which already calls it

### Data model
- `Sources/MeetingModels.swift` — `Speaker` enum with `colorIndex`, `Speaker.init(displayName:)` string parsing (`"Me"` → `.me`, `"Speaker 1"` → `.labeled("Speaker 1")`, `""` → `.unknown`)
- `Sources/MeetingRecorder.swift:25` — `@Published private(set) var activeSpeakerLabel: String` — the live speaker signal Phase 9 subscribes to

### Requirements
- `.planning/REQUIREMENTS.md` — RT-01, RT-02, RT-03 (real-time waveform color requirements)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `speakerPaletteColor(_ speaker: Speaker) -> Color` in `SharedViews.swift` — shared color lookup; Phase 9 updates the palette values here
- `MeetingRecorder.activeSpeakerLabel: String` — `@Published` property, already updated on speaker-change detection before ASR (Phase 8)
- `MeetingRecorder.normalizedLevel: Float` — `max(micLevel, systemLevel)`, captures dominant channel — no change needed

### Established Patterns
- `MeetingWaveformView` uses `Timer.publish(every: 0.1)` + `@State private var levels: [Float]` — same timer drives `speakerLabels: [String]` append
- Parallel-array pattern for waveform data is idiomatic in this file
- `Speaker(displayName:)` init already parses label strings — use for `speakerPaletteColor()` lookup

### Integration Points
- `MeetingNotesView.swift:125` — `MeetingWaveformView(recorder: recorder)` — no call-site change needed, same init signature
- `SharedViews.swift` palette update automatically propagates to `MeetingDetailView` and `MeetingNotesView` via `speakerPaletteColor()`

</code_context>

<specifics>
## Specific Ideas

- Palette chosen for high contrast between simultaneous speakers in both light and dark mode — explicit hex to avoid OS-adaptive semantic color variance
- The `Color+Hex.swift` extension parses `#RRGGBB` format (no alpha needed for the palette)

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 09-waveform-color-per-speaker*
*Context gathered: 2026-03-22*
