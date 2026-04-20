---
status: diagnosed
phase: 11-live-transcription-stream
source:
  - 11-01-SUMMARY.md
  - 11-02-SUMMARY.md
  - 11-03-SUMMARY.md
  - 11-04-SUMMARY.md
started: 2026-04-18T20:00:16Z
updated: 2026-04-18T20:22:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Live mic tokens during speech
expected: Start a meeting and speak into the microphone for a few seconds. Text should appear in the transcript while the chunk is still decoding, rather than only after the whole chunk finishes. Speaker label should stay as Me for the mic path.
result: issue
reported: "коли в налаштуваннях вибрано parakeet то ве відпрацьовує, але коли я переключив на WhisperKit то розпізнавання не пішло. відобразилась бульбашка Me і далі нічого. коли я натиснув End Meeting то воно не завершило а \"зависло\" у стані завершення"
severity: blocker

### 2. Silent mic chunk does not show failure
expected: Leave the microphone silent for a chunk window. No persistent `[transcription failed]` row should remain in the transcript, and silence should not be surfaced as an error to the user.
result: blocked
blocked_by: prior-phase
reason: "Parakeet: pass. WhisperKit: cannot verify because Test 1 blocker prevents WhisperKit live transcription from running."

### 3. System audio shows Pending immediately
expected: Play audio from another app while recording. A transcript row should appear promptly with the Pending speaker state before diarization catches up.
result: issue
reported: "ні, у транскріпті зʼявляється вже готовий рядок. поступової зміни тексту нема, не видно процес розпізнавання"
severity: major

### 4. Pending transcript text finalizes cleanly
expected: While a row is pending, text should appear in a dimmed/pending style and then settle into its final non-pending state once the chunk completes, without leaving duplicate rows behind.
result: blocked
blocked_by: prior-phase
reason: "Не можливо перевірити через відсутність pending стану."

### 5. No dropped or duplicated transcript across a mixed session
expected: Record a short mixed session with speech, short pauses, and system audio. The resulting transcript should read continuously without obvious dropped phrases or duplicate repeated chunks.
result: pass

## Summary

total: 5
passed: 1
issues: 2
pending: 0
skipped: 0
blocked: 2

## Gaps

- truth: "Mic speech starts rendering text during chunk decoding and the meeting can still end cleanly with WhisperKit selected."
  status: failed
  reason: "User reported: коли в налаштуваннях вибрано parakeet то ве відпрацьовує, але коли я переключив на WhisperKit то розпізнавання не пішло. відобразилась бульбашка Me і далі нічого. коли я натиснув End Meeting то воно не завершило а \"зависло\" у стані завершення"
  severity: blocker
  test: 1
  root_cause: "WhisperKit streaming in the recorder path is not completing reliably for live mic chunks. `MeetingRecorder.processAudioChunk(...)` waits on `VoiceToTextModel.processStream(...)`, and `MeetingSession.stopMeeting()` waits on `MeetingRecorder.stopRecording()`, which in turn waits for `transcriptionQueue.drain()`. When the WhisperKit task neither yields usable output nor completes in the stop path, the pending `Me` row remains without text and the meeting can stay stuck in `Stopping...`."
  artifacts:
    - path: "Sources/VoiceToTextModel.swift"
      issue: "WhisperKit-specific streaming path is separate from the known-good batch `process(...)` path and lacks a recorder-flow regression test or stop/timeout protection."
    - path: "Sources/MeetingRecorder.swift"
      issue: "`processAudioChunk(...)` awaits STT completion inline and `stopRecording()` blocks on `transcriptionQueue.drain()`, so a stuck WhisperKit task also blocks meeting teardown."
    - path: "Sources/MeetingSession.swift"
      issue: "`stopMeeting()` keeps UI state in `.stopping` until `recorder.stopRecording()` returns."
  missing:
    - "Add a WhisperKit recorder-path regression test or reproducible harness for `processStream(...)` on live meeting chunks."
    - "Guard WhisperKit stop behavior with timeout/cancellation or fallback so `stopRecording()` cannot hang indefinitely on an in-flight streaming transcription."
    - "Verify WhisperKit `processStream(...)` against the recorder WAV chunk format and, if needed, fall back to `process(...)` for WhisperKit until streaming is proven stable."
  debug_session: ""
- truth: "System audio should surface a visible Pending/live-recognition state before diarization catches up."
  status: failed
  reason: "User reported: ні, у транскріпті зʼявляється вже готовий рядок. поступової зміни тексту нема, не видно процес розпізнавання"
  severity: major
  test: 3
  root_cause: "The current system-audio path still starts transcription only after `SpeakerBufferManager` flushes a closed diarized buffer into `MeetingRecorder.transcribeClosedBuffer(...)`. That means there is no immediate pre-diarizer transcript row for system audio. On top of that, the Parakeet `processStream(...)` implementation emits only the final text once, so the user never sees incremental pending text."
  artifacts:
    - path: "Sources/MeetingRecorder.swift"
      issue: "System audio pending rows are created only inside `transcribeClosedBuffer(...)`, which runs after diarizer micro-window flush rather than immediately when system audio arrives."
    - path: "Sources/SpeakerBufferManager.swift"
      issue: "System audio is buffered into diarizer micro-windows first, so the first user-visible row appears only after buffer close."
    - path: "Sources/ParakeetVoiceToTextModel.swift"
      issue: "`processStream(...)` currently forwards only the final transcript once, so there is no visible token-by-token pending state."
  missing:
    - "Introduce an immediate system-audio transcript path that creates a visible pending row before diarizer resolution, then reconcile/update speaker identity later."
    - "Decide whether Phase 11 should support real streaming partials for Parakeet or explicitly degrade to a non-streaming pending UI with accurate expectations."
    - "Add UAT-backed verification for visible Pending state on system audio before diarizer completion."
  debug_session: ""
