# WhisperClip

## What This Is

WhisperClip — локальний macOS AI-інструмент для транскрипції та резюмування зустрічей. Записує системне аудіо та мікрофон одночасно, транскрибує через Whisper (FluidAudio), ідентифікує спікерів через diarization, і зберігає структуровані нотатки зустрічей.

## Core Value

Точна транскрипція зустрічей з правильною атрибуцією спікерів — користувач завжди знає хто що сказав.

## Requirements

### Validated

<!-- Shipped and confirmed valuable — v1.0 SettingsView Refactoring -->

- ✓ SettingsView розбита на фокусовані sub-views по вкладках — Phase 1
- ✓ HotkeySettingsViewModel, LLMModelViewModel, PromptManagementViewModel — Phase 2
- ✓ Prompt мігровано на SwiftData @Model — Phase 3
- ✓ Unit-тести: 18 тестів для всіх ViewModels і SwiftData — Phase 4
- ✓ Global hotkey через KeyboardShortcuts 2.4.0, AppDelegate registration — Phase 5
- ✓ Dual-channel audio capture (mic + system audio) — existing
- ✓ ASR через FluidAudio (Parakeet TDT) — existing
- ✓ MeetingSession, MeetingStorage, MeetingDetailView — existing
- ✓ DiarizerManager (FluidAudio) wired into MeetingRecorder — v1.1 start

### Shipped — v1.1 Speaker Diarization (2026-03-23)

- ✓ PIPE-01..04: SpeakerBufferManager actor — per-speaker buffers, speaker change trigger, 30s cap, atomic ASR
- ✓ PIPE-05: Мікрофон завжди "Me", без diarization — Phase 7 + Phase 9 gap closure
- ✓ SPKR-01..03: DiarizerManager зі стабільними IDs, clusteringThreshold 0.3, "Speaker N" labels
- ✓ RT-01..03: Canvas waveform — per-bar speaker color history, -50dB noise floor, activeSpeakerLabel для mic path
- ✓ Diarization тимчасово вимкнена — стабільний continuous stream у боєвих умовах (battle-tested 2026-03-23)

### Active — v1.2 Live Enrichment & Diarization Fix

- [ ] MUT-01: `MeetingSegment.speakerLabel` — `@Published var`, реактивне оновлення без reload
- [ ] MUT-02: Retroactive speaker update API — Reconciler може патчити сегмент за ID
- [ ] MUT-03: `MeetingSession` і `MeetingStorage` зберігають сумісність — без breaking changes
- [ ] DIAR-01: Diarizer мікро-вікна 5-10s (default 7s) замість 30s batch — усуває speaker blending
- [ ] DIAR-02: Speaker change у межах вікна → boundary → два окремих сегменти
- [ ] LIVE-01: Mic ASR рендериться в UI протягом ~0.5s після decode — не чекає diarizer
- [ ] LIVE-02: System ASR рендериться одразу під `[Pending]` — label оновлюється коли diarizer підтверджує
- [ ] LIVE-03: Жоден сэмпл не втрачається між fast ASR path і diarizer micro-window path
- [ ] CHAT-01: Consecutive segments одного спікера — chat-style bubble group
- [ ] CHAT-02: Ім'я/аватар один раз зверху групи
- [ ] CHAT-03: Timestamp тільки в кінці групи
- [ ] CHAT-04: "Me" — справа, інші — зліва (iMessage style)
- [ ] REC-01: Reconciler патчить `[Pending]` сегменти протягом ~2 вікон після capture
- [ ] REC-02: Сегмент що охоплює зміну спікера — split на два без втрати тексту
- [ ] REC-03: Reconciler — standalone actor з unit-testable interface

### Out of Scope

- Рефакторинг SettingsView далі — v1.0 завершено
- XCUITest / UI automation — немає інфраструктури
- Speaker naming/labeling UI (перейменування "Speaker 1" → "Олексій") — v1.2
- Cloud sync або export — local-first
- Bool/String/UInt16 міграція на SwiftData — UserDefaults достатній

## Context

- **Stack:** Swift 5.10, SwiftUI + AppKit, macOS 14+ (Sonoma)
- **Audio:** FluidAudio (Parakeet TDT ASR + DiarizerManager), DualChannelAudioCapture
- **Diarization:** FluidAudio SpeakerManager, clusteringThreshold tuning active
- **Patterns:** ObservableObject + @Published, PascalCase файли, XCTest
- **Current pipeline:** fixed 5s chunks → ASR → resolveSpeaker(dominant) → 1 segment
- **Target pipeline:** continuous buffer per speaker → speaker change → atomic ASR → N segments

## Constraints

- **Platform:** macOS 14.0+ (AVFoundation, CoreML, FluidAudio)
- **Local-only:** Немає мережевих залежностей для core features
- **No regressions:** Кожна фаза компілюється і записує зустрічі
- **Mic = always Me:** Мікрофонний канал ніколи не проходить через diarizer — один користувач на мік. Майбутня підтримка meeting room (кілька людей на одному мікрофоні) — explicitly deferred.
- **Diarization disabled until Phase 11:** Діаризація залишається вимкненою в `MeetingRecorder` до Phase 11 (мікро-вікна). Поточний стан: source-based attribution — `mic -> "Me"`, system -> `""` (unknown).

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| SwiftData тільки для Prompt | Прості settings — UserDefaults достатньо | ✓ Good |
| SettingsStore як фасад | Не ламаємо зовнішні залежності | ✓ Good |
| KeyboardShortcuts 2.4.0 | CGEventTap не надійний, бібліотека вирішує проблему | ✓ Good |
| DiarizerManager wired into pipeline | FluidAudio готовий, моделі завантажені | ✓ Good |
| clusteringThreshold 0.3 vs 0.7 | 0.7 = benchmark default; streaming chunks потребують нижчого порогу | — Phase 11 |
| Hybrid splitting (change + cap) | Speaker change = природний сегмент; cap = захист від довгих монологів | — Phase 11 |
| Disable diarization (2026-03-23) | 30s batch = неприйнятний лаг + speaker blending; пріоритет — continuous stream | Active until Phase 11 |
| Мікровікна 5-10s замість 30s | Battle test виявив що 30s batch = UX bottleneck; мікровікна = менший blending | — Phase 11 |
| Immediate Render + Async Enrichment | ASR stream не чекає diarizer; Reconciler патчить `[Pending]` labels асинхронно | — Phase 12-13 |
| Chat Bubble UI на мutablemodel | Будувати UI на immutable model = марна трата; чекаємо Phase 11 foundation | — Phase 10 (v1.2) |

## Current Milestone: v1.2 Live Enrichment & Diarization Fix

**Goal:** Зробити транскрипцію миттєвою, а діаризацію — точною та асинхронною. Текст з'являється в UI одразу після decode; diarizer з мікро-вікнами (7s) асинхронно збагачує сегменти правильним спікером через Reconciler.

**Target features:**
- Mutable `MeetingSegment` з реактивним `speakerLabel`
- Diarizer мікро-вікна 5-10s (замість 30s) — усуває speaker blending
- Immediate ASR render — `[Me]` для mic, `[Pending]` для system
- Reconciler — async патчинг і split сегментів по speaker boundary
- Chat Bubble UI на новій реактивній моделі

---
*Last updated: 2026-03-23 — v1.1 shipped; v1.2 Live Enrichment started*
