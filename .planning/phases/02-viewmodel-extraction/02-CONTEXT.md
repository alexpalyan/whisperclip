# Phase 2: ViewModel Extraction — Context

**Gathered:** 2026-03-21
**Status:** Ready for planning

<domain>
## Phase Boundary

Витягти `@State`-логіку і приватні функції з `HotkeySettingsView`, `GeneralSettingsView`, і `PromptsSettingsView` у три `ObservableObject` ViewModels. Views стають декларативними — тільки bindings і рендеринг. Ніяких нових UI-компонентів, ніяких змін до `SettingsStore` публічного API.

</domain>

<decisions>
## Implementation Decisions

### ViewModel Ownership
- Each View owns its VM with `@StateObject`: `@StateObject var vm = HotkeySettingsViewModel()`
- `HotkeySettingsView` → `@StateObject var vm = HotkeySettingsViewModel()`
- `GeneralSettingsView` → `@StateObject var llmVM = LLMModelViewModel()`
- `PromptsSettingsView` → `@StateObject var vm = PromptManagementViewModel()`
- `SettingsView` (coordinator) does NOT create or pass VMs — each tab view is self-contained

### SettingsStore Access (Testability)
- VMs receive `SettingsStore` as an init parameter with a default value:
  `HotkeySettingsViewModel(store: SettingsStore = .shared)`
- Production usage: `@StateObject var vm = HotkeySettingsViewModel()` (uses default `.shared`)
- Tests pass a custom/test store instance for isolation
- This applies to ALL three ViewModels (HotkeySettingsViewModel, LLMModelViewModel, PromptManagementViewModel)

### HotkeyManager Injection
- `HotkeySettingsViewModel` also injects `HotkeyManager` for testability:
  `HotkeySettingsViewModel(store: SettingsStore = .shared, hotkeyManager: HotkeyManager = .shared, meetingHotkeyManager: HotkeyManager = .meetingShared)`
- VM owns `updateHotkey()` and `updateMeetingHotkey()` calls — not the View
- Tests can verify hotkey registration side effects without triggering real system calls

### LLMModelViewModel Location
- LLM download/delete state moves out of `GeneralSettingsView` into `LLMModelViewModel`
- `GeneralSettingsView` keeps the `@StateObject var llmVM = LLMModelViewModel()` — no new view file
- LLM section UI in `GeneralSettingsView` binds to `llmVM` instead of local `@State`

### What Stays in Views (@State for pure UI modals)
- `showingResetConfirmation: Bool` stays in `GeneralSettingsView` — purely UI modal, no business logic
- `showingDeleteModelsConfirmation: Bool` stays in `GeneralSettingsView` — same reason
- All other `@State` in the three Views moves to corresponding ViewModels as `@Published`

### No `import SwiftUI` in ViewModels
- ViewModels must not import SwiftUI — only Foundation and AppKit/Cocoa where needed
- `NSEvent.ModifierFlags` is AppKit — acceptable in `HotkeySettingsViewModel`
- This constraint is from REQUIREMENTS.md VM-01/02/03

### Claude's Discretion
- Exact `@Published` property names (should match current `@State` names for minimal diff)
- `onAppear` lifecycle: whether Views call `vm.loadSettings()` or VM auto-loads in `init`
- Exact `ModelDownloader` / `ModelStorage` integration details in `LLMModelViewModel`

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Current Implementation (source of truth)
- `Sources/HotkeySettingsView.swift` — current `@State` vars and private funcs to extract
- `Sources/GeneralSettingsView.swift` — LLM download state and private funcs to extract
- `Sources/PromptsSettingsView.swift` — prompt CRUD state and private funcs to extract
- `Sources/SettingsStore.swift` — singleton API that MUST NOT change; VMs call this
- `Sources/HotkeyManager.swift` — called by `HotkeySettingsViewModel.updateHotkey()`

### Requirements
- `.planning/REQUIREMENTS.md` — VM-01, VM-02, VM-03, VM-04 (exact field and method lists per VM)

### Project Conventions
- `.planning/codebase/CONVENTIONS.md` — Swift coding conventions
- `.planning/codebase/ARCHITECTURE.md` — architectural layers

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `SettingsStore.shared` — singleton, VMs depend on it via injected parameter
- `HotkeyManager.shared` / `HotkeyManager.meetingShared` — injected into `HotkeySettingsViewModel`
- `ModelStorage.shared`, `ModelDownloader` — used by `LLMModelViewModel.downloadLLMModel()`
- `SettingsViewData` — static data accessed by ViewModels for key/modifier mapping

### Established Patterns
- `ObservableObject` + `@Published` already used by `SettingsStore` — same pattern for VMs
- `@ObservedObject var settings: SettingsStore` in all Views — VMs replace inline logic but Views still receive `settings` for direct bindings where needed (e.g., Toggles that write directly to SettingsStore)
- PascalCase file naming, one type per file

### Integration Points
- Views switch from `@State` to `vm.propertyName` bindings (e.g., `$vm.selectedModifierRawValue`)
- `HotkeySettingsView.onAppear` currently calls `loadHotkeySettings()` — this moves to VM `init` or a `load()` method
- `GeneralSettingsView` LLM section: replace `llmDownloadInProgress`, `llmDownloadProgress`, `llmDownloadModelName` with `llmVM.` prefixed equivalents

</code_context>

<specifics>
## Specific Ideas

- Testability over simplicity: inject dependencies even at the cost of slightly verbose init signatures
- Phase 4 tests need to verify `updateHotkey()` was called — HotkeyManager must be mockable/injectable
- Keep `@State` only for UI-only modal flags (`showingResetConfirmation`, etc.) — nothing with business logic

</specifics>

<deferred>
## Deferred Ideas

- None — discussion stayed within phase scope

</deferred>

---

*Phase: 02-viewmodel-extraction*
*Context gathered: 2026-03-21*
