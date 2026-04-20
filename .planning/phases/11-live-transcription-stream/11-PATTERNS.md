# Phase 11: Live Transcription Stream - Pattern Map

**Mapped:** 2026-04-18
**Files analyzed:** 6
**Analogs found:** 6 / 6

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `Sources/VoiceToTextProtocol.swift` | protocol | streaming | `Sources/VoiceToTextProtocol.swift` (existing, to be extended) | self |
| `Sources/VoiceToTextModel.swift` | service | streaming | `Sources/ParakeetVoiceToTextModel.swift` | exact role-match |
| `Sources/ParakeetVoiceToTextModel.swift` | service | streaming | `Sources/VoiceToTextModel.swift` | exact role-match |
| `Sources/MeetingModels.swift` | model | event-driven | `Sources/MeetingModels.swift` (existing, to be modified) | self |
| `Sources/MeetingRecorder.swift` | service | event-driven | `Sources/MeetingRecorder.swift` (existing, to be refactored) | self |
| `Sources/MeetingDetailView.swift` | component | request-response | `Sources/MeetingDetailView.swift` (existing, bug fix) | self |

---

## Pattern Assignments

### `Sources/VoiceToTextProtocol.swift` (protocol, streaming)

**Analog:** `Sources/VoiceToTextProtocol.swift` (current file — extend it, do not replace)

**Current protocol** (lines 1-10 of existing file):
```swift
import Foundation

/// Protocol defining the interface for audio transcription
protocol VoiceToTextProtocol {
    /// Transcribe an audio file to text
    /// - Parameter filepath: The path to the audio file (m4a format)
    /// - Returns: The transcribed text
    /// - Throws: TranscriptionError if the transcription fails
    func process(filepath: String) async throws -> String
}
```

**Addition pattern — add streaming method below the existing `process` declaration:**
```swift
/// Transcribe an audio file to text with streaming token callback.
/// - Parameters:
///   - filepath: Path to the audio file.
///   - onToken: Called on the MainActor each time new partial text is available.
///              Receives the cumulative text decoded so far.
/// - Returns: The final complete transcription string.
/// - Throws: TranscriptionError if the transcription fails.
func processStream(filepath: String, onToken: @escaping @MainActor (String) -> Void) async throws -> String
```

**Default implementation pattern** (add in a protocol extension so both conformers have a no-op fallback):
```swift
extension VoiceToTextProtocol {
    /// Default: delegates to `process` without streaming.
    func processStream(filepath: String, onToken: @escaping @MainActor (String) -> Void) async throws -> String {
        let result = try await process(filepath: filepath)
        await MainActor.run { onToken(result) }
        return result
    }
}
```

---

### `Sources/VoiceToTextModel.swift` (service, streaming)

**Analog:** `Sources/VoiceToTextModel.swift` (current file — add `processStream`) and `Sources/ParakeetVoiceToTextModel.swift` (same class skeleton pattern)

**Imports pattern** (lines 1-3 of existing file — keep as-is):
```swift
import Foundation
import WhisperKit
```

**Class skeleton pattern** (lines 4-21 — keep as-is):
```swift
class VoiceToTextModel: VoiceToTextProtocol {
    static let shared = VoiceToTextModel()
    private var pipe: WhisperKit?

    private init() { self.pipe = nil }

    func load() async throws {
        if self.pipe == nil {
            self.pipe = try await LocalWhisperKit.loadModel(
                modelRepo: CurrentSTTModelRepo,
                modelName: CurrentSTTModelName
            )
        }
        if self.pipe == nil {
            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load voice-to-text model."])
        }
    }
    // ...
}
```

**Existing `process` method** (lines 24-56 — unchanged reference):
```swift
func process(filepath: String) async throws -> String {
    try await load()
    let language = SettingsStore.shared.language
    let languageCode = language == "auto" ? nil : language
    let ts = TimeSpenter()

    let results = try await pipe!.transcribe(
        audioPath: filepath,
        decodeOptions: DecodingOptions(
            language: languageCode,
            usePrefillPrompt: true,
            detectLanguage: language == "auto"
        )
    )
    let transcription = results.first?.text
    // ...
    return transcription!
}
```

**New `processStream` method — copy this pattern into `VoiceToTextModel`:**
```swift
func processStream(filepath: String, onToken: @escaping @MainActor (String) -> Void) async throws -> String {
    try await load()

    let language = SettingsStore.shared.language
    let languageCode = language == "auto" ? nil : language

    if GenericHelper.logSensitiveData() {
        Logger.log("WhisperKit streaming transcription started", log: Logger.general)
    }
    let ts = TimeSpenter()

    let results = try await pipe!.transcribe(
        audioPath: filepath,
        decodeOptions: DecodingOptions(
            language: languageCode,
            usePrefillPrompt: true,
            detectLanguage: language == "auto"
        )
    ) { progress in
        // progress.segments contains cumulative decoded segments
        let currentText = progress.segments.map { $0.text }.joined()
        Task { @MainActor in
            onToken(currentText)
        }
        return true  // return false to abort early
    }

    let transcription = results.first?.text ?? ""
    if GenericHelper.logSensitiveData() {
        Logger.log("WhisperKit streaming done in \(ts.getDelay()) us", log: Logger.general)
    }
    if transcription.isEmpty {
        throw NSError(domain: "Transcriber", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "No transcription result received"])
    }
    return transcription
}
```

**Key note:** The callback closure passed to `pipe!.transcribe` returns `Bool`. `true` continues decoding; `false` aborts. Always `return true` for live streaming.

---

### `Sources/ParakeetVoiceToTextModel.swift` (service, streaming)

**Analog:** `Sources/VoiceToTextModel.swift` (same service skeleton pattern — mirror the `processStream` addition)

**Current class skeleton** (lines 4-59 — keep unchanged):
```swift
class ParakeetVoiceToTextModel: VoiceToTextProtocol {
    static let shared = ParakeetVoiceToTextModel()
    private var manager: AsrManager?

    private init() { self.manager = nil }

    func load() async throws { /* ... */ }

    func process(filepath: String) async throws -> String {
        try await load()
        // ...
        let audioURL = URL(fileURLWithPath: filepath)
        let result = try await manager.transcribe(audioURL)
        let transcription = result.text
        // ...
        return transcription
    }
}
```

**New `processStream` method for Parakeet — FluidAudio does not expose a token-level streaming callback via the URL-based `transcribe(_:)` API. Use the protocol extension default (delegates to `process`, then fires `onToken` once at the end):**
```swift
// No override needed — protocol extension default provides the fallback:
// func processStream(...) { let r = try await process(...); await MainActor.run { onToken(r) }; return r }
```

**Rationale:** The `StreamingEouAsrManager` in FluidAudio requires raw audio buffers fed incrementally, not a pre-written WAV file. Since `MeetingRecorder` passes a file path (WAV), Parakeet fires its `onToken` once with the final text. This is acceptable per D-08 (the protocol only requires the method exist; quality of streaming is engine-specific).

---

### `Sources/MeetingModels.swift` (model, event-driven)

**Analog:** `Sources/MeetingModels.swift` (modify in-place)

**Existing `Speaker` enum** (lines 9-98 — add one case):
```swift
enum Speaker: Codable, Hashable {
    case me
    case other
    case unknown
    case labeled(String)
    // ADD:
    case pending   // system audio awaiting diarization result (Phase 13)
}
```

**Pattern for adding `pending` to Codable decode** — mirror existing `case` switches:
```swift
// In init(from decoder:), keyed container branch:
case "pending": self = .pending

// In encode(to encoder:):
case .pending:
    var c = encoder.singleValueContainer(); try c.encode("Pending")
```

**Pattern for adding `pending` to `displayName` / `icon` / `colorIndex`** — follow existing switch exhaustiveness:
```swift
var displayName: String {
    // ...
    case .pending: return "Pending"
}

var icon: String {
    // ...
    case .pending: return "ellipsis.circle"
}

var colorIndex: Int {
    // ...
    case .pending: return 8
}
```

**Fix `displayText` on `MeetingSegment`** (lines 138-140 — current broken logic):
```swift
// CURRENT (wrong — hides tokens during live decoding):
var displayText: String {
    isPending ? "..." : text
}

// REPLACE WITH (D-11 fix — show tokens as they arrive):
var displayText: String {
    text.isEmpty ? "..." : text
}
```

**Fix `displaySpeaker` on `MeetingSegment`** (lines 142-144 — current broken logic):
```swift
// CURRENT (wrong — always returns .unknown for pending segments, even mic):
var displaySpeaker: Speaker {
    isPending ? .unknown : speaker
}

// REPLACE WITH (D-12 fix — mic is always .me; system audio is .pending):
var displaySpeaker: Speaker {
    guard isPending else { return speaker }
    // Mic channel is known immediately; system channel waits for diarizer
    return speaker == .me ? .me : .pending
}
```

---

### `Sources/MeetingRecorder.swift` (service, event-driven)

**Analog:** `Sources/MeetingRecorder.swift` (refactor in-place — existing patterns copied below as reference for what changes)

**Dead code to REMOVE** (per D-15):

1. Field at line 32: `private var asrManager: AsrManager?`
2. Field at line 46: `private var processedMicTexts: Set<String> = []`
3. Method at lines 547-571: `private func extractNewText(_ fullText: String, for source: AudioSource) -> String`
4. Reset in `startRecording` at line 185: `processedMicTexts = []`
5. Reset in `cleanup()` at line 309: `processedMicTexts = []`
6. Reset in `cleanup()` at line 310: `asrManager = nil`
7. ASR model load block in `startRecording` (lines 85-90):
```swift
// REMOVE:
do {
    asrManager = try await LocalParakeet.loadModel()
} catch {
    Logger.log("Failed to load ASR model: \(error)", log: Logger.general, type: .error)
    throw MeetingRecorderError.modelLoadFailed(error.localizedDescription)
}
```

**New field to ADD** (replaces `asrManager`):
```swift
// Add after transcriptionQueue declaration (line 49 area)
private var voiceToText: VoiceToTextProtocol?
```

**Load pattern to ADD** in `startRecording` (replaces removed Parakeet load block):
```swift
// Load via factory (respects user's sttEngine setting)
voiceToText = await VoiceToTextFactory.createVoiceToText()
```

**`processAudioChunk` — streaming wiring pattern** (replaces `asrManager.transcribe(tempURL)` at line 419):

The existing segment creation and `transcriptCallback?` call (lines 394-404) are already correct — keep them. Replace only the transcription call:

```swift
// REMOVE:
let transcriptionResult = try await asrManager.transcribe(tempURL)

// REPLACE WITH (D-07, D-09, D-10):
guard let voiceToText = voiceToText else {
    Logger.log("processAudioChunk: voiceToText not available", log: Logger.general, type: .error)
    return
}

let transcriptionText = try await voiceToText.processStream(
    filepath: tempURL.path
) { [weak pendingSegment] partialText in
    // Token callback — update segment text in real-time (D-01, D-10)
    pendingSegment?.text = partialText
}
```

**`processAudioChunk` — remove deduplication block** (lines 428-435, per D-10):
```swift
// REMOVE extractNewText call and guard:
let newText = extractNewText(normalizedText, for: source)
guard !newText.isEmpty else {
    await MeetingSession.shared.replaceSegment(id: pendingSegment.id, with: [])
    Logger.log(...)
    return
}

// REMOVE processedMicTexts.insert (line 442):
if source == .microphone {
    processedMicTexts.insert(newText)
}
```

**`transcribeClosedBuffer` — streaming wiring pattern** (replaces `asrManager.transcribe(tempURL)` at line 504):
```swift
// REMOVE:
let transcriptionResult = try await asrManager.transcribe(tempURL)

// REPLACE WITH (D-07, D-09):
guard let voiceToText = voiceToText else {
    Logger.log("transcribeClosedBuffer: voiceToText not available", log: Logger.general, type: .error)
    return
}

let transcriptionText = try await voiceToText.processStream(
    filepath: tempURL.path
) { [weak pendingSegment] partialText in
    pendingSegment?.text = partialText
}
```

**Guard pattern for empty transcription** — copy from existing error-handling pattern (lines 421-425, 506-510) and apply to `transcriptionText`:
```swift
guard !transcriptionText.isEmpty else {
    Logger.log("processAudioChunk: empty transcription from \(sourceName)", log: Logger.general)
    await MeetingSession.shared.replaceSegment(id: pendingSegment.id, with: [])
    return
}
let normalizedText = transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
```

**`cleanup()` — remove asrManager nil reset, keep voiceToText**:
```swift
// In cleanup(), replace:
asrManager = nil
// WITH:
voiceToText = nil
```

**Existing `pendingSegment` creation and callback pattern** (lines 394-404) — preserve unchanged, this is the D-14 lifecycle anchor:
```swift
let pendingSegment = MeetingSegment(
    speaker: source.speaker,
    text: "",
    startTime: startTime,
    endTime: endTime,
    confidence: 0,
    isPending: true
)
segmentCount += 1
transcriptCallback?(pendingSegment)  // UI subscribes immediately
```

**`guard asrManager` patterns** — replace all `guard let asrManager = asrManager` guards with:
```swift
guard let voiceToText = voiceToText else {
    Logger.log("<method>: voiceToText not available", log: Logger.general, type: .error)
    return
}
```

---

### `Sources/MeetingDetailView.swift` (component, request-response)

**Analog:** `Sources/MeetingDetailView.swift` (fix in-place — `TranscriptSegmentRow` only)

**Current `TranscriptSegmentRow`** (lines 668-699 — shows hardcoded pending logic):
```swift
struct TranscriptSegmentRow: View {
    let segment: MeetingSegment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(segment.formattedTime)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 40)

            // WRONG — hardcoded "•••" and bypasses displaySpeaker:
            Text(segment.isPending ? "•••" : segment.speaker.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(segment.isPending ? .gray : speakerColor)
                .frame(width: 50)

            // WRONG — hardcoded "..." and bypasses displayText:
            Text(segment.isPending ? "..." : segment.text)
                .font(.system(size: 14))
                .foregroundColor(segment.isPending ? .secondary : .white.opacity(0.9))
                .textSelection(.enabled)
        }
        .padding(12)
        .background(Color.white.opacity(0.02))
        .cornerRadius(8)
    }

    private var speakerColor: Color {
        speakerPaletteColor(segment.speaker)
    }
}
```

**Fixed `TranscriptSegmentRow`** (D-13 — delegate to model methods):
```swift
struct TranscriptSegmentRow: View {
    let segment: MeetingSegment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(segment.formattedTime)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 40)

            // Use displaySpeaker — returns .me for mic, .pending for unresolved system
            Text(segment.displaySpeaker.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(segment.isPending ? .gray : speakerColor)
                .frame(width: 50)

            // Use displayText — returns text if non-empty, "..." otherwise (D-11)
            Text(segment.displayText)
                .font(.system(size: 14))
                .foregroundColor(segment.isPending ? .secondary : .white.opacity(0.9))
                .textSelection(.enabled)
        }
        .padding(12)
        .background(Color.white.opacity(0.02))
        .cornerRadius(8)
    }

    private var speakerColor: Color {
        speakerPaletteColor(segment.displaySpeaker)  // use displaySpeaker for color too
    }
}
```

**Dimming color pattern** — `segment.isPending ? .secondary : .white.opacity(0.9)` is already the right pattern for text dimming (D-03). Keep it as-is in the fixed version.

---

## Shared Patterns

### @Observable Segment Update Pattern
**Source:** `Sources/MeetingRecorder.swift` (lines 394-404) and `Sources/MeetingModels.swift` (lines 101-126)
**Apply to:** `VoiceToTextModel.processStream`, `ParakeetVoiceToTextModel.processStream`, `MeetingRecorder.processAudioChunk`, `MeetingRecorder.transcribeClosedBuffer`

The `MeetingSegment` is `@Observable final class`. Any mutation to `pendingSegment.text` on the `@MainActor` is automatically picked up by SwiftUI without explicit `objectWillChange.send()`. The callback must always run on `@MainActor`:
```swift
Task { @MainActor in
    pendingSegment.text = partialText
}
```
Or if already on `@MainActor` (inside `MeetingRecorder` which is `@MainActor`): direct assignment is safe.

### WAV Temp File Pattern
**Source:** `Sources/MeetingRecorder.swift` (lines 406-413, 479-482)
**Apply to:** Both `processAudioChunk` and `transcribeClosedBuffer` — no change needed here, pattern is correct

```swift
let tempURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("meeting_\(sourceName)_\(UUID().uuidString).wav")
defer {
    try? FileManager.default.removeItem(at: tempURL)
}
```

### Logger Pattern
**Source:** `Sources/VoiceToTextModel.swift` (lines 30-33, 44-46) and `Sources/MeetingRecorder.swift` throughout
**Apply to:** All new method bodies

```swift
if GenericHelper.logSensitiveData() {
    Logger.log("<message with sensitive data>", log: Logger.general)
}
Logger.log("<non-sensitive status>", log: Logger.general)
Logger.log("<error message>", log: Logger.general, type: .error)
```

### Error Propagation Pattern
**Source:** `Sources/MeetingRecorder.swift` (lines 454-463, 537-543)
**Apply to:** `processAudioChunk` and `transcribeClosedBuffer` catch blocks — keep unchanged

```swift
} catch {
    pendingSegment.confidence = 0
    await MeetingSession.shared.finalizeSegment(
        id: pendingSegment.id,
        text: "[transcription failed]",
        speaker: source.speaker  // or speaker variable for closedBuffer path
    )
    Logger.log("<method>: error processing \(sourceName): \(error)", log: Logger.general, type: .error)
    lastError = error.localizedDescription
}
```

### TranscriptionQueue Enqueue Pattern
**Source:** `Sources/TranscriptionQueue.swift` (lines 7-44) and `Sources/MeetingRecorder.swift` (lines 147-156)
**Apply to:** No change needed — queue remains serial (D-06), existing enqueue call sites stay the same

---

## No Analog Found

All 6 files have close analogs in the codebase. No files require falling back to RESEARCH.md patterns exclusively.

| File | Note |
|---|---|
| `VoiceToTextProtocol.swift` | The `processStream` callback signature is novel (no prior streaming protocol exists). Use RESEARCH.md `WhisperKit Streaming Callback` example for the closure's `progress` parameter structure. |

---

## Metadata

**Analog search scope:** `Sources/` directory (all .swift files)
**Files scanned:** 8 source files read in full
**Pattern extraction date:** 2026-04-18
