# Phase 4: Test Coverage - Research

**Researched:** 2026-03-21
**Domain:** Swift XCTest, @MainActor isolation, UserDefaults test suites, SwiftData in-memory containers
**Confidence:** HIGH

## Summary

Phase 4 adds unit tests for three `@MainActor` ViewModels and the SwiftData `Prompt` model. All required source is in place from Phases 2 and 3: `HotkeySettingsViewModel`, `LLMModelViewModel`, `PromptManagementViewModel`, `Prompt`, and `SettingsDataContainer`. The test target `WhisperClipTests` already exists in `Package.swift` and the single existing test file (`GenericHelperTests.swift`) establishes the pattern to follow.

Two small source refactors are required before tests can be written: (1) `SettingsStore.init` must change from `private init()` to `init(defaults: UserDefaults = .standard)` so test code can construct isolated instances, and (2) a `HotkeyManaging` protocol must be extracted from `HotkeyManager` so tests can inject a no-op double instead of triggering OS-level event taps. Neither refactor changes any public API surface.

The core testing discipline for this phase is isolation: every test must operate against a named UserDefaults suite (not `.standard`), cleaned up in `tearDown`, and SwiftData tests must use an in-memory `ModelContainer` created via `SettingsDataContainer.create(inMemory: true)`. The `@MainActor` attribute on all three ViewModels requires each test class to also be annotated `@MainActor` at the class level.

**Primary recommendation:** Write all test classes as `@MainActor final class ... : XCTestCase`, instantiate `SettingsStore(defaults: UserDefaults(suiteName: "com.whisperclip.tests")!)` in each `setUp`, and remove the suite in `tearDown`.

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**SettingsStore test isolation**
- Change `private init()` to `init(defaults: UserDefaults = .standard)` (make init internal)
- Tests instantiate: `let testStore = SettingsStore(defaults: UserDefaults(suiteName: "com.whisperclip.tests")!)`
- Cleanup in `tearDown`: `UserDefaults.standard.removeSuite(named: "com.whisperclip.tests")`
- All 4 test files use this pattern — no test touches `SettingsStore.shared` or production UserDefaults

**`@MainActor` test pattern**
- Mark each test class `@MainActor` at the class level
- Test methods remain synchronous (no `async`/`await` needed for synchronous VM methods)
- Matches existing `GenericHelperTests` style — no new async overhead
- Example: `@MainActor final class HotkeySettingsViewModelTests: XCTestCase { ... }`

**HotkeyManager protocol + test double**
- Extract `HotkeyManaging` protocol with one required method: `func updateSystemHotkey(hotkeyEnabled: Bool, modifier: NSEvent.ModifierFlags, keyCode: UInt16)`
- `HotkeyManager` and its `meetingShared` instance both conform to `HotkeyManaging`
- `HotkeySettingsViewModel` init changes: `hotkeyManager: any HotkeyManaging = HotkeyManager.shared, meetingHotkeyManager: any HotkeyManaging = HotkeyManager.meetingShared`
- Create `NullHotkeyManager: HotkeyManaging` in the test target — empty no-op body
- Tests inject `NullHotkeyManager()` — no OS hotkey registration during test execution
- Source files modified for this refactor: `Sources/HotkeyManager.swift`, `Sources/HotkeySettingsViewModel.swift`

**What "updateHotkey persistence" actually tests (TEST-01)**
- Call `vm.onModifierChanged(newModifierRaw)` or `vm.onKeyCodeChanged(newKeyCode)`
- Assert `testStore.hotkeyModifier` / `testStore.hotkeyKey` updated to the new value
- The store write is the contract — HotkeyManager system registration is a side effect, not asserted

**LLMModelViewModel test scope (TEST-03)**
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

### Deferred Ideas (OUT OF SCOPE)
- None — discussion stayed within phase scope
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| TEST-01 | `Tests/HotkeySettingsViewModelTests.swift` — ≥5 tests: `keyCodeToString` for Space/F-keys, `getModifierString` for single and combined modifiers, `updateHotkey` persists to SettingsStore | `SettingsViewData.keyOptions` and `modifierOptions` provide known key code / modifier raw values for deterministic assertions. `HotkeyManaging` protocol + `NullHotkeyManager` removes OS dependency. |
| TEST-02 | `Tests/PromptManagementViewModelTests.swift` — ≥4 tests: create appends, saveEdits updates label, cancelEditing clears state, delete removes from store | `PromptManagementViewModel` all methods are synchronous. `SettingsStore(defaults:)` constructor with named suite provides isolated SwiftData + UserDefaults store per test. |
| TEST-03 | `Tests/LLMModelViewModelTests.swift` — ≥2 tests: progressUpdates, deleteModelClearsState | `refreshModelsSize()` is synchronous. `deleteLLMModel` updates `store.selectedLLMModelName` synchronously. Only async `downloadLLMModel` Task path is explicitly out of scope per decisions. |
| TEST-04 | `Tests/PromptSwiftDataTests.swift` — ≥2 tests: persists across ModelContext, migration from UserDefaults (in-memory ModelContainer in setUp/tearDown) | `SettingsDataContainer.create(inMemory: true)` already exists and accepts `inMemory: Bool`. `Prompt` is `@Model final class` with `id`, `label`, `content`, `createdAt` fields. |
</phase_requirements>

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| XCTest | Built-in (macOS 14+) | Unit test framework | Already used in `GenericHelperTests.swift`; no additional dependency |
| SwiftData | Built-in (macOS 14+) | In-memory container for Prompt tests | Already in production code; `ModelConfiguration(isStoredInMemoryOnly:)` is the standard isolation pattern |
| UserDefaults (suite) | Built-in | Isolated settings state per test | Suite-named instances are the standard XCTest isolation mechanism for UserDefaults |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Foundation | Built-in | `UserDefaults`, `UUID`, `Date` | All test files |
| Cocoa / AppKit | Built-in | `NSEvent.ModifierFlags` used in hotkey tests | `HotkeySettingsViewModelTests` only |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Named UserDefaults suite | `@testable` access to reset singleton | Suite-based isolation is simpler and reversible; singleton mutation causes test-order coupling |
| `NullHotkeyManager` struct | Protocol mock generated by library | Library adds dependency; hand-written no-op struct is 4 lines and fully adequate |
| In-memory ModelContainer | Separate on-disk test DB | In-memory is always clean; on-disk creates file system side effects |

**Installation:** No new packages required. All dependencies are built into macOS 14 / Swift 5.

## Architecture Patterns

### Recommended Project Structure
```
Tests/
├── GenericHelperTests.swift             # existing
├── HotkeySettingsViewModelTests.swift   # TEST-01
├── PromptManagementViewModelTests.swift # TEST-02
├── LLMModelViewModelTests.swift         # TEST-03
├── PromptSwiftDataTests.swift           # TEST-04
└── TestDoubles/
    └── NullHotkeyManager.swift          # or inline in HotkeySettingsViewModelTests
```

### Pattern 1: @MainActor XCTestCase class
**What:** Annotate the entire test class with `@MainActor` to match the ViewModel's actor isolation. Test methods remain synchronous.
**When to use:** All test classes in this phase (all three VMs are `@MainActor`).
**Example:**
```swift
// Source: existing GenericHelperTests.swift + @MainActor overlay per CONTEXT.md
@MainActor final class HotkeySettingsViewModelTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var store: SettingsStore!
    private var vm: HotkeySettingsViewModel!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.whisperclip.tests")!
        store = SettingsStore(defaults: testDefaults)
        vm = HotkeySettingsViewModel(
            store: store,
            hotkeyManager: NullHotkeyManager(),
            meetingHotkeyManager: NullHotkeyManager()
        )
    }

    override func tearDown() {
        vm = nil
        store = nil
        UserDefaults.standard.removeSuite(named: "com.whisperclip.tests")
        super.tearDown()
    }
}
```

### Pattern 2: In-memory SwiftData ModelContainer
**What:** Create a fresh `ModelContainer` per test using `SettingsDataContainer.create(inMemory: true)`. Build a `ModelContext` from it. Discard in `tearDown`.
**When to use:** `PromptSwiftDataTests` — tests that exercise the SwiftData layer directly.
**Example:**
```swift
// Source: SettingsDataContainer.swift — create(inMemory:) factory
override func setUp() {
    super.setUp()
    container = SettingsDataContainer.create(inMemory: true)
    context = ModelContext(container)
}

override func tearDown() {
    context = nil
    container = nil
    super.tearDown()
}
```

### Pattern 3: NullHotkeyManager test double
**What:** A minimal struct conforming to the new `HotkeyManaging` protocol with a no-op body. Lives in the test target.
**When to use:** Inject into `HotkeySettingsViewModel` during all hotkey tests.
**Example:**
```swift
// Test target only — NullHotkeyManager.swift or inline
struct NullHotkeyManager: HotkeyManaging {
    func updateSystemHotkey(hotkeyEnabled: Bool, modifier: NSEvent.ModifierFlags, keyCode: UInt16) {}
}
```

### Pattern 4: SettingsStore init refactor
**What:** Change `private init(container: ModelContainer? = nil)` to `init(defaults: UserDefaults = .standard, container: ModelContainer? = nil)`. Store `defaults` as an instance property and replace all `UserDefaults.standard` references in `SettingsStore` with `self.defaults`.
**When to use:** Required source change — prerequisite for all test files.
**Current state:** `SettingsStore` uses a hard-coded `private let defaults = UserDefaults.standard` property on line 79. The init is `private init(container:)`. Both must change.

### Anti-Patterns to Avoid
- **Using `SettingsStore.shared` in tests:** Writes to production UserDefaults; causes test-order side effects.
- **`async` test methods for synchronous VMs:** All three VMs' methods under test are synchronous. Marking tests `async` adds overhead and complexity without benefit.
- **Asserting exact `totalModelsSize` values:** Disk state is non-deterministic in `LLMModelViewModelTests`. Assert `>= 0` only.
- **Writing SwiftData tests without in-memory container:** Leaves `.sqlite` files on disk and creates cross-test state.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| UserDefaults isolation | Custom key-prefixing scheme | Named suite + `removeSuite` | Built-in, reversible, zero boilerplate |
| In-memory persistence | Custom mock ModelContext | `ModelConfiguration(isStoredInMemoryOnly: true)` | SwiftData's own isolation mechanism; identical API surface |
| `HotkeyManager` isolation | Subclass or swizzling | `HotkeyManaging` protocol + no-op struct | Protocol is 3 lines; avoids CGEvent tap registration which can fail in CI |

**Key insight:** SwiftData and UserDefaults both provide first-party isolation mechanisms. Using them avoids mock complexity and tests against real store behavior.

## Common Pitfalls

### Pitfall 1: SettingsStore still private init after refactor
**What goes wrong:** `SettingsStore(defaults:)` is unreachable from the test target — compiler error.
**Why it happens:** `private init` is still `private` after changing the parameter; the access level keyword must change to `internal` (no keyword, since `internal` is default in Swift).
**How to avoid:** Change `private init(container:)` to `init(defaults: UserDefaults = .standard, container: ModelContainer? = nil)`.
**Warning signs:** `'SettingsStore' initializer is inaccessible due to 'private' protection level` compile error.

### Pitfall 2: HotkeySettingsViewModel still typed to HotkeyManager concrete
**What goes wrong:** After extracting `HotkeyManaging` protocol, the VM properties `hotkeyManager` and `meetingHotkeyManager` remain typed as `HotkeyManager` — `NullHotkeyManager` cannot be injected.
**Why it happens:** Forgot to update the stored property types in `HotkeySettingsViewModel`.
**How to avoid:** Change `private let hotkeyManager: HotkeyManager` to `private let hotkeyManager: any HotkeyManaging` and correspondingly for the init parameter.
**Warning signs:** `cannot convert value of type 'NullHotkeyManager' to expected argument type 'HotkeyManager'`.

### Pitfall 3: @MainActor isolation causes test runtime failure
**What goes wrong:** Tests fail with "Main actor-isolated ... can not be referenced from a nonisolated context" at runtime or compile time.
**Why it happens:** XCTestCase test methods are not automatically on the MainActor even if the class is, in older patterns.
**How to avoid:** Annotate the entire class with `@MainActor`, not individual methods. This applies the isolation uniformly.
**Warning signs:** `Expression is 'async' but is not marked with 'await'` or actor isolation compile errors.

### Pitfall 4: SettingsStore.init calls loadSettings which reads real UserDefaults before test suite is set
**What goes wrong:** Init reads from `UserDefaults.standard` before the test suite is applied, picking up production values.
**Why it happens:** `loadSettings()` is called inside `init` before any custom defaults can be injected.
**How to avoid:** The refactor passes `defaults` as a parameter to `init`, and `loadSettings()` reads from `self.defaults` (which is the test suite). The key is that `private let defaults = UserDefaults.standard` on line 79 must be replaced by `private let defaults: UserDefaults` assigned from the init parameter.
**Warning signs:** Tests passing in isolation but failing when run with production data present in UserDefaults.standard.

### Pitfall 5: PromptSwiftDataTests container not fully cleaned up
**What goes wrong:** In-memory container persists state between test methods if `container` and `context` are not nilled in `tearDown`.
**Why it happens:** Each `@testable` test method shares the same instance-level `container` unless re-created.
**How to avoid:** Set `container = nil` and `context = nil` in `tearDown`, then create fresh instances in `setUp`.
**Warning signs:** Test order dependency — tests pass individually but fail when run as a suite.

### Pitfall 6: `SettingsStore(defaults:)` triggers `migratePromptsFromUserDefaults` with real data
**What goes wrong:** Migration logic reads `UserDefaults.standard` for `did_migrate_to_swiftdata` key, potentially interfering.
**Why it happens:** `migratePromptsFromUserDefaults()` uses `defaults` but checks a separate key. If using a named suite, this key is scoped to that suite — which starts empty — causing migration to run every time.
**How to avoid:** This is expected behavior: migration from UserDefaults runs once per fresh suite, seeds default prompts. Tests should account for the 3 default seeded prompts when asserting counts.
**Warning signs:** `createNewPrompt` test expects count 1 but sees count 4 (3 defaults + 1 created).

## Code Examples

Verified patterns from actual project source:

### Known key codes (from SettingsViewData.keyOptions)
```swift
// Source: Sources/SettingsViewData.swift
// keyOptions: [(UInt16, String)]
// (49, "Space"), (36, "Return"), (48, "Tab"), (51, "Delete"), (53, "Escape")
// (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"), (101, "F9")
// F10=109, F11=103, F12=111, F13=105, F14=107, F15=113
```

### Known modifier raw values (from SettingsViewData.modifierOptions)
```swift
// Source: Sources/SettingsViewData.swift
// Single: .command, .option, .control, .shift
// Combined: [.command, .option], [.command, .control], [.command, .shift]
//           [.option, .control], [.option, .shift], [.control, .shift]
// getModifierString() returns "⌘ Command" for .command, "⌥ Option" for .option, etc.
```

### HotkeyManaging protocol (to be added to Sources/HotkeyManager.swift)
```swift
// Source: CONTEXT.md decision — minimal protocol surface
protocol HotkeyManaging {
    func updateSystemHotkey(hotkeyEnabled: Bool, modifier: NSEvent.ModifierFlags, keyCode: UInt16)
}
```

### PromptSwiftDataTests setUp skeleton
```swift
// Source: CONTEXT.md + Sources/SettingsDataContainer.swift
@MainActor final class PromptSwiftDataTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        container = SettingsDataContainer.create(inMemory: true)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }
}
```

### LLMModelViewModel test — bounded assertion
```swift
// Source: CONTEXT.md decision — assertions are bounded (no exact size values)
func testRefreshModelsSizeReturnsNonNegative() {
    vm.refreshModelsSize()
    XCTAssertGreaterThanOrEqual(vm.totalModelsSize, 0)
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Mock frameworks (OCMock) | Protocol + test doubles | Swift 3+ era | No ObjC runtime swizzling; protocol conformance is compile-time safe |
| `DispatchQueue.main.async` in tests | `@MainActor` class annotation | Swift 5.5+ | Eliminates test flakiness from queue-based synchronization |
| `XCTestExpectation` for synchronous VM methods | Direct synchronous call + assert | N/A | VMs in this project are synchronous for observable state; no expectation needed |

**Deprecated/outdated:**
- `XCTestExpectation` for methods like `onKeyCodeChanged`: these are synchronous; no `waitForExpectations` call is needed or appropriate here.
- `DispatchQueue.main.sync` to enter the main actor in tests: use `@MainActor` class annotation instead.

## Open Questions

1. **SettingsStore.init access level vs. `SettingsStore.shared`**
   - What we know: `static let shared = SettingsStore()` will call the refactored `init(defaults: .standard, container: nil)` which works correctly.
   - What's unclear: Whether changing from `private init` to `internal init` exposes the constructor to external callers outside the test target in unexpected ways.
   - Recommendation: Acceptable tradeoff. The `shared` singleton pattern is enforced by convention, not by init privacy, given the test isolation requirement.

2. **`SettingsStore` migration flag `did_migrate_to_swiftdata` in named suite**
   - What we know: Each test suite starts empty so migration runs on every `setUp`. Default prompts are seeded.
   - What's unclear: Whether this adds noticeable overhead to test setup.
   - Recommendation: Accept it. The in-memory ModelContainer makes persistence instantaneous. Tests asserting prompt counts should start from 3 (seeded defaults), not 0.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (built-in, macOS 14) |
| Config file | `Package.swift` — `.testTarget(name: "WhisperClipTests", dependencies: ["WhisperClip"], path: "Tests")` |
| Quick run command | `swift test --filter HotkeySettingsViewModelTests` |
| Full suite command | `swift test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TEST-01 | `keyCodeToString` maps Space (49) to "Space" | unit | `swift test --filter HotkeySettingsViewModelTests/testKeyCodeToStringSpace` | ❌ Wave 0 |
| TEST-01 | `keyCodeToString` maps F5 (96) to "F5" | unit | `swift test --filter HotkeySettingsViewModelTests/testKeyCodeToStringF5` | ❌ Wave 0 |
| TEST-01 | `getModifierString` returns "⌥ Option" for `.option` | unit | `swift test --filter HotkeySettingsViewModelTests/testGetModifierStringSingle` | ❌ Wave 0 |
| TEST-01 | `getModifierString` returns "⌘⌥ Command+Option" for combined modifier | unit | `swift test --filter HotkeySettingsViewModelTests/testGetModifierStringCombined` | ❌ Wave 0 |
| TEST-01 | `onKeyCodeChanged` persists key to SettingsStore | unit | `swift test --filter HotkeySettingsViewModelTests/testOnKeyCodeChangedPersists` | ❌ Wave 0 |
| TEST-02 | `createNewPrompt` appends to store.prompts | unit | `swift test --filter PromptManagementViewModelTests/testCreateNewPromptAppends` | ❌ Wave 0 |
| TEST-02 | `savePromptEdits` updates prompt label | unit | `swift test --filter PromptManagementViewModelTests/testSavePromptEditsUpdatesLabel` | ❌ Wave 0 |
| TEST-02 | `cancelEditing` clears editing state | unit | `swift test --filter PromptManagementViewModelTests/testCancelEditingClearsState` | ❌ Wave 0 |
| TEST-02 | `deletePrompt` removes from store | unit | `swift test --filter PromptManagementViewModelTests/testDeletePromptRemovesFromStore` | ❌ Wave 0 |
| TEST-03 | `refreshModelsSize` sets totalModelsSize >= 0 | unit | `swift test --filter LLMModelViewModelTests/testRefreshModelsSizeNonNegative` | ❌ Wave 0 |
| TEST-03 | `deleteLLMModel` updates selectedLLMModelName to fallback | unit | `swift test --filter LLMModelViewModelTests/testDeleteLLMModelUpdatesFallback` | ❌ Wave 0 |
| TEST-04 | Prompt inserted into in-memory context persists on fetch | unit | `swift test --filter PromptSwiftDataTests/testPromptPersistsInContext` | ❌ Wave 0 |
| TEST-04 | Prompt created via SettingsStore(container:) fetchable after save | unit | `swift test --filter PromptSwiftDataTests/testPromptCreatedViaStoreIsFetchable` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `swift test --filter <TestClassName>`
- **Per wave merge:** `swift test`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `Tests/HotkeySettingsViewModelTests.swift` — covers TEST-01 (≥5 tests)
- [ ] `Tests/PromptManagementViewModelTests.swift` — covers TEST-02 (≥4 tests)
- [ ] `Tests/LLMModelViewModelTests.swift` — covers TEST-03 (≥2 tests)
- [ ] `Tests/PromptSwiftDataTests.swift` — covers TEST-04 (≥2 tests)
- [ ] `Tests/TestDoubles/NullHotkeyManager.swift` (or inline) — required by TEST-01
- Source prerequisite: `Sources/HotkeyManager.swift` — add `HotkeyManaging` protocol, `HotkeyManager` conformance
- Source prerequisite: `Sources/HotkeySettingsViewModel.swift` — update stored property types to `any HotkeyManaging`
- Source prerequisite: `Sources/SettingsStore.swift` — change `private init(container:)` to `init(defaults:container:)`, replace `UserDefaults.standard` property with injected `defaults`

## Sources

### Primary (HIGH confidence)
- Codebase direct reads: `Sources/HotkeySettingsViewModel.swift`, `Sources/PromptManagementViewModel.swift`, `Sources/LLMModelViewModel.swift`, `Sources/SettingsStore.swift`, `Sources/HotkeyManager.swift`, `Sources/SettingsDataContainer.swift`, `Sources/Prompt+SwiftData.swift`, `Sources/SettingsViewData.swift`
- `Tests/GenericHelperTests.swift` — existing test style reference
- `Package.swift` — test target configuration confirmed

### Secondary (MEDIUM confidence)
- `CONTEXT.md` decisions — detailed implementation decisions made in prior discussion session

### Tertiary (LOW confidence)
- None — all critical claims are backed by direct source code reads

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all libraries are built-in; test target already declared in Package.swift
- Architecture patterns: HIGH — based on direct source code inspection and CONTEXT.md locked decisions
- Pitfalls: HIGH — derived from actual source code analysis (SettingsStore.init structure, UserDefaults.standard hard-coding, etc.)

**Research date:** 2026-03-21
**Valid until:** 2026-04-21 (stable APIs — XCTest, SwiftData, UserDefaults suites)
