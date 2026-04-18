# Phase 10: Mutable Data Model + Diarizer Micro-Windows — Pattern Map

**Mapped:** 2026-04-18
**Files analyzed:** 6 new/modified files + 1 new file (Reconciler)
**Analogs found:** 6 / 7

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `Sources/MeetingModels.swift` | model | CRUD | `Sources/MeetingModels.swift` (self — current struct) | self-migration |
| `Sources/MeetingSession.swift` | service/coordinator | event-driven | `Sources/MeetingSession.swift` (self — @MainActor class) | self-extension |
| `Sources/MeetingStorage.swift` | persistence | CRUD | `Sources/MeetingStorage.swift` (self — ObservableObject) | self-extension |
| `Sources/MeetingDetailView.swift` | component | request-response | `Sources/MeetingDetailView.swift` (self) + `Sources/SharedViews.swift` | self-extension |
| `Sources/SpeakerBufferManager.swift` | service | event-driven | `Sources/SpeakerBufferManager.swift` (self — actor) | self-extension |
| `Sources/MeetingRecorder.swift` | service | streaming | `Sources/MeetingRecorder.swift` (self — @MainActor class) | self-extension |
| `Sources/Reconciler.swift` (NEW) | service/actor | event-driven | `Sources/SpeakerBufferManager.swift` + `Sources/TranscriptionQueue.swift` | role-match |

---

## Pattern Assignments

### `Sources/MeetingModels.swift` — MeetingSegment struct → @Observable class

**Migration target:** Lines 100–126 (current `struct MeetingSegment`).

**Current pattern to replace** (lines 100–126):
```swift
struct MeetingSegment: Identifiable, Codable, Hashable {
    let id: UUID
    let speaker: Speaker
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float

    init(speaker: Speaker, text: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Float = 1.0) {
        self.id = UUID()
        ...
    }
}
```

**Target pattern — @Observable class with manual Codable:**
- Import `Observation` at top of file (already has `Foundation`).
- Annotate with `@Observable` (replaces `ObservableObject`; no `@Published` needed on properties).
- Add `var isPending: Bool` and `var speaker: Speaker` as mutable `var` (was `let`).
- Keep `let id: UUID` as `let` — identity must be stable.
- Implement manual `CodingKeys` + `init(from:)` + `encode(to:)` to avoid `_$observationRegistrar` leakage.
- Drop `Hashable` (class reference identity replaces hash-based equality; or implement manually via `id`).

**Manual Codable pattern — copy from `Sources/MeetingModels.swift` Speaker enum** (lines 15–63):
```swift
// Speaker already shows the correct keyed/singleValue hybrid Codable pattern.
// MeetingSegment's manual Codable should use the simpler keyed-only form:

enum CodingKeys: String, CodingKey {
    case id, speaker, text, startTime, endTime, confidence, isPending
}

required init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id        = try c.decode(UUID.self,         forKey: .id)
    self.speaker   = try c.decode(Speaker.self,      forKey: .speaker)
    self.text      = try c.decode(String.self,       forKey: .text)
    self.startTime = try c.decode(TimeInterval.self, forKey: .startTime)
    self.endTime   = try c.decode(TimeInterval.self, forKey: .endTime)
    self.confidence = try c.decodeIfPresent(Float.self, forKey: .confidence) ?? 1.0
    self.isPending  = try c.decodeIfPresent(Bool.self,  forKey: .isPending)  ?? false
}

func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id,         forKey: .id)
    try c.encode(speaker,    forKey: .speaker)
    try c.encode(text,       forKey: .text)
    try c.encode(startTime,  forKey: .startTime)
    try c.encode(endTime,    forKey: .endTime)
    try c.encode(confidence, forKey: .confidence)
    try c.encode(isPending,  forKey: .isPending)
}
```

**isPending-aware display helpers** — keep `formattedTime` and `duration` computed properties unchanged; add:
```swift
var displayText: String { isPending ? "..." : text }
var displaySpeaker: Speaker { isPending ? .unknown : speaker }
```

**MeetingNote.segments array** (lines 315, 367–374): Change `[MeetingSegment]` to keep array of class references. The `addSegment` mutating func becomes a regular func (class-based, no `mutating`). `MeetingNote` itself remains a `struct` — only `MeetingSegment` migrates to class.

---

### `Sources/MeetingSession.swift` — Segment handling + Reconciler bridge

**Current ObservableObject pattern** (lines 5–15):
```swift
@MainActor
class MeetingSession: ObservableObject {
    @Published private(set) var liveTranscript: [MeetingSegment] = []
```

**Phase 10 changes needed:**
1. `liveTranscript` stays `[MeetingSegment]` but elements are now `@Observable` class instances — SwiftUI ForEach observes each cell independently (no full-list re-render).
2. Add `@MainActor func addPendingSegment(_ segment: MeetingSegment)` — called by Reconciler via `MainActor.run {}`.
3. Add `@MainActor func replaceSegments(removing original: UUID, inserting two: [MeetingSegment])` for split case.

**Existing segment handling pattern to extend** (lines 252–263):
```swift
private func handleNewSegment(_ segment: MeetingSegment, forMeetingId meetingId: UUID) {
    if isActive {
        liveTranscript.append(segment)
        liveTranscript.sort { $0.startTime < $1.startTime }
    }
    storage.addSegment(segment, to: meetingId)
}
```

**Target — emit pending segment early, update later:**
```swift
// Called by MeetingRecorder before ASR starts:
@MainActor func addPendingSegment(_ segment: MeetingSegment) {
    liveTranscript.append(segment)
    liveTranscript.sort { $0.startTime < $1.startTime }
    // Do NOT persist yet — storage.addSegment called after ASR resolves
}

// Called by Reconciler after ASR finishes (updates in-place, no array replacement):
@MainActor func finalizeSegment(id: UUID, text: String, speaker: Speaker) {
    guard let seg = liveTranscript.first(where: { $0.id == id }) else { return }
    withAnimation(.easeInOut) {
        seg.text = text
        seg.speaker = speaker
        seg.isPending = false
    }
    storage.addSegment(seg, to: currentMeetingId!)
}

// Called by Reconciler for split case:
@MainActor func replaceSegment(id: UUID, with newSegments: [MeetingSegment]) {
    guard let index = liveTranscript.firstIndex(where: { $0.id == id }) else { return }
    withAnimation(.easeInOut) {
        liveTranscript.remove(at: index)
        liveTranscript.insert(contentsOf: newSegments, at: index)
    }
    for seg in newSegments {
        storage.addSegment(seg, to: currentMeetingId!)
    }
}
```

**Task/MainActor bridge pattern** — copy from lines 199–219 (existing Task.detached + MainActor.run):
```swift
Task.detached(priority: .userInitiated) { [weak self] in
    guard let self = self else { return }
    await MainActor.run {
        // mutate @Published / @Observable state here
    }
}
```

---

### `Sources/MeetingStorage.swift` — Codable persistence for class-based MeetingSegment

**Current save/load pattern** (lines 181–224):
```swift
private func loadMeetings() {
    guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
    do {
        meetings = try JSONDecoder().decode([MeetingNote].self, from: data)
        ...
    } catch {
        Logger.log("Failed to load meetings: \(error)", log: Logger.general, type: .error)
    }
}

func saveMeetings() {
    do {
        let data = try JSONEncoder().encode(meetings)
        UserDefaults.standard.set(data, forKey: storageKey)
    } catch {
        Logger.log("Failed to save meetings: \(error)", log: Logger.general, type: .error)
    }
}
```

**Phase 10 impact:** No changes needed to `MeetingStorage` if `MeetingSegment`'s manual `Codable` is implemented correctly. `JSONEncoder().encode([MeetingNote])` will call through `MeetingNote.segments: [MeetingSegment]` → `MeetingSegment.encode(to:)` which uses `CodingKeys`. The `_$observationRegistrar` property is NOT encoded because it is not in `CodingKeys`.

**Verify pattern:** The `decode([MeetingNote].self)` call will trigger `MeetingSegment.init(from:)` which returns a new class instance per segment — each loaded meeting gets fresh `@Observable` instances. This is correct.

**addSegment pattern to copy** (lines 45–56) — used by MeetingSession after finalization:
```swift
func addSegment(_ segment: MeetingSegment, to meetingId: UUID) {
    if let index = meetings.firstIndex(where: { $0.id == meetingId }) {
        meetings[index].addSegment(segment)
        if currentMeeting?.id == meetingId {
            currentMeeting = meetings[index]
        }
        NotificationCenter.default.post(name: .meetingSegmentAdded, object: segment)
    }
}
```

---

### `Sources/MeetingDetailView.swift` — ForEach with @Observable class segments

**Current ForEach pattern** (lines 444–447):
```swift
ForEach(currentMeeting.segments) { segment in
    TranscriptSegmentRow(segment: segment)
}
```

**Phase 10 change:** `MeetingSegment` is now a class. SwiftUI's `ForEach` with `Identifiable` class references will automatically observe each `@Observable` instance individually. No structural change needed to the `ForEach` call.

**TranscriptSegmentRow binding pattern** (lines 668–699):
```swift
struct TranscriptSegmentRow: View {
    let segment: MeetingSegment  // class reference — SwiftUI tracks @Observable
    ...
}
```
When `segment.isPending == true`, row should show `"..."` and a neutral gray color instead of the speaker name and speaker color. Pattern for conditional display:
```swift
// In TranscriptSegmentRow.body:
Text(segment.isPending ? "..." : segment.text)
    .foregroundColor(segment.isPending ? .gray : .white.opacity(0.9))

Text(segment.isPending ? "•••" : segment.speaker.displayName)
    .foregroundColor(segment.isPending ? .gray : speakerPaletteColor(segment.speaker))
```

**Animation pattern** — copy `withAnimation(.easeInOut)` from tab bar (lines 254–257):
```swift
withAnimation(.easeInOut(duration: 0.2)) {
    selectedTab = tab
}
```
Apply same pattern in MeetingSession.finalizeSegment and replaceSegment as shown above.

**Live transcript panel** (`MeetingNotesView` or inline in MeetingDetailView if added) should use the same `ForEach(session.liveTranscript)` pattern with `TranscriptSegmentRow`.

---

### `Sources/SpeakerBufferManager.swift` — Micro-window configuration

**Current configuration constants** (lines 62–64):
```swift
self.maxSamplesPerBuffer = sampleRate * 30   // 30 seconds
self.minSamplesPerBuffer = sampleRate / 2    // 0.5 seconds
```

**Phase 10 change:** Add a 7-second micro-window parameter. The existing `pollingInterval` init parameter pattern (line 59) shows the right approach:
```swift
init(
    diarizer: any DiarizationProvider,
    sampleRate: Int = 16_000,
    pollingInterval: UInt64 = 150_000_000,
    microWindowSeconds: Int = 7          // NEW: Phase 10 default
) {
    self.microWindowSamples = sampleRate * microWindowSeconds
    self.maxSamplesPerBuffer = sampleRate * 30
    self.minSamplesPerBuffer = sampleRate / 2
    ...
}
```

**Pre-ASR split pattern** — copy Array slicing from `accumulateSystemFallback` (lines 315–318 in MeetingRecorder.swift):
```swift
// Already established pattern for fixed-size slicing:
let chunk = Array(systemFallbackBuffer.prefix(chunkSampleCount))
systemFallbackBuffer.removeFirst(chunkSampleCount)
```
Apply same for sample-accurate split at speaker-change offset `T`:
```swift
func splitBuffer(_ samples: [Float], atSeconds offset: Double) -> ([Float], [Float]) {
    let splitIndex = min(Int(offset * Double(sampleRate)), samples.count)
    return (Array(samples.prefix(splitIndex)), Array(samples.dropFirst(splitIndex)))
}
```

**AsyncStream yield pattern** (lines 176–188) — copy for micro-window emission:
```swift
continuation?.yield(closed)
bufferStartTime += Double(maxSamplesPerBuffer) / Double(sampleRate)
accumulatedSamples = overflow
```

**Polling loop pattern** (lines 91–100):
```swift
func start() {
    guard pollingTask == nil else { return }
    pollingTask = Task {
        while !Task.isCancelled {
            pollDiarizer()
            do {
                try await Task.sleep(nanoseconds: pollingInterval)
            } catch {
                break
            }
        }
    }
}
```

---

### `Sources/MeetingRecorder.swift` — Early emission integration

**Current segment creation point** (lines 388–396):
```swift
let segment = MeetingSegment(
    speaker: speaker,
    text: newText,
    startTime: startTime,
    endTime: endTime,
    confidence: 0.95
)
segmentCount += 1
transcriptCallback?(segment)
```

**Phase 10 target — emit pending BEFORE ASR:**
```swift
// 1. Create pending segment immediately (before ASR call):
let pendingSegment = MeetingSegment(
    speaker: source.speaker,
    text: "",
    startTime: startTime,
    endTime: startTime + chunkDuration,
    confidence: 0.0,
    isPending: true          // new property
)
await MainActor.run { transcriptCallback?(pendingSegment) }

// 2. Run ASR (slow):
let transcriptionResult = try await asrManager.transcribe(tempURL)

// 3. Update segment in-place (Reconciler or direct callback):
await MainActor.run {
    pendingSegment.text = newText
    pendingSegment.speaker = speaker
    pendingSegment.confidence = 0.95
    pendingSegment.isPending = false
}
```

**Error handling pattern to copy** (lines 408–411):
```swift
} catch {
    Logger.log("processAudioChunk: error processing \(sourceName): \(error)", log: Logger.general, type: .error)
    lastError = error.localizedDescription
}
```
When ASR fails on a pending segment: set `isPending = false`, `text = "[transcription failed]"`.

**@MainActor isolation pattern** (lines 110–113):
```swift
Task { @MainActor in
    self.activeSpeakerLabel = source == .microphone ? Speaker.me.displayName : ""
}
```
Use this same pattern for all pending-segment mutations from background tasks.

---

### `Sources/Reconciler.swift` (NEW) — Background actor for async updates

**No direct analog exists.** Closest structural patterns come from two existing actors:

**Actor declaration pattern** — copy from `Sources/SpeakerBufferManager.swift` (lines 9, 34–35):
```swift
actor Reconciler {
    private let session: MeetingSession   // held as nonisolated reference to call @MainActor methods

    init(session: MeetingSession) {
        self.session = session
    }
}
```

**Background-to-MainActor dispatch pattern** — copy from `Sources/MeetingSession.swift` (lines 199–219):
```swift
// Inside Reconciler actor:
func process(pendingSegment: MeetingSegment, samples: [Float], startTime: TimeInterval) async {
    // Work happens inside actor isolation (background thread):
    let result = try? await runASR(samples: samples)

    // Push updates to main thread:
    await MainActor.run {
        if let text = result?.text {
            session.finalizeSegment(id: pendingSegment.id, text: text, speaker: resolvedSpeaker)
        } else {
            session.finalizeSegment(id: pendingSegment.id, text: "[failed]", speaker: pendingSegment.speaker)
        }
    }
}
```

**Sendable closure pattern for callbacks** — copy from `Sources/TranscriptionQueue.swift` (lines 16–18):
```swift
processor: @escaping @MainActor (AudioSource, [Float], TimeInterval) async -> Void
```
Reconciler's public API should accept `@Sendable` async closures or use structured concurrency (Task groups) — consistent with `TranscriptionQueue` design.

**Task cancellation / drain pattern** — copy from `Sources/TranscriptionQueue.swift` (lines 65–69):
```swift
func drain() async {
    while isProcessing || !pendingRequests.isEmpty {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
```

---

## Shared Patterns

### @MainActor class singleton
**Source:** `Sources/MeetingSession.swift` lines 5–8, `Sources/MeetingStorage.swift` lines 4–7
**Apply to:** Any new classes that own published UI state
```swift
@MainActor
class Foo: ObservableObject {
    static let shared = Foo()
    private init() { ... }
}
```
**Note for Phase 10:** `MeetingSession` and `MeetingStorage` remain `ObservableObject` (they own the array, not the items). Only `MeetingSegment` migrates to `@Observable`.

### Actor isolation with @unchecked Sendable bridge
**Source:** `Sources/DiarizationProvider.swift` lines 18–19
**Apply to:** `Reconciler` if it holds a reference to any FluidAudio type
```swift
extension SomeForeignClass: @unchecked Sendable {}
```

### Error enum with LocalizedError
**Source:** `Sources/MeetingRecorder.swift` lines 556–582
**Apply to:** `Reconciler`, any new service types
```swift
enum ReconcilerError: LocalizedError {
    case segmentNotFound(UUID)
    case asrFailed(String)

    var errorDescription: String? {
        switch self {
        case .segmentNotFound(let id): return "Segment \(id) not found"
        case .asrFailed(let msg):      return "ASR failed: \(msg)"
        }
    }
}
```

### Logger.log pattern
**Source:** Throughout `Sources/MeetingRecorder.swift` and `Sources/SpeakerBufferManager.swift`
**Apply to:** All new types
```swift
Logger.log("Description: \(value)", log: Logger.general)
Logger.log("Error: \(error)", log: Logger.general, type: .error)
```

### withAnimation(.easeInOut) for state transitions
**Source:** `Sources/MeetingDetailView.swift` lines 254–257
**Apply to:** All pending→resolved segment visual transitions
```swift
withAnimation(.easeInOut(duration: 0.2)) {
    segment.isPending = false
    segment.text = finalText
}
```

### Speaker Codable — keyed + singleValue hybrid
**Source:** `Sources/MeetingModels.swift` lines 19–63
**Apply to:** Any new speaker-typed model fields — backward-compatible decode supports both old String format and new keyed format.

---

## No Analog Found

| File | Role | Data Flow | Reason |
|---|---|---|---|
| `Sources/Reconciler.swift` | actor/service | event-driven | No standalone reconciler actor exists; patterns assembled from `SpeakerBufferManager` + `TranscriptionQueue` + `MeetingSession` |

---

## Metadata

**Analog search scope:** `Sources/` directory (55 Swift files)
**Files read:** MeetingModels.swift, MeetingSession.swift, MeetingStorage.swift, MeetingDetailView.swift, MeetingRecorder.swift, SpeakerBufferManager.swift, DiarizationProvider.swift, TranscriptionQueue.swift, SharedViews.swift
**@Observable usage in codebase:** None yet — Phase 10 is the first introduction
**Pattern extraction date:** 2026-04-18
