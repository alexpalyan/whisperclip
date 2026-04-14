# Phase 3: SwiftData для Prompt — Context

**Gathered:** 2026-03-21
**Status:** Ready for planning

<domain>
## Phase Boundary

Migrate `Prompt` from `struct Codable` stored as UserDefaults JSON → `@Model final class` managed by SwiftData. `SettingsStore` remains the public facade — all external callers (`MicrophoneView`, `FileTranscriptionView`, `PromptManagementViewModel`) are unchanged. `selectedPromptId` stays in UserDefaults (plain String reference, not migrated).

</domain>

<decisions>
## Implementation Decisions

### Prompt model file
- New file: `Sources/Prompt+SwiftData.swift` — `@Model final class Prompt` lives here
- The existing `struct Prompt` in `SettingsStore.swift` is removed entirely
- No co-location with store logic — model and store are separate files

### Prompt model structure
- Fields: `id: String`, `label: String`, `content: String`, `createdAt: Date`
- `@Attribute(.unique)` on `id` field — enforces uniqueness in the SwiftData store
- Init signature: `init(id: String = UUID().uuidString, label: String, content: String, createdAt: Date = Date())`
  - Default values for `id` and `createdAt` — existing call sites like `Prompt(label:content:)` work unchanged
  - Migration code can pass explicit `id` and `createdAt` values

### UserDefaults migration strategy
- Migration guard: check `defaults.bool(forKey: "did_migrate_to_swiftdata")` at startup
- If flag is false (first launch after update): migrate from UserDefaults → SwiftData
- On successful migration:
  1. Copy existing `"prompts"` data to key `"prompts_backup_pre_swiftdata"` (safety backup, off the active read path)
  2. Remove the original `"prompts"` key (prevents drift/double-read)
  3. Set `"did_migrate_to_swiftdata" = true` (idempotency — migration runs exactly once)
- If flag is true: skip migration entirely, read directly from SwiftData

### createdAt for migrated prompts
- Each migrated prompt gets `createdAt = migrationDate.addingTimeInterval(Double(index))`
  - `migrationDate = Date()` at the moment migration runs
  - `index` = position in the original UserDefaults array (0, 1, 2, …)
  - Preserves original UserDefaults order when SwiftData queries sort by `createdAt`

### Claude's Discretion
- How `SettingsStore` obtains/owns its `ModelContext` (SettingsDataContainer factory approach from ROADMAP)
- Whether `SettingsStore` creates the `ModelContainer` internally or receives it via injection
- Exact `@MainActor` / threading strategy for SwiftData operations
- `DefaultSettings.prompts` handling: whether default prompts are seeded via migration path or separately

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Current implementation (source of truth)
- `Sources/SettingsStore.swift` — current `struct Prompt`, `savePrompts()`, `loadSettings()`, and all four public CRUD methods that must not change signature
- `Sources/PromptManagementViewModel.swift` — calls `createPrompt`, `updatePrompt`, `deletePrompt` — must continue to compile unchanged
- `Sources/MicrophoneView.swift` — uses `settings.currentPrompt` — must remain functional
- `Sources/FileTranscriptionView.swift` — uses `settings.currentPrompt` — must remain functional

### Requirements
- `.planning/REQUIREMENTS.md` — SD-01, SD-02, SD-03 (exact field list, container spec, API constraint)

### Project conventions
- `.planning/codebase/CONVENTIONS.md` — Swift coding conventions
- `.planning/codebase/ARCHITECTURE.md` — architectural layers

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `SettingsStore.shared` — singleton facade; prompt CRUD methods stay on this class
- `SettingsStore.loadSettings()` — migration runs inside here (or is called from init) after the SwiftData context is ready
- `DefaultSettings.prompts` — 3 default prompts used when no UserDefaults data exists; also needed for fresh installs (no migration path)

### Established Patterns
- `ObservableObject` + `@Published` already in use for `prompts: [Prompt]` — the published array pattern stays, backed by SwiftData fetch instead of UserDefaults decode
- Dependency injection via default init param (e.g., `init(store: SettingsStore = .shared)`) — `SettingsDataContainer` should follow the same pattern for testability (in-memory config)
- PascalCase file naming, one type per file

### Integration Points
- `SettingsStore.prompts` (`@Published var prompts: [Prompt]`) — still the SwiftUI binding source; now backed by a `ModelContext` fetch instead of JSONDecoder
- `SettingsStore.savePrompts()` — removed; writes go through `ModelContext.insert` / `ModelContext.delete` + `try context.save()`
- `WhisperClip.swift` app entry — may need `.modelContainer()` modifier if `SettingsStore` doesn't own the container internally

</code_context>

<specifics>
## Specific Ideas

- Init with default params: `init(id: String = UUID().uuidString, label: String, content: String, createdAt: Date = Date())` — "best of both worlds" per user: migration flexibility + zero call-site changes
- Migration ordering trick: `createdAt = migrationDate.addingTimeInterval(Double(index))` — preserves UserDefaults array order via sort-by-date
- Backup key: `"prompts_backup_pre_swiftdata"` — keeps old data as a black box without it being on any active read path
- Idempotency flag: `"did_migrate_to_swiftdata"` Boolean in UserDefaults

</specifics>

<deferred>
## Deferred Ideas

- None — discussion stayed within phase scope

</deferred>

---

*Phase: 03-swiftdata-prompt*
*Context gathered: 2026-03-21*
