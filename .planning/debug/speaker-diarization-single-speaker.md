---
status: paused
trigger: "Speaker Diarization & ID завжди повертає одного спікера — всі репліки атрибутуються як Speaker 1 або одна особа, незалежно від кількості реальних спікерів у записі."
created: 2026-03-22T00:00:00Z
updated: 2026-03-22T10:00:00Z
---

## Current Focus
<!-- OVERWRITE on each update - reflects NOW -->

hypothesis: clusteringThreshold=0.4 (speakerThreshold=0.48) partially works — some speaker separation observed but not reliable
test: threshold tuning — if too many splits try 0.5, if still merging try 0.35
expecting: a threshold around 0.4–0.5 to reliably separate different human voices
next_action: resume next session — collect real logs showing exact cosine distances returned per chunk, then tune threshold accordingly. Check logs for "new speaker assigned" vs "existing speaker" messages to understand current behavior.

## Symptoms
<!-- Written during gathering, then IMMUTABLE -->

expected: Різні спікери → різні мітки (Speaker 1, Speaker 2...)
actual: Всі репліки атрибутуються одному спікеру
errors: Немає видимих помилок у консолі
reproduction: Запис зустрічі з кількома людьми — у результаті тільки один спікер
started: Ніколи не працювала — feature never worked from the start

## Eliminated
<!-- APPEND only - prevents re-investigating -->

- hypothesis: Regression 1 - "Me" label lost after initial fix
  evidence: resolveSpeaker() did not check source before running diarization. Mic audio got .labeled("Speaker 1") instead of .me. Fixed by adding early return for .microphone source.
  timestamp: 2026-03-22

- hypothesis: Regression 2 - all speakers "Speaker 1" after initial fix
  evidence: Per-chunk diarization runs in isolation per call. speakerId "SPEAKER_00" in every chunk maps to the same speakerLabelMap entry. The real fix for Issue 1 (mic always = .me) also partially helps here because mic no longer consumes "Speaker 1". System audio diarization now uses the same DiarizerManager instance across chunks, so SpeakerManager embeddings persist and raw IDs should be stable within a session. Will require real-world verification.
  timestamp: 2026-03-22

- hypothesis: Diarization model is running but labels are lost in the UI layer
  evidence: DiarizerManager is never instantiated or called anywhere in the app sources
  timestamp: 2026-03-22

- hypothesis: Speaker labels are assigned then overwritten somewhere in the pipeline
  evidence: There is no pipeline - assignment is a simple enum switch on AudioSource
  timestamp: 2026-03-22

## Evidence
<!-- APPEND only - facts discovered -->

- timestamp: 2026-03-22
  checked: DualChannelAudioCapture.swift, AudioSource enum
  found: AudioSource.speaker returns Speaker.me for .microphone and Speaker.other for .system — a static, hardcoded mapping with no diarization
  implication: Speaker identity is determined by which physical channel captured the audio, not by voice analysis

- timestamp: 2026-03-22
  checked: MeetingRecorder.swift processAudioChunk()
  found: MeetingRecorder only calls asrManager.transcribe() (ASR only). No call to DiarizerManager or performCompleteDiarization(). Speaker label is derived from `source.speaker` which maps to .me/.other
  implication: The diarization pipeline is NEVER invoked during recording

- timestamp: 2026-03-22
  checked: MeetingModels.swift Speaker enum
  found: Speaker enum has .me, .other, .unknown — no dynamic "Speaker 1", "Speaker 2" labels. No support for N speakers from diarization output.
  implication: Even if diarization were run, the data model cannot represent more than 2 distinct speakers (Me/Other)

- timestamp: 2026-03-22
  checked: LocalParakeet.swift
  found: loadModel() creates AsrManager (ASR only). No DiarizerManager initialization in any meeting recording path.
  implication: The meeting recorder loads only the ASR model, not the diarizer

- timestamp: 2026-03-22
  checked: FluidAudio DiarizerManager.swift, DiarizerTypes.swift
  found: DiarizerManager.performCompleteDiarization() takes [Float] audio samples and returns DiarizationResult with [TimedSpeakerSegment] each having a speakerId (e.g. "SPEAKER_00", "SPEAKER_01"). Full pipeline is available and functional.
  implication: The capability exists in the library; it just isn't called

- timestamp: 2026-03-22
  checked: ModelStorage.swift, OnboardingView.swift
  found: The app does download DiarizerModels (via DiarizerModels.downloadIfNeeded()). diarizerModelsExist() checks for 2 .mlmodelc files. Models are available after onboarding.
  implication: The models are downloaded but the diarization API is never called during recording

- timestamp: 2026-03-22
  checked: user log output from second test session
  found: For all regular 80000-sample system chunks, logs go directly "processing system chunk" → "created Speaker 1 segment" with NO resolveSpeaker log in between. Only the final 34560-sample chunk hit resolveSpeaker and got "no segments" fallback.
  implication: resolveSpeaker IS being called on line 295 of processAudioChunk. The missing log was because: (a) the first chunk logs "new speaker assigned 'Speaker 1'", (b) all subsequent chunks silently return the existing label via speakerLabelMap hit on line 374 — no log there. This means either diarizer returns same speakerId every chunk (one real speaker) or SpeakerManager is not distinguishing different voices.

- timestamp: 2026-03-22
  checked: FluidAudio DiarizerManager.swift, SpeakerManager.swift, DiarizerTypes.swift
  found: DiarizerManager uses SpeakerManager.assignSpeaker() with speakerThreshold=0.7*1.2=0.84 and embeddingThreshold=0.7*0.8=0.56. SpeakerManager assigns stable IDs across calls using cosine similarity on embeddings. chunkDuration=10s by default.
  implication: The cross-chunk speaker consistency mechanism IS in place. All chunks processed by same DiarizerManager instance share the same SpeakerManager state. If two distinct people speak in separate chunks, they should get different IDs — IF their embeddings differ enough. Detailed logging has been added to see what speakerIds are actually returned per chunk.

- timestamp: 2026-03-22
  checked: DiarizerManager.swift init, SpeakerManager.swift assignSpeaker(), DiarizerTypes.swift DiarizerConfig
  found: DiarizerConfig.default has clusteringThreshold=0.7 → speakerThreshold=0.7*1.2=0.84. SpeakerManager only creates a new speaker when cosine distance >= speakerThreshold (line 136: distance < speakerThreshold → assign to existing). A threshold of 0.84 means voices must be nearly orthogonal to be distinguished. Typical inter-speaker cosine distance is 0.3–0.6, well within 0.84 → all collapse to speaker 1.
  implication: ROOT CAUSE CONFIRMED. Fix: lower clusteringThreshold to ~0.4, giving speakerThreshold=0.48. Inter-speaker distances of >0.48 will then trigger new speaker creation.

- timestamp: 2026-03-22
  checked: MeetingRecorder.swift — clusteringThreshold value applied in DiarizerConfig passed to DiarizerManager init
  found: clusteringThreshold changed from 0.7 to 0.4 (speakerThreshold drops from 0.84 to 0.48). Code committed. User tested real meeting recording.
  implication: PARTIAL improvement — diarization now creates multiple speakers in some recordings but not reliably. Threshold may still need tuning. User reported "стало трошки краще, але ще не все" (got a bit better, but not everything). Session paused at 86% context window.

## Resolution
<!-- OVERWRITE as understanding evolves -->

root_cause: MeetingRecorder never called FluidAudio's DiarizerManager. Speaker attribution was done by audio channel (microphone=Me, system=Other) via a static AudioSource.speaker mapping. The Speaker data model only had two values (.me/.other) — no support for N-speaker dynamic labels. DiarizerManager and performCompleteDiarization() were available in FluidAudio and models were downloadable, but neither was wired into the recording pipeline.

fix: |
  1. MeetingModels.swift — Added Speaker.labeled(String) case with custom Codable (backward-compatible), Hashable, displayName, icon, colorIndex.
  2. MeetingRecorder.swift — Added DiarizerManager property. In startRecording(), load DiarizerModels and initialize DiarizerManager if models exist (falls back gracefully if not). Added resolveSpeaker() that runs performCompleteDiarization() on each chunk and maps raw speakerId ("SPEAKER_00") to stable "Speaker 1", "Speaker 2" labels via speakerLabelMap. processAudioChunk() uses resolveSpeaker() instead of source.speaker.
  3. SharedViews.swift — Added speakerPaletteColor() free function returning distinct colors for .labeled speakers.
  4. MeetingDetailView.swift, MeetingNotesView.swift, MeetingWaveformView.swift — Updated speakerColor switches to call speakerPaletteColor().

verification: |
  Round 1: swift build passed. Human test revealed two regressions:
    1. "Me" label lost - mic audio was going through diarization and getting .labeled("Speaker 1")
    2. All speakers still "Speaker 1" - per-chunk diarization with speakerId map accumulation.
  Round 2 fix: resolveSpeaker() now returns .me immediately for .microphone source before touching DiarizerManager.
    System audio still uses diarization. speakerLabelMap accumulation is correct because the same
    DiarizerManager instance is reused for the entire session (FluidAudio's SpeakerManager maintains
    speaker embeddings across calls). Build passes (swift build). Awaiting re-verification.
  Round 3 threshold fix: clusteringThreshold lowered 0.7 → 0.4 (speakerThreshold 0.84 → 0.48).
    User reported partial improvement — some speaker separation now occurs.
    Verdict: PARTIALLY WORKING. Threshold tuning still needed.
    Next: collect logs with exact cosine distances, tune threshold (try 0.5 if too many splits, try 0.35 if still merging).
files_changed:
  - Sources/MeetingModels.swift
  - Sources/MeetingRecorder.swift
  - Sources/SharedViews.swift
  - Sources/MeetingDetailView.swift
  - Sources/MeetingNotesView.swift
  - Sources/MeetingWaveformView.swift
