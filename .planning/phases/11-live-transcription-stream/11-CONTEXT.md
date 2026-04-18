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
- **D-07:** Architectural Alignment: `MeetingRecorder` ПОВИНЕН використовувати `VoiceToTextFactory` замість прямого виклику `LocalParakeet.loadModel()`, щоб вибір WhisperKit у налаштуваннях став робочим для запису зустрічей.
- **D-08:** Protocol Extension: `VoiceToTextProtocol` розширюється методом `processStream` (або аналогічним), який приймає callback для передачі токенів.
- **D-09:** Decoupling: `MeetingRecorder` тепер не чекає завершення всього сегмента, а починає стрімінг токенів через оновлений `VoiceToTextProtocol`.
- **D-10:** No Deduplication: Відмова від `extractNewText` для Live-шляху. Текст просто додається до кінця сегмента, оскільки стрімінг природно видає послідовність.

### [BEHAVIOR] Corrections
- **D-09:** On-the-fly Correction: Дозволяємо тексту "мерехтіти" (змінюватися), поки Whisper уточнює контекст останнього речення.

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
- `Sources/MeetingRecorder.swift` — Transcription ingress points
- `Sources/MeetingModels.swift` — `MeetingSegment` definition
- `Sources/TranscriptionQueue.swift` — Serialized CoreML execution
- `Sources/LocalWhisperKit.swift` — ASR engine interface

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
