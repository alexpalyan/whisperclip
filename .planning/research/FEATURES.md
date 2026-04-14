# Feature Research

**Domain:** Real-time streaming ASR with speaker diarization — macOS meeting transcription app
**Researched:** 2026-03-22
**Confidence:** MEDIUM (codebase analysis HIGH; external patterns MEDIUM from training knowledge; web search unavailable)

---

## Context: Existing Pipeline (Do Not Re-Research)

The current pipeline in `MeetingRecorder.swift` delivers fixed 5-second audio chunks from `DualChannelAudioCapture` into a `TranscriptionQueue`, which serializes `AsrManager.transcribe()` calls and then calls `resolveSpeaker()` (dominant-speaker via `DiarizerManager`). Each chunk produces one `MeetingSegment`. The `Speaker` enum has `.me`, `.other`, `.labeled(String)`, `.unknown`. A palette (`speakerPaletteColor`) already exists in `SharedViews.swift`. `MeetingWaveformView` drives a 10 Hz bar-chart waveform from `recorder.normalizedLevel` (single composite level, no per-speaker signal).

v1.1 replaces fixed chunking with per-speaker buffering. This research documents what is table stakes, what is differentiating, and what to avoid.

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features that a user of a speaker-aware meeting transcription tool assumes exist. Missing these makes the product feel broken.

| Feature | Why Expected | Complexity | Pipeline Dependency |
|---------|--------------|------------|---------------------|
| Per-speaker audio buffer — accumulate samples while same speaker is active | Without this, a speaker change mid-chunk splits text attribution wrongly; users expect each utterance to belong to one speaker | MEDIUM | Replaces fixed-5s chunking in `DualChannelAudioCapture` callback; buffer must be keyed per `AudioSource` (mic is always `.me`, system audio goes through `DiarizerManager`) |
| Speaker-change trigger — close buffer and dispatch ASR when speaker changes | This is the minimal reason the buffer exists; if you buffer but never flush on change, you just get bigger wrong segments | MEDIUM | `DiarizerManager.performCompleteDiarization()` must be called incrementally or on incoming frames to detect the change event before the full buffer is written |
| 30-second hard cap — force-flush long monologues regardless of speaker change | Monologues are common in meetings; without a cap, a 10-minute solo segment starves the transcript and makes ASR accuracy collapse on long audio | LOW | A `DispatchSourceTimer` or `Task.sleep` loop watching buffer duration against `sampleRate × 30` |
| Minimum buffer floor — suppress ASR dispatch for very short fragments (< 0.5s) | Sub-second audio is noise or a stutter; dispatching ASR on it produces hallucinations and fills the transcript with garbage | LOW | Gate on `samples.count >= sampleRate / 2` before enqueuing (0.5s = 8000 samples at 16 kHz) |
| Atomic speaker attribution — each dispatched buffer belongs to exactly one speaker | If a buffer is dispatched and then has its speaker re-labeled, the transcript becomes inconsistent; attribution must be locked at dispatch time | LOW | Speaker label captured from `resolveSpeaker()` at flush time, stored in the queued task |
| Stable speaker IDs across buffer boundaries | If "Speaker 1" becomes "Speaker 2" on the next buffer, the transcript is useless | HIGH | `DiarizerManager` uses the same instance throughout the session (already done); `clusteringThreshold: 0.3` (already tuned in code) |
| Mic channel always attributed to "Me", no diarization | `PIPE-05` from PROJECT.md — mic channel identity is known from capture source; running diarization on it wastes CPU and can mis-label | LOW | Already implemented in `resolveSpeaker()`: `if source == .microphone { return .me }` — preserve this invariant |
| Chat-style grouping in MeetingDetailView — consecutive segments from same speaker shown as one bubble group | Users read meeting transcripts like Slack or iMessage; sequential rows from "Speaker 1", "Speaker 1", "Speaker 1" with individual borders is visually noisy and hard to follow | MEDIUM | Requires a computed `[SpeakerGroup]` layer above `[MeetingSegment]` in `transcriptContent`; no model changes needed |
| "Me" bubbles on the right, others on the left | This is the universal iMessage/Slack convention for self-vs-other; violating it is immediately jarring for any user who has ever used a chat app | LOW | `HStack` alignment flip based on `segment.speaker == .me` |
| Speaker name / avatar shown once per group, not per segment | Repeating "Speaker 1" on every line wastes vertical space and makes the grouping less obvious | LOW | Show header only on first segment of a group |
| Timestamp shown at group level, not segment level | For reading flow, a timestamp every 1-2 sentences is too frequent; one timestamp at the end of the group (or on hover) matches iMessage behavior | LOW | Attach `group.lastSegment.endTime` to the bubble cluster footer |

---

### Differentiators (Competitive Advantage)

Features that go beyond baseline expectation and create genuine "this is better" moments.

| Feature | Value Proposition | Complexity | Pipeline Dependency |
|---------|-------------------|------------|---------------------|
| Real-time waveform color tied to active speaker | While recording, the waveform in `MeetingWaveformView` changes color to match the active speaker's palette color — gives instant visual signal of who is talking before any words appear | MEDIUM | `MeetingRecorder` needs a new `@Published var activeSpeaker: Speaker` updated at speaker-change detection time (pre-ASR dispatch); `MeetingWaveformView` reads this to override `barGradient()` per bar or as a whole-bar color |
| Instant color transition at speaker change (not animated fade) | The change in speaker identity is a hard boundary event, not a smooth state; an immediate color switch communicates "this is a new person" more accurately than a fade | LOW | Replace `.animation(.easeInOut)` on color with `.animation(nil)` or a fast `.easeOut(duration: 0.05)` at the speaker-change moment; smooth height animation preserved separately |
| Shared palette between waveform and chat view | Speaker 1 is always teal in both the live waveform and the saved transcript bubble — builds recognition across recording and review modes | LOW | Already partially wired: `speakerPaletteColor` is used in `MeetingDetailView` and `TranscriptSegmentRow`; `MeetingWaveformView.barGradient()` currently uses level-based colors (teal/orange/red) — replace with palette-driven color when `activeSpeaker` is set |
| Overlap window at speaker transition — keep N frames of the previous speaker's audio in the new buffer | Real speech has a ~100-200ms "cross-talk" at transitions; including a small overlap prevents word-clipping at boundaries | MEDIUM | Circular buffer of last ~1600 samples (0.1s at 16 kHz) prepended to new buffer at speaker change; adds complexity to buffer management |
| Transcript auto-scroll to latest bubble during recording | As new segments arrive, the transcript view scrolls to show the newest bubble without user interaction — "live" feel | LOW | `ScrollViewReader` + `.onChange(of: segments.count)` in `MeetingDetailView.transcriptContent`; already has infrastructure via `ScrollView` |

---

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem obvious but create more problems than they solve in this context.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Animated color fade on speaker change (e.g., 0.5s crossfade in waveform) | Smooth transitions feel "polished" | Speaker change is a discrete event, not a continuous one. A fade implies uncertainty about who is speaking. It also adds visual noise while the user is trying to track who said what. More importantly, it means the color shown during the fade does not accurately represent the current speaker — misleading real-time feedback. | Hard cut with short `.easeOut(duration: 0.05)` — fast enough to feel snappy, not so instant it seems glitchy |
| Per-segment timestamps (every bubble line gets a timestamp) | Looks thorough and "professional" | Timestamps on every segment create visual clutter that competes with the text. In a 60-segment meeting, 60 timestamps adds ~900px of noise. iMessage and Slack both suppress per-message timestamps by default. | One timestamp per group (at group footer, right-aligned, dimmed gray) or on hover/tap only |
| Mid-buffer ASR preview (stream partial text while buffer accumulates) | Feels more real-time | Partial Parakeet TDT results are unstable — the transcription engine runs on complete audio; streaming partials would show text that is then retracted and replaced, creating a confusing flickering experience. The existing `TranscriptionQueue` serializes calls for a reason (CoreML thread safety). Partial results would require a parallel "preview" pipeline that bypasses the queue, risking crashes. | Show a typing indicator (`...`) or spinner badge on the waveform while the current buffer is accumulating — signals activity without showing unstable text |
| Automatic speaker naming ("detect that Speaker 1 is John") | Sounds smart | Not technically feasible within the local-only, no-network constraint. The app has no reference embeddings for named individuals. Even if attempted, false positives would be highly disruptive. This is explicitly deferred to v1.2 in PROJECT.md. | Show "Speaker 1", "Speaker 2" consistently; rename manually in v1.2 |
| Overlap detection / cross-talk merging | Meetings have cross-talk; ignoring it seems wrong | Cross-talk segments where two people speak simultaneously are rare in structured meetings and extremely hard to handle correctly. Attempting to split them adds complexity and typically produces worse output (two half-quality segments instead of one good one). The dominant-speaker approach (most speaking time in the chunk wins) is the correct tradeoff. | Accept the dominant-speaker heuristic for overlap; document as known limitation |
| Speaker-change detection below 500ms | More granular turn-taking | Very short turn fragments (< 0.5s) are almost always noise, filler sounds, or diarizer false-positives. Dispatching ASR on them wastes CPU and fills the transcript with empty or hallucinated results. The 0.5s minimum floor is a correctness guard, not an optimization. | Enforce minimum buffer floor of 0.5s at the accumulation layer |
| Per-speaker audio visualization (two parallel waveforms, one per speaker) | Feels informative | Adds significant UI complexity to the recording bar. macOS menu-bar window is space-constrained. More critically, the system audio channel is mono — splitting it into two visual waveforms implies separate amplitude measurements per speaker, which requires STFT analysis that does not exist in the current stack. | Single waveform with color representing the dominant active speaker |

---

## Feature Dependencies

```
[PIPE-01: Per-speaker buffer accumulation]
    └──requires──> [DualChannelAudioCapture frame callbacks at sub-5s intervals]
    └──requires──> [DiarizerManager incremental call or per-frame detection]
                       └──enables──> [PIPE-02: Speaker-change trigger]
                       └──enables──> [RT-01: activeSpeaker published property]

[PIPE-02: Speaker-change trigger]
    └──requires──> [PIPE-01: per-speaker buffer]
    └──enables──> [PIPE-04: atomic ASR dispatch]

[PIPE-03: 30s max duration cap]
    └──requires──> [PIPE-01: per-speaker buffer] (needs buffer start timestamp)
    └──parallel-with──> [PIPE-02: speaker-change trigger]
    (either PIPE-02 or PIPE-03 can flush the buffer; whichever fires first wins)

[PIPE-04: atomic ASR per speaker segment]
    └──requires──> [PIPE-01 + PIPE-02 + PIPE-03 all delivering closed buffers]
    └──uses──> [TranscriptionQueue (existing)] — no changes needed here

[RT-01: Waveform color per active speaker]
    └──requires──> [PIPE-02: speaker-change detection publishes activeSpeaker]
    └──requires──> [speakerPaletteColor (existing in SharedViews.swift)]
    └──modifies──> [MeetingWaveformView.barGradient()]

[RT-02: Shared palette waveform + chat]
    └──requires──> [RT-01]
    └──requires──> [speakerPaletteColor already used in MeetingDetailView] — LOW effort

[CHAT-01: Bubble grouping]
    └──requires──> [MeetingSegment.speaker stable across session] (SPKR-01, SPKR-02, SPKR-03)
    └──requires──> [segments sorted by startTime] (MeetingNote.addSegment already does this)
    └──does NOT require──> [pipeline changes] — pure UI grouping computed from existing [MeetingSegment]

[CHAT-02: Speaker name once per group]
    └──requires──> [CHAT-01]

[CHAT-03: Timestamp once per group]
    └──requires──> [CHAT-01]
    └──uses──> [MeetingSegment.formattedTime (existing)]

[CHAT-04: Me-right, others-left alignment]
    └──requires──> [CHAT-01]
    └──uses──> [Speaker.me case (existing)]
```

### Dependency Notes

- **PIPE-01 through PIPE-04 must land together** — a partial pipeline rewrite where buffering works but speaker-change dispatch doesn't means no segments ever arrive. Implement as one atomic phase.
- **SPKR-01/02/03 are prerequisites for CHAT-01** — chat grouping only looks correct if speaker labels are stable. If `Speaker 1` appears, then `Speaker 2`, then `Speaker 1` again due to ID drift, groups will fragment incorrectly.
- **RT-01 requires PIPE-02** — waveform color can only update if speaker-change detection runs ahead of ASR completion. This is intentional: color changes when the speaker changes (pre-transcription), not when text appears.
- **CHAT features are independent of PIPE features** — the chat UI grouping works on `[MeetingSegment]` already stored in `MeetingNote`. It can be implemented against existing v1.0 data as a pure SwiftUI refactor of `transcriptContent` in `MeetingDetailView`.

---

## MVP Definition

### Launch With (v1.1)

Minimum needed to make diarization-first pipeline meaningful to the user.

- [ ] **PIPE-01 + PIPE-02 + PIPE-03 + PIPE-04** — Per-speaker buffering with speaker-change flush and 30s cap. Without this, the v1.1 goal of "each utterance is a clean segment" does not exist. This is the pipeline rewrite.
- [ ] **SPKR-01/02/03** — Stable speaker IDs. Without stability, all downstream features (grouping, coloring) produce wrong output.
- [ ] **CHAT-01 + CHAT-02 + CHAT-03 + CHAT-04** — iMessage-style bubble grouping. This is the primary user-visible output of the pipeline rewrite. If the transcript still looks like a plain list after the pipeline is fixed, the work is invisible to users.
- [ ] **RT-01 + RT-02 + RT-03** — Waveform color per speaker. This is the real-time "who is speaking" signal. Low implementation cost relative to value.

### Add After Validation (v1.x)

- [ ] **Overlap window prepend** — Keep ~100ms of previous speaker's audio in new buffer. Trigger: users report word-clipping at speaker transitions in testing. Low-risk addition after core pipeline is stable.
- [ ] **Transcript auto-scroll** — ScrollViewReader auto-scroll to latest bubble during live recording. Trigger: user feedback that the view doesn't follow new segments.
- [ ] **Typing indicator during accumulation** — Show animated `...` badge on waveform while buffer is building (before ASR dispatch). Trigger: user feedback that silence between speaker turns feels like the app froze.

### Future Consideration (v2+)

- [ ] **Speaker naming UI** — Explicitly out of scope per PROJECT.md. Defer to v1.2.
- [ ] **Per-speaker audio visualization** — Two parallel waveforms. Too much complexity, constrained UI space.
- [ ] **Partial ASR preview** — Conflicts with `TranscriptionQueue` safety design.

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| PIPE-01/02/03/04: Per-speaker buffer + flush pipeline | HIGH | HIGH | P1 |
| SPKR-01/02/03: Stable speaker IDs (clusteringThreshold tuning) | HIGH | MEDIUM | P1 |
| CHAT-01/02/03/04: iMessage bubble grouping | HIGH | MEDIUM | P1 |
| RT-01/02/03: Waveform color per speaker | MEDIUM | LOW | P1 |
| Transcript auto-scroll | MEDIUM | LOW | P2 |
| Overlap window prepend at transition | LOW | MEDIUM | P2 |
| Typing indicator during buffer accumulation | LOW | LOW | P2 |
| Speaker naming UI | HIGH | HIGH | P3 (v1.2) |

**Priority key:** P1 = v1.1 launch, P2 = add after validation, P3 = future milestone

---

## Buffer Management Rules (Specific Decisions)

These are opinionated recommendations based on the existing codebase and streaming ASR conventions.

| Rule | Value | Rationale |
|------|-------|-----------|
| Minimum buffer duration before ASR dispatch | 0.5s (8,000 samples at 16 kHz) | Below this, Parakeet TDT produces hallucinations on silence/noise. Existing code already checks `samples.count >= sampleRate * 2` (2s minimum) — this is conservative. For speaker-change-driven buffers, 0.5s is sufficient since the trigger is semantic (speaker changed) not temporal. |
| Maximum buffer duration cap | 30s (480,000 samples at 16 kHz) | From PIPE-03 in PROJECT.md. Parakeet TDT accuracy degrades on very long audio. 30s is a widely-used monologue cap in streaming ASR systems. |
| Speaker-change detection granularity | Per incoming audio frame batch from `DualChannelAudioCapture` | Detection runs on each batch; if speaker ID differs from current buffer's speaker, flush current buffer and start new one. |
| Overlap at transition | 0 initially (v1.1); 1,600 samples (0.1s) optionally in v1.x | Start simple. No overlap means cleaner buffer boundaries. Add overlap only if word-clipping is observed. |
| Buffer keyed by | `AudioSource` (`.microphone` or `.system`) | Mic and system audio are independent channels and cannot share a buffer. Each channel has its own accumulator. |
| Speaker assigned at flush time | Dominant speaker for the buffer's full duration | Same heuristic as current `resolveSpeaker()`. Lock label at dispatch time, never retroactively re-label a dispatched buffer. |

---

## Chat Bubble Grouping Rules (Specific Decisions)

| Rule | Value | Rationale |
|------|-------|-----------|
| New group trigger | `segment.speaker != previousSegment.speaker` | Standard iMessage/Slack rule: consecutive segments from same speaker belong to same group. |
| Time gap threshold for new group | None in v1.1 | Do not start a new group based on time gap alone. The speaker-change-driven pipeline produces semantically correct boundaries already. Adding a time gap rule (e.g., "new group if > 30s gap") is a v1.x refinement if users request it. |
| Speaker header position | Top of group | Name + icon shown once above the first segment of each group. Hidden for subsequent segments. |
| Timestamp position | Bottom-right of last segment in group | Right-aligned, dimmed gray, formatted as `MM:SS` from `MeetingSegment.formattedTime`. Hidden for intermediate segments within a group. |
| "Me" alignment | Trailing (right side) | `HStack(spacing: 0) { Spacer(); bubble }` for `.me`. Standard iMessage layout. |
| Others alignment | Leading (left side) | `HStack(spacing: 0) { bubble; Spacer() }` for any non-`.me` speaker. |
| Bubble max width | 75% of container width | Industry standard for chat bubbles. Prevents very short utterances from looking odd on wide screens. |
| Background color | `speakerPaletteColor(speaker).opacity(0.15)` with a 2px leading border in `speakerPaletteColor(speaker)` | Uses the existing palette. Subtle background + colored left border is readable on dark background without overwhelming. For `.me` bubbles: blue tint, no leading border (right-aligned). |
| Group data structure | `struct SpeakerGroup { let speaker: Speaker; let segments: [MeetingSegment] }` computed from `meeting.segments` | Computed property on `MeetingDetailView`, not persisted. Groups rebuild when segments array changes. |

---

## Waveform Color Rules (Specific Decisions)

| Rule | Value | Rationale |
|------|-------|-----------|
| Color source | `speakerPaletteColor(recorder.activeSpeaker)` | Same palette as chat view — visual consistency between live recording and transcript review. |
| Default (no speech / silence) | `.gray` or `.teal` (existing default) | When no speaker is active, fall back to existing teal. |
| Transition timing | Instant (`.animation(nil)` or `duration: 0.0`) on color, preserved smooth animation on bar height | Speaker change is a hard boundary. Color conveys identity, not energy. Height animation (`.easeOut(0.1)`) remains for the level animation. |
| `activeSpeaker` property on `MeetingRecorder` | `@Published var activeSpeaker: Speaker = .unknown` | Updated in the speaker-change detection path, before the ASR buffer is enqueued. This makes the waveform update immediately when the change is detected, not after ASR completes (which could be 1-3 seconds later). |
| Bar gradient vs. solid color | Solid color derived from palette; remove existing level-based gradient in `MeetingWaveformView.barGradient()` | Level-based gradient (teal→orange→red) conflicts with speaker-based color. Can't have both. Speaker identity wins — it's more semantically meaningful than amplitude level. |

---

## Sources

- Codebase analysis: `MeetingRecorder.swift`, `MeetingWaveformView.swift`, `MeetingDetailView.swift`, `MeetingModels.swift`, `SharedViews.swift` (HIGH confidence — direct code reading)
- PROJECT.md v1.1 milestone requirements: PIPE-01 through PIPE-05, SPKR-01 through SPKR-03, RT-01 through RT-03, CHAT-01 through CHAT-04 (HIGH confidence — authoritative project spec)
- Streaming ASR buffer conventions (MEDIUM confidence — training knowledge, web search unavailable): min 0.5s floor, 30s cap, dominant-speaker attribution are widely-used heuristics in production systems (e.g., Google Live Transcribe, AWS Transcribe Streaming, OpenAI Whisper real-time implementations)
- iMessage/chat bubble UX conventions (MEDIUM confidence — training knowledge): right-for-self, left-for-others, timestamp at group end, header once per group — these are stable Apple HIG conventions visible in Messages.app, iMessage, and widely reproduced in SwiftUI chat tutorials

---

*Feature research for: WhisperClip v1.1 Speaker Diarization pipeline rewrite*
*Researched: 2026-03-22*
