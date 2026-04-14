# Phase 4: Test Coverage — Context

**Gathered:** 2026-03-21
**Status:** Ready for planning

<domain>
## Phase Boundary

Unit tests for three ViewModels (`HotkeySettingsViewModel`, `LLMModelViewModel`, `PromptManagementViewModel`) and the SwiftData `Prompt` model. Covers TEST-01 through TEST-04. No new UI, no new features — only tests and the minimal source changes required for testability.

Phase 4 also includes a small but necessary refactor: extracting a `HotkeyManaging` protocol from `HotkeyManager` and updating `HotkeySettingsViewModel` to depend on the protocol instead of the concrete class. This enables injection of a no-op test double.

</domain>

<decisions>
## Implementation Decisions

### SettingsStore test isolation
- Change `private init()` → `init(defaults: UserDefaults = .standard)` (make init internal)
- Tests instantiate: `let testStore = SettingsStore(defaults: UserDefaults(suiteName: "com.whisperclip.tests")!)`
- Cleanup in `tearDown`: `UserDefaults.standard.removeSuite(named: "com.whisperclip.tests")`
- All 4 test files use this pattern — no test touches `SettingsStore.shared` or production UserDefaults

### `@MainActor` test pattern
- Mark each test class `@MainActor` at the class level
- Test methods remain synchronous (no `async`/`await` needed for synchronous VM methods)
- Matches existing `GenericHelperTests` style — no new async overhead
- Example: `@MainActor final class HotkeySettingsViewModelTests: XCTestCase { ... }`

### HotkeyManager protocol + test double
- Extract `HotkeyManaging` protocol with one required method:
  `func updateSystemHotkey(hotkeyEnabled: Bool, modifier: NSEvent.ModifierFlags, keyCode: UInt16)`
- `HotkeyManager` and its `meetingShared` instance both conform to `HotkeyManaging`
- `HotkeySettingsViewModel` init changes: `hotkeyManager: any HotkeyManaging = HotkeyManager.shared, meetingHotkeyManager: any HotkeyManaging = HotkeyManager.meetingShared`
- Create `NullHotkeyManager: HotkeyManaging` in the test target — empty no-op body
- Tests inject `NullHotkeyManager()` — no OS hotkey registration during test execution
- Source files modified for this refactor: `Sources/HotkeyManager.swift`, `Sources/HotkeySettingsViewModel.swift`

### What "updateHotkey persistence" actually tests (TEST-01)
- Call `vm.onModifierChanged(newModifierRaw)` or `vm.onKeyCodeChanged(newKeyCode)`
- Assert `testStore.hotkeyModifier` / `testStore.hotkeyKey` updated to the new value
- The store write is the contract — HotkeyManager system registration is a side effect, not asserted

### LLMModelViewModel test scope (TEST-03)
- `downloadLLMModel` spawns an async `Task` hitting `ModelStorage.shared` — not tested
- ≥2 tests cover synchronous, observable state:
  1. `testRefreshModelsSizeReturnsInt64` — `refreshModelsSize()` sets `totalModelsSize` (Int64, ≥0)
  2. `testDeleteLLMModelUpdatesSelectedModelName` — after `deleteLLMModel`, `store.selectedLLMModelName` changes to fallback if deleted model was selected
- `ModelStorage.shared` is used as-is (non-injectable) — tests accept that real disk state may affect results; assertions are bounded (no exact size values)

### Claude's Discretion
- Exact names for `NullHotkeyManager` test double file (`Tests/TestDoubles/NullHotkeyManager.swift` or inline in test file)
- Whether `HotkeyManaging` protocol lives in `Sources/HotkeyManager.swift` or a new `Sources/HotkeyManaging.swift`
- Exact `XCTAssert*` calls for each test beyond what REQUIREMENTS specify
- `PromptSwiftDataTests` `setUp`/`tearDown` structure (beyond the `isStoredInMemoryOnly: true` requirement)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### ViewModels under test
- `Sources/HotkeySettingsViewModel.swift` — init signature, `@Published` properties, methods under test
- `Sources/LLMModelViewModel.swift` — init, methods, `ModelStorage.shared` dependency
- `Sources/PromptManagementViewModel.swift` — init, all CRUD methods

### Source changes for testability
- `Sources/HotkeyManager.swift` — add `HotkeyManaging` protocol, make `HotkeyManager` conform
- `Sources/SettingsStore.swift` — change `private init()` to `init(defaults: UserDefaults = .standard)`

### SwiftData support
- `Sources/SettingsDataContainer.swift` — in-memory `ModelContainer` factory for `PromptSwiftDataTests`; factory must use `ModelConfiguration(isStoredInMemoryOnly: true)` — no database files written to disk
- `Sources/Prompt+SwiftData.swift` — `@Model class Prompt` fields and init (created in Phase 3)

### Requirements
- `.planning/REQUIREMENTS.md` — TEST-01, TEST-02, TEST-03, TEST-04 (exact test counts and method coverage)

### Existing test pattern
- `Tests/GenericHelperTests.swift` — existing XCTestCase structure, import style, assertion style

### Project conventions
- `.planning/codebase/CONVENTIONS.md` — Swift coding conventions

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `GenericHelperTests.swift` — template for XCTestCase style (`@testable import WhisperClip`, XCTAssert* calls)
- `SettingsDataContainer` (Phase 3 output) — call `SettingsDataContainer.makeInMemory()` in `PromptSwiftDataTests.setUp`; must use `ModelConfiguration(isStoredInMemoryOnly: true)` — no files written to disk
- `SettingsViewData.keyOptions` / `modifierOptions` — used by `HotkeySettingsViewModel.keyCodeToString` — tests can use known values from this array

### Established Patterns
- `HotkeySettingsViewModel(store:hotkeyManager:meetingHotkeyManager:)` — all three injectable
- `LLMModelViewModel(store:)` — store injectable, `ModelStorage.shared` is not
- `PromptManagementViewModel(store:)` — store injectable, all methods synchronous
- All 3 VMs are `@MainActor` — test classes must be `@MainActor`

### Integration Points
- `SettingsStore.init(defaults:)` (post-refactor) — instantiated in each test `setUp` with a test suite
- `NullHotkeyManager` — declared in test target only, injected into `HotkeySettingsViewModel` in tests
- `UserDefaults.standard.removeSuite(named: "com.whisperclip.tests")` — tearDown cleanup

</code_context>

<specifics>
## Specific Ideas

- `HotkeyManaging` protocol: minimal surface — only `updateSystemHotkey(hotkeyEnabled:modifier:keyCode:)` needed
- `NullHotkeyManager`: struct (not class), single empty method body
- `SettingsStore.init(defaults:)`: only change is access level + parameter; all `self.defaults = defaults` references stay the same
- "updateHotkey persistence" test: call `vm.onKeyCodeChanged(49)` → assert `testStore.hotkeyKey == 49` (Space key, already in `SettingsViewData.keyOptions`)
- `PromptSwiftDataTests` ModelContainer: `ModelConfiguration(isStoredInMemoryOnly: true)` — explicit requirement; no `.sqlite` files left on SSD after test run

</specifics>

<deferred>
## Deferred Ideas

- None — discussion stayed within phase scope

</deferred>

---

*Phase: 04-test-coverage*
*Context gathered: 2026-03-21*
