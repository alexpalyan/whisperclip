# Phase 1: UI Decomposition — Context

**Gathered:** 2026-03-21
**Status:** Ready for planning
**Source:** User guidance

<domain>
## Phase Boundary

Декомпозиція `SettingsView.swift` (1,251 рядків) на фокусовані sub-views по вкладках. Кожна вкладка — окремий файл. Статичні дані (мови, клавіші, модифікатори) — окремий файл. `SettingsView` стає тонким TabView-координатором (~60 рядків).

</domain>

<decisions>
## Implementation Decisions

### Swift/SwiftUI Style
- Використовувати сучасні Swift/SwiftUI best practices (Swift 5.10, macOS 14+)
- Дотримуватися MVVM-патерну (у Phase 1 — підготовка структури, ViewModels у Phase 2)
- Розбивати на малі, повторно використовувані компоненти

### Readability
- Пріоритет — читабельність і стандартні Apple-конвенції
- Власник коду не є Swift-експертом, тому уникати надмірної складності
- Слідувати Swift API Design Guidelines: camelCase для функцій, PascalCase для типів

### Decomposition Rules
- Одна вкладка = один файл (не змішувати секції)
- Sub-views отримують `settings: SettingsStore` через `@ObservedObject` або `@EnvironmentObject`
- `@State` змінні залишаються у відповідному sub-view (до Phase 2)
- Кожен крок декомпозиції має компілюватися — не ломати проміжний стан

### Static Data
- Всі статичні масиви (languageOptions, modifierOptions, keyOptions, meetingKeyOptions, summaryLanguageOptions) → `SettingsViewData.swift` як `enum SettingsViewData` зі `static let` властивостями
- Типи tuple-масивів зберегти: `[(String, String)]`, `[(UInt, String)]`, `[(UInt16, String)]`

### File Structure
- `Sources/GeneralSettingsView.swift`
- `Sources/HotkeySettingsView.swift`
- `Sources/MeetingsSettingsView.swift`
- `Sources/PromptsSettingsView.swift` (включає PromptRowView і NewPromptDialog)
- `Sources/SettingsViewData.swift`
- `Sources/SettingsView.swift` — залишається як TabView-координатор

### Claude's Discretion
- Точний розподіл `@State` по sub-views (кожен sub-view отримує лише свій стан)
- Naming для `SettingsViewData` properties (залишити ті самі імена для сумісності)
- Порядок вкладок у TabView — залишити такий самий як в оригіналі

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Existing Code
- `Sources/SettingsView.swift` — оригінальний файл (1,251 рядків), джерело правди
- `Sources/SettingsStore.swift` — singleton, не змінювати публічний API

### Project Context
- `.planning/REQUIREMENTS.md` — REQ-IDs: UI-01 через UI-06
- `.planning/codebase/CONVENTIONS.md` — Swift coding conventions проєкту
- `.planning/codebase/ARCHITECTURE.md` — архітектурні шари
- `.planning/codebase/STACK.md` — Swift 5.10, macOS 14+, SwiftUI

</canonical_refs>

<specifics>
## Specific Ideas

- `SettingsView` body зараз починається з рядка 120 (TabView з 5 вкладками: General, Hotkey, Meetings, Prompts + розділ View Sections)
- Секції у SettingsView.swift: MARK: General Tab (172), MARK: Hot Key Tab (326), MARK: Meetings Tab (484), MARK: Prompts Tab (675), MARK: View Sections (768)
- `PromptRowView` і `NewPromptDialog` — вже окремі structs у кінці файлу (рядки 1093–1251), треба перенести у PromptsSettingsView.swift
- Статичні масиви оголошені як `private let` у `SettingsView` (рядки ~38–112)

</specifics>

<deferred>
## Deferred Ideas

- ViewModels (ObservableObject) — Phase 2
- SwiftData міграція — Phase 3
- Тести — Phase 4
- `@State` → `@Published` рефакторинг — Phase 2

</deferred>

---

*Phase: 01-ui-decomposition*
*Context gathered: 2026-03-21 via user guidance*
