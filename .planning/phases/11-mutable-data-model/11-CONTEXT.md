# Context: Phase 11 — Mutable Data Model + Diarizer Micro-Windows

## Phase Goal
Впровадити реактивну модель сегментів та точну діарізацію через 7-секундні мікро-вікна з підтримкою асинхронного оновлення та розбиття сегментів.

## Implementation Decisions

### [MUT] Mutable Data Model
- **Decision:** `MeetingSegment` перетворюється на `@Observable class` (macOS 14+).
- **Identity:** Кожен сегмент має стабільний `id: UUID`.
- **Persistence:** Зберігаємо `Codable` для сумісності з поточним `MeetingStorage`.
- **UI Performance:** Використання класів дозволяє SwiftUI оновлювати лише змінені баблі (60 FPS).

### [DIAR] Diarizer Micro-Windows & Splitting
- **Decision:** Вікна діарізації — **7 секунд** (default).
- **Splitting:** **Pre-ASR Split** (на рівні аудіо). Якщо діарізатор фіксує зміну спікера всередині вікна — буфер розрізається на частини до відправки в Parakeet/Whisper.
- **Rationale:** Гарантує "чисті" сегменти з одним спікером. Спрощує логіку Reconciler-а.

### [UI] Pending State & Visuals
- **Decision:** Сегменти в стані очікування мають **нейтральний сірий колір**.
- **Pending Label:** Замість імені показуємо анімовані три крапки `...` (TimelineView або анімований рядок).
- **Transition:** Перетворення сірого бабла на кольоровий (або розбиття на два) відбувається через `withAnimation(.easeInOut)`.

### [ARCH] Async Reconciliation
- **Decision:** Створити `Reconciler` як фоновий `actor`.
- **Flow:** `Reconciler` отримує дані → знаходить сегмент за UUID → оновлює дані через `@MainActor` метод у `MeetingSession`.
- **Splitting Logic:** При розбитті оригінальний сегмент видаляється, а замість нього вставляються два нових із правильними спікерами.

## Success Criteria
1. `MeetingSegment` реактивно оновлюється в UI без перемальовування всього списку.
2. Діарізатор працює з 7с вікнами та успішно розрізає аудіо при зміні спікера.
3. Користувач бачить плавні анімовані переходи від "..." до готового тексту.
4. Збереження та завантаження зустрічей працює без регресій.

## Next Steps
1. **Research:** Аналіз імплементації `Codable` для `@Observable` класів.
2. **Plan 11-01:** Міграція `MeetingSegment` на клас та впровадження UUID.
3. **Plan 11-02:** Налаштування мікро-вікон у `DiarizerManager`.

## Deferred Ideas
- Повна міграція бази зустрічей на SwiftData (після стабілізації v1.2).
