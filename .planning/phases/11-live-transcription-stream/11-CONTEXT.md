# Phase 11: Live Transcription Stream - Context

**Gathered:** 2026-04-18
**Status:** Ready for planning

<domain>
## Phase Boundary

Дана фаза відповідає за миттєве відображення тексту (токенів) в UI під час декодування ASR, не чекаючи завершення всього чанку або підтвердження діарізатора.

</domain>

<decisions>
## Implementation Decisions

### [UX] Token Streaming (Live Feedback)
- **D-01:** Прямий стрімінг токенів. Як тільки WhisperKit видає новий токен — він миттєво додається в `MeetingSegment.text`.
- **D-02:** Анімація відсутня на цьому етапі. Текст просто з'являється ("стрибає"), забезпечуючи максимальну продуктивність.

### [UI] Visual States & Labels
- **D-03:** Колір тексту: Поки чанк декодується (`isPending = true`), текст відображається сірим (Secondary/Tertiary). Після завершення чанку — перемикається на Primary.
- **D-04:** Мікрофон: Відразу маркується як `[Me]`.
- **D-05:** Системний звук: Отримує тимчасову мітку `[Pending]` до моменту асинхронної обробки діарізатором (у Фазі 13).

### [ARCH] Queue & Performance
- **D-06:** Sequential Queue: `TranscriptionQueue` залишається послідовною. Одна задача CoreML (Neural Engine) за раз для стабільності на M-чипах.
- **D-07:** Architectural Alignment: `MeetingRecorder` ПОВИНЕН використовувати `VoiceToTextProtocol` (через `VoiceToTextFactory`) в обох методах — `processAudioChunk` (мікрофон) та `transcribeClosedBuffer` (системне аудіо) — замість прямих викликів `asrManager.transcribe()`.
- **D-08:** Protocol Extension: `VoiceToTextProtocol` розширюється методом `processStream` (або аналогічним), який приймає callback для передачі токенів.
- **D-09:** Decoupling: `MeetingRecorder` тепер не чекає завершення всього сегмента, а починає стрімінг токенів через оновлений `VoiceToTextProtocol`.
- **D-10:** No Deduplication: Відмова від `extractNewText` для Live-шляху. Текст просто додається до кінця сегмента, оскільки стрімінг природно видає послідовність.
- **D-14:** Callback Lifecycle: Кожен `MeetingSegment` має бути переданий у `transcriptCallback` ВІДРАЗУ після створення в `isPending` стані, щоб UI міг підписатися на оновлення його властивостей (`text`, `isPending`).

### [BEHAVIOR] Corrections
- **D-09:** On-the-fly Correction: Дозволяємо тексту "мерехтіти" (змінюватися), поки Whisper уточнює контекст останнього речення.
- **D-11:** Display Logic Fix: `MeetingSegment.displayText` ПОВИНЕН показувати `text`, якщо він не порожній, навіть при `isPending = true`. Логіка: `text.isEmpty ? "..." : text`. Це дозволяє бачити токени в реальному часі.
- **D-12:** Pending Speaker State: Додати `case pending` до enum `Speaker`. При `isPending = true`, метод `displaySpeaker` має повертати:
  - `.me` — для мікрофона (визначається відразу).
  - `.pending` — для системного звуку (до моменту вирішення діарізатором).
- **D-13:** View Implementation Fix: ПОВИННО бути видалено hardcoded логіку `segment.isPending ? "..." : segment.text` у `TranscriptSegmentRow` (`MeetingDetailView.swift`). Натомість використовувати виклики `segment.displaySpeaker.displayName` та `segment.displayText`.

- **D-15:** Dead Code Removal: Видалити з `MeetingRecorder` мертвий код після міграції на `VoiceToTextFactory`: поле `asrManager: AsrManager?`, множину `processedMicTexts: Set<String>` та метод `extractNewText(_:for:)` (замінений D-10).

### Claude's Discretion
- Вибір конкретної реалізації callback-інтерфейсу в `VoiceToTextProtocol`.
- Деталі візуального "dimming" ефекту для тексту в стані очікування.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Core Docs
- `.planning/ROADMAP.md` — Phase 11 goal and requirements
- `.planning/phases/10-mutable-data-model/10-CONTEXT.md` — Observable segments logic

### Source Code
- `Sources/MeetingRecorder.swift` — Transcription ingress points (D-07, D-14)
- `Sources/MeetingModels.swift` — `MeetingSegment` & `Speaker` definitions (D-11, D-12)
- `Sources/MeetingDetailView.swift` — `TranscriptSegmentRow` UI (D-13)
- `Sources/VoiceToTextFactory.swift` — STT engine dispatch (D-07)
- `Sources/VoiceToTextProtocol.swift` — Streaming interface definition (D-08)
- `Sources/VoiceToTextModel.swift` — WhisperKit streaming (D-08)
- `Sources/ParakeetVoiceToTextModel.swift` — Parakeet streaming (D-08)
- `Sources/TranscriptionQueue.swift` — Serialized CoreML execution (D-06)
- `Sources/LocalWhisperKit.swift` — ASR engine interface (D-08)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `MeetingSegment` (@Observable): дозволяє оновлювати `text` без перемалювання всього списку.
- `TranscriptionQueue`: гарантує відсутність паралельних запитів до Neural Engine.

### Integration Points
- `MeetingRecorder.processAudioChunk`: місце, де починається транскрипція мікрофона.
- `MeetingSession.liveTranscript`: масив, куди додаються нові сегменти.

</code_context>

<specifics>
## Specific Ideas
- "Слова мають з'являтися по одному. Це створює відчуття 'магії'."
- "Сірий текст для [Pending] станів достатньо інформативний і не відволікає."

</specifics>

<deferred>
## Deferred Ideas
- **Phase 12:** Групування баблів (iMessage style).
- **Phase 13:** Reconciler для асинхронного розбиття баблів при зміні спікера.

</deferred>

---

*Phase: 11-live-transcription-stream*
*Context gathered: 2026-04-18*
