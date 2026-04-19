# Roadmap: WhisperClip

## Milestones

- ✅ **v1.0 SettingsView Refactoring** — Phases 1-5 (shipped 2026-03-22)
- ✅ **v1.1 Speaker Diarization** — Phases 6-9 (shipped 2026-03-23)
- 🚧 **v1.2 Live Enrichment & Diarization Fix** — Phases 10-13 (in progress)

## Phases

<details>
<summary>✅ v1.0 SettingsView Refactoring (Phases 1-5) — SHIPPED 2026-03-22</summary>

### Phase 1: UI Decomposition

**Goal**: SettingsView split into focused per-tab sub-views
**Requirements**: UI-01, UI-02, UI-03, UI-04, UI-05, UI-06
**Plans**: 3/3 complete

Plans:

- [x] 01-01-PLAN.md — Extract GeneralSettingsView and tab scaffolding
- [x] 01-02-PLAN.md — Extract HotkeySettingsView and LLMSettingsView
- [x] 01-03-PLAN.md — Extract PromptSettingsView and wire all tabs

### Phase 2: ViewModel Extraction

**Goal**: HotkeySettingsViewModel, LLMModelViewModel, PromptManagementViewModel extracted and wired
**Requirements**: VM-01, VM-02, VM-03, VM-04
**Plans**: 4/4 complete

Plans:

- [x] 02-01-PLAN.md — HotkeySettingsViewModel
- [x] 02-02-PLAN.md — LLMModelViewModel
- [x] 02-03-PLAN.md — PromptManagementViewModel
- [x] 02-04-PLAN.md — Wire ViewModels into sub-views

### Phase 3: SwiftData Migration

**Goal**: Prompt model migrated to SwiftData @Model, UserDefaults removed for prompts
**Requirements**: SD-01, SD-02, SD-03
**Plans**: 2/2 complete

Plans:

- [x] 03-01-PLAN.md — SwiftData Prompt @Model and container setup
- [x] 03-02-PLAN.md — Migrate PromptManagementViewModel to SwiftData

### Phase 4: Test Coverage

**Goal**: 18 XCTests covering all ViewModels and SwiftData operations
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04
**Plans**: 3/3 complete

Plans:

- [x] 04-01-PLAN.md — HotkeySettingsViewModelTests
- [x] 04-02-PLAN.md — LLMModelViewModelTests and PromptManagementViewModelTests
- [x] 04-03-PLAN.md — SwiftData integration tests

### Phase 5: Hotkey Fix

**Goal**: Fix global hotkey registration — replace broken CGEventTap with KeyboardShortcuts, wire launch-time registration in AppDelegate, add Combine subscriptions for live settings propagation
**Requirements**: HF-01, HF-02, HF-03, HF-04, HF-05
**Plans**: 2/2 complete

Plans:

- [x] 05-01-PLAN.md — Add KeyboardShortcuts dependency and rewrite HotkeyManager internals
- [x] 05-02-PLAN.md — Wire AppDelegate launch registration, Combine subscriptions, remove dead code

</details>

---

<details>
<summary>✅ v1.1 Speaker Diarization (Phases 6-9) — SHIPPED 2026-03-23</summary>

**Milestone Goal:** Foundation pipeline — dual-channel audio capture, SpeakerBufferManager, per-speaker waveform color with real-time feedback. Battle-tested in live meeting 2026-03-23.

**Shipped:**
- Dual-channel audio capture (mic always "Me", system via diarizer)
- SpeakerBufferManager actor with stable speaker IDs
- Canvas waveform with per-bar speaker color history and -50dB noise floor
- Hex palette + `speakerPaletteColor()` as single source of truth
- `activeSpeakerLabel` correctly published for mic path

**Not shipped (moved to v1.2):** Chat Bubble UI — deferred to build on mutable data model.

#### Phase 6: SpeakerBufferManager Actor

**Goal**: A standalone, unit-testable Swift actor that accumulates per-speaker audio buffers, detects speaker changes via diarization polling, enforces the 30-second cap and 0.5s minimum floor, resolves stable speaker labels, and dispatches closed buffers through TranscriptionQueue — with all concurrency constraints baked in
**Depends on**: Phase 5 (v1.0 complete)
**Requirements**: PIPE-01, PIPE-02, PIPE-03, PIPE-04, PIPE-06, SPKR-01, SPKR-02, SPKR-03
**Plans**: 3/3 complete

Plans:

- [x] 06-01-PLAN.md — Strict concurrency flag, DiarizationProvider protocol, ClosedSpeakerBuffer, test stubs
- [x] 06-02-PLAN.md — SpeakerBufferManager actor implementation and 10 passing unit tests
- [x] 06-03-PLAN.md — TranscriptionQueue promotion and strict concurrency warning cleanup

#### Phase 7: DualChannelAudioCapture Streaming Callback

**Goal**: System audio flows into SpeakerBufferManager continuously via a streaming callback that replaces the 5-second chunk timer; mic path is completely untouched
**Depends on**: Phase 6
**Requirements**: PIPE-05
**Plans**: 1/1 complete

Plans:

- [x] 07-01-PLAN.md — Streaming onSystemBatch callback, format validation, MeetingRecorder wiring

#### Phase 8: MeetingRecorder Pipeline Rewire

**Goal**: The full end-to-end pipeline is connected — SpeakerBufferManager dispatches ASR through TranscriptionQueue, MeetingRecorder receives completed segments with correct per-speaker attribution, and `activeSpeakerLabel` is published before each ASR result arrives
**Depends on**: Phase 7
**Requirements**: (integration phase — all Phase 6+7 requirements exercised end-to-end)
**Plans**: 2/2 complete

Plans:

- [x] 08-01-PLAN.md — Wire buffer consumer loop, TranscriptionQueue overload, activeSpeakerLabel, dead code removal
- [x] 08-02-PLAN.md — Gap closure: system audio fallback when diarizer unavailable

#### Phase 9: Waveform Color Per Speaker

**Goal**: The waveform in the recording bar reflects the active speaker's palette color in real time, using the same color identity as chat bubbles
**Depends on**: Phase 8
**Requirements**: RT-01, RT-02, RT-03
**Plans**: 5/5 complete ✅ Battle-tested 2026-03-23

Plans:

- [x] 09-00-PLAN.md — Wave 0 test stubs (SharedViewsTests, WaveformHistoryTests, SpeakerResolutionTests)
- [x] 09-01-PLAN.md — Color+Hex extension, hex palette update, Speaker(displayName:) init
- [x] 09-02-PLAN.md — Canvas waveform rewrite with per-bar speaker color history and -50dB noise floor scaling
- [x] 09-03-PLAN.md — Gap closure: fix Me-channel hardcoded color, dB noise floor scaling, strengthen tests
- [x] 09-04-PLAN.md — Gap closure: set activeSpeakerLabel to Me in microphone onAudioChunk path

</details>

---

### 🚧 v1.2 Live Enrichment & Diarization Fix (In Progress)

**Milestone Goal:** Transcription is immediate (tokens render as they're decoded), diarization is async and precise (5-10s micro-windows instead of 30s batches), and speaker attribution is retroactively enriched in the UI via a Reconciler. Chat Bubble UI is built on this new reactive foundation.

**Architecture:** Immediate Render + Async Enrichment — text appears instantly under `[Me]`/`[Pending]`, diarizer metadata arrives later and patches speaker labels without blocking the transcript stream.

#### Phase 10: Mutable Data Model + Diarizer Micro-Windows

**Goal**: `MeetingSegment` becomes a reactive mutable model that supports retroactive speaker updates; diarizer is restored with 5-10s micro-windows (replacing the disabled 30s batch mode), eliminating speaker blending
**Depends on**: Phase 9
**Requirements**: MUT-01, MUT-02, MUT-03, DIAR-01, DIAR-02
**Success Criteria** (what must be TRUE):

1. `MeetingSegment` exposes `@Published var speakerLabel: String` — updating it from any context propagates to the transcript UI without a full view reload
2. Diarizer micro-window size is configurable (default 7s); the 30s cap remains as a hard ceiling
3. Speaker blending (two speakers sharing one segment due to a late flush) is eliminated — speaker changes trigger a segment boundary within the 7s window
4. Existing `MeetingSession`, `MeetingStorage`, and `MeetingDetailView` compile and round-trip without modification
5. `swift test` passes with no regressions to existing test suite
**Plans**: 2/2 complete

Plans:
- [x] 10-01-PLAN.md — @Observable MeetingSegment migration with manual Codable and pending-state API
- [x] 10-02-PLAN.md — SpeakerBufferManager micro-windows (7s default) and diarizer re-enable with pre-ASR split
#### Phase 11: Live Transcription Stream

**Goal**: ASR output is decoupled from the diarizer batch — text tokens render in the UI as they are decoded, attributed to `[Me]` (mic) or `[Pending]` (system) while diarizer catches up in the background
**Depends on**: Phase 10
**Requirements**: LIVE-01, LIVE-02, LIVE-03
**Success Criteria** (what must be TRUE):

1. Mic transcription renders in the live session view within 1 chunk (~0.5s) of ASR decode — no waiting for diarizer confirmation
2. System audio transcription renders immediately under `[Pending]` speaker label; label is replaced by the resolved speaker name when diarizer confirms
3. No audio samples are dropped or duplicated between the fast ASR path and the diarizer micro-window path
4. `swift build` produces zero warnings; no regressions to mic or system audio transcription
**Plans**: 4/4 complete

Plans:
- [x] 11-01-PLAN.md — Wave 0: StreamingTests test scaffold (LIVE-01, LIVE-02, LIVE-03)
- [x] 11-02-PLAN.md — VoiceToTextProtocol.processStream + VoiceToTextModel WhisperKit streaming (LIVE-01)
- [x] 11-03-PLAN.md — Speaker.pending case + displayText/displaySpeaker fixes (LIVE-02)
- [x] 11-04-PLAN.md — MeetingRecorder VoiceToTextFactory wiring + TranscriptSegmentRow fix (LIVE-01, LIVE-02, LIVE-03)

#### Phase 11.1: Audio-Active Pending State (INSERTED)

**Goal**: Implement a multi-stage pending state triggered by voice activity (VAD/energy gate) to provide immediate visual feedback even before ASR tokens arrive
**Depends on**: Phase 11
**Requirements**: PENDING-01, PENDING-02, PENDING-03, VAD-01, VAD-02
**Success Criteria**:
1. Pending segment row appears immediately upon stable voice activity (200-400ms)
2. Segments transition from "audio-active" (no text) to "asr-partial" (streaming tokens) to "final" (confirmed text)
3. Consistent behavior across all STT engines (Parakeet/WhisperKit)
**Plans**: 4/4 complete ✅ Accepted via manual validation 2026-04-19

Plans:
- [x] 11.1-01-PLAN.md — Wave 0: VADStateMachineTests stubs (VAD-01, VAD-02)
- [x] 11.1-02-PLAN.md — VADStateMachine actor + DualChannelAudioCapture.onMicrophoneLevel + SpeakerBufferManager.onSpeechDetected (PENDING-01, VAD-01)
- [x] 11.1-03-PLAN.md — MeetingRecorder VAD wiring, reconciliation, ghost cleanup + MeetingSession.removeSegment (PENDING-01, PENDING-02, PENDING-03, VAD-02)
- [x] 11.1-04-PLAN.md — TranscriptSegmentRow dashed border + TypingIndicator (PENDING-02, PENDING-03)

#### Phase 11.2: True Streaming ASR (INSERTED)

**Goal**: Enable true word-by-word streaming ASR for WhisperKit and Parakeet, bypassing 5-10s batches where possible to provide immediate feedback
**Depends on**: Phase 11.1
**Requirements**: LIVE-04, LIVE-05, LIVE-06
**Success Criteria**:
1. WhisperKit `TranscriptionProgress.text` is used to update the `pending` segment row in real-time
2. Parakeet engine is extended to support similar streaming tokens if possible
3. Latency between speech and first token appearance is < 1s
**Plans**: TBD

#### Phase 12: Chat Bubble UI

**Goal**: MeetingDetailView displays the meeting transcript as iMessage-style grouped chat bubbles — consecutive segments from the same speaker form a single visual group, and speaker labels update in-place when diarizer resolves `[Pending]` attributions
**Depends on**: Phase 10
**Requirements**: CHAT-01, CHAT-02, CHAT-03, CHAT-04
**Success Criteria** (what must be TRUE):

1. Consecutive segments from the same speaker are visually grouped — no repeated name or avatar between bubbles within the group
2. Each group shows the speaker name (or "Me") once at the top and a single timestamp at the bottom of the group
3. "Me" segments are right-aligned; all other speaker segments are left-aligned — matching iMessage visual convention
4. `[Pending]` label resolves visually in-place when Reconciler assigns a speaker — no layout jump or full-list reload
5. The existing flat-list transcript view is fully replaced by the bubble layout; no regression to MeetingDetailView navigation or meeting storage
   **Plans**: TBD

#### Phase 13: Reconciler — Async Speaker Enrichment

**Goal**: A background Reconciler actor listens for diarizer metadata packets and retroactively patches `[Pending]` transcript segments with resolved speaker IDs; segments spanning a speaker boundary are split into two
**Depends on**: Phase 11, Phase 12
**Requirements**: REC-01, REC-02, REC-03
**Success Criteria** (what must be TRUE):

1. Every `[Pending]` segment in the live session receives a resolved speaker label within 2 diarizer windows (~14s) of the audio being captured
2. A segment whose timestamp range spans a speaker-change boundary is split into two segments at the boundary; no text is lost
3. The Reconciler is a standalone actor with a unit-testable interface — speaker enrichment can be tested without live audio
4. Chat Bubble UI groups update correctly after a split or label resolution — no stale groups or duplicate entries
   **Plans**: TBD

---

## Progress

| Phase                                | Milestone | Plans Complete | Status      | Completed  |
| ------------------------------------ | --------- | -------------- | ----------- | ---------- |
| 1. UI Decomposition                  | v1.0      | 3/3            | Complete    | 2026-03-22 |
| 2. ViewModel Extraction              | v1.0      | 4/4            | Complete    | 2026-03-22 |
| 3. SwiftData Migration               | v1.0      | 2/2            | Complete    | 2026-03-22 |
| 4. Test Coverage                     | v1.0      | 3/3            | Complete    | 2026-03-22 |
| 5. Hotkey Fix                        | v1.0      | 2/2            | Complete    | 2026-03-22 |
| 6. SpeakerBufferManager Actor        | v1.1      | 3/3            | Complete    | 2026-03-22 |
| 7. DualChannelAudioCapture Streaming | v1.1      | 1/1            | Complete    | 2026-03-22 |
| 8. MeetingRecorder Pipeline Rewire   | v1.1      | 2/2            | Complete    | 2026-03-22 |
| 9. Waveform Color Per Speaker        | v1.1      | 5/5            | Complete    | 2026-03-23 |
| 10. Mutable Data Model + Diarizer    | v1.2      | 2/2            | Complete    | 2026-04-18 |
| 11. Live Transcription Stream        | v1.2      | 4/4            | Complete    | 2026-04-18 |
| 11.1 Audio-Active Pending State      | v1.2      | 0/4            | Not started | -          |
| 11.2 True Streaming ASR              | v1.2      | 0/TBD          | Not started | -          |
| 12. Chat Bubble UI                   | v1.2      | 0/TBD          | Not started | -          |
| 13. Reconciler — Async Enrichment    | v1.2      | 0/TBD          | Not started | -          |

\* Code complete and focused verification green; warning-clean build remains open carry-over work.

---

_Roadmap created: 2026-03-21_
_v1.1 section added: 2026-03-22 — Speaker Diarization milestone (Phases 6-10)_
