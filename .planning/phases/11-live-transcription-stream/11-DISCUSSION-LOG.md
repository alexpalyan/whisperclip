# Phase 11: Live Transcription Stream - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-18
**Phase:** 11-live-transcription-stream
**Areas discussed:** UX/Tokens, UI/Pending Labels, Architecture/Priority, Behavior/Correction

---

## UX: Візуалізація токенів
| Option | Description | Selected |
|--------|-------------|----------|
| 0.5s batches | Збирати слова групами по пів секунди | |
| Streaming (tokens) | Пряма видача токенів WhisperKit | ✓ |
| Full segments only | Чекати завершення всього чанку | |

**User's choice:** Streaming (tokens). Прямий стрімінг токенів без штучних затримок.
**Notes:** "Слова мають з'являтися по одному. Це створює відчуття 'магії'."

---

## UI: Статус [Pending] та перехід до спікера
| Option | Description | Selected |
|--------|-------------|----------|
| Gray text for [Pending] | Сірий колір поки текст не стабільний | ✓ |
| Different icons | Іконка годинника поруч | |
| Normal text | Ніякого візуального виділення | |

**User's choice:** Gray text for [Pending]. При завершенні чанку колір стає Primary.
**Notes:** Заголовок залишається [Pending] для системного аудіо до Фази 13.

---

## Architecture: Пріоритетність та черга
| Option | Description | Selected |
|--------|-------------|----------|
| LIFO Queue | Пріоритет мікрофона через чергу | |
| Sequential Queue | Залишити як є (послідовно) | ✓ |
| Parallel Models | Запускати дві моделі одночасно (ризиковано) | |

**User's choice:** Sequential Queue. Пріоритет стабільності Neural Engine.
**Notes:** Текст мікрофона потрапляє в UI через callback, не чекаючи завершення WAV-файла.

---

## Behavior: Корекція "на льоту" (Стрибаючий текст)
| Option | Description | Selected |
|--------|-------------|----------|
| Allow flickering | Дозволити тексту змінюватися | ✓ |
| Freeze tokens | Фіксувати першу версію слова | |

**User's choice:** Allow flickering. Whisper часто уточнює контекст попередніх слів.
**Notes:** Це дає користувачеві найточнішу інформацію в реальному часі.

---

## Claude's Discretion
- Визначено, що `extractNewText` (deduplication) більше не потрібен для Live-шляху.

## Deferred Ideas
- Логіка "різання" баблів при зміні голосу перенесена на Фазу 13.
- Групування баблів перенесено на Фазу 12.
