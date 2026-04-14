# Phase 2: ViewModel Extraction - Research

**Researched:** 2026-03-21
**Domain:** SwiftUI MVVM Architecture & Dependency Injection
**Confidence:** HIGH

## Summary

The goal of this phase is to move business logic and state management from SwiftUI Views into specialized ViewModels. This follows the MVVM (Model-View-ViewModel) pattern, which improves testability and separates concerns. We will use the standard `ObservableObject` and `@Published` pattern (Combine-based), as it is already established in the project via `SettingsStore`.

**Primary recommendation:** Use `@StateObject` in Views to own ViewModels, mark all ViewModel classes with `@MainActor` for thread safety, and use constructor injection for all dependencies (`SettingsStore`, `HotkeyManager`).

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Each View owns its VM with `@StateObject`: `@StateObject var vm = HotkeySettingsViewModel()`
- `HotkeySettingsView` → `@StateObject var vm = HotkeySettingsViewModel()`
- `GeneralSettingsView` → `@StateObject var llmVM = LLMModelViewModel()`
- `PromptsSettingsView` → `@StateObject var vm = PromptManagementViewModel()`
- `SettingsView` (coordinator) does NOT create or pass VMs — each tab view is self-contained
- VMs receive `SettingsStore` as an init parameter with a default value: `HotkeySettingsViewModel(store: SettingsStore = .shared)`
- `HotkeySettingsViewModel` also injects `HotkeyManager` for testability
- `GeneralSettingsView` keeps the `@StateObject var llmVM = LLMModelViewModel()` — no new view file
- `showingResetConfirmation: Bool` and `showingDeleteModelsConfirmation: Bool` stay in `GeneralSettingsView` as purely UI modal flags
- ViewModels must not import SwiftUI — only Foundation and AppKit/Cocoa where needed

### Claude's Discretion
- Exact `@Published` property names (should match current `@State` names for minimal diff)
- `onAppear` lifecycle: whether Views call `vm.loadSettings()` or VM auto-loads in `init`
- Exact `ModelDownloader` / `ModelStorage` integration details in `LLMModelViewModel`

### Deferred Ideas (OUT OF SCOPE)
- None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| VM-01 | `HotkeySettingsViewModel` encapsulation | Verified `HotkeyManager` and `SettingsStore` integration patterns. |
| VM-02 | `LLMModelViewModel` encapsulation | Identified async/await pattern for model downloads and `ModelStorage` interaction. |
| VM-03 | `PromptManagementViewModel` encapsulation | Verified `Prompt` struct and `SettingsStore` CRUD methods. |
| VM-04 | Declarative Views with only UI modals | Confirmed `@State` usage for modals vs `@Published` for business logic. |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Foundation | Native | Core logic, UUID, JSON | Standard Swift library for non-UI logic. |
| AppKit | Native | `NSEvent.ModifierFlags` | Required for hotkey modifier handling on macOS. |
| Combine | Native | `ObservableObject`, `@Published` | Established pattern in the codebase for state observation. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Swift Concurrency | Native | `async/await`, `Task`, `@MainActor` | Mandatory for safe background tasks (LLM downloads) and UI updates. |
| XCTest | Native | Unit Testing | Project's existing test framework. |

## Architecture Patterns

### Recommended Project Structure
```
Sources/
├── HotkeySettingsViewModel.swift       # New: Logic for Hotkey tab
├── LLMModelViewModel.swift             # New: Logic for LLM downloads/management
├── PromptManagementViewModel.swift     # New: Logic for Prompt CRUD
├── HotkeySettingsView.swift            # Refactored: Bindings to VM
├── GeneralSettingsView.swift           # Refactored: Bindings to LLM VM
└── PromptsSettingsView.swift           # Refactored: Bindings to Prompt VM
```

### Pattern 1: MVVM with Constructor Injection
**What:** ViewModels are classes conforming to `ObservableObject`, marked with `@MainActor`. They take their dependencies via the initializer.
**When to use:** Always for these three ViewModels to ensure testability.
**Example:**
```typescript
// Source: .planning/phases/02-viewmodel-extraction/02-CONTEXT.md
@MainActor
class HotkeySettingsViewModel: ObservableObject {
    private let store: SettingsStore
    private let hotkeyManager: HotkeyManager

    @Published var selectedModifierRawValue: UInt
    
    init(store: SettingsStore = .shared, hotkeyManager: HotkeyManager = .shared) {
        self.store = store
        self.hotkeyManager = hotkeyManager
        self.selectedModifierRawValue = store.hotkeyModifier.rawValue
    }
}
```

### Anti-Patterns to Avoid
- **Implicit Main Thread Assumptions:** Never update `@Published` properties from background threads (e.g., in a download callback). Use `@MainActor`.
- **Logic in View Init:** Do not perform heavy logic or side effects in `ViewModel.init`. Use a `load()` or `refresh()` method if needed, or keep init lightweight.
- **Direct SwiftUI Imports:** ViewModels should remain independent of SwiftUI to stay "pure" logic containers.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| UI Thread Sync | `DispatchQueue.main.async` | `@MainActor` | More declarative and compiler-checked in Swift 6. |
| Persistence | Custom File Saving | `SettingsStore` | Centralized UserDefaults management already exists. |
| Network/FS | Custom Downloaders | `ModelStorage` / `ModelDownloader` | Existing services handle these complex operations. |
| Global Events | `NotificationCenter` | `@Published` | SwiftUI's native way to propagate state changes. |

## Common Pitfalls

### Pitfall 1: State Desynchronization
**What goes wrong:** `SettingsStore` changes from another part of the app, but the ViewModel's local `@Published` properties don't update.
**Why it happens:** Local copies are made during VM init but not kept in sync.
**How to avoid:** Use Combine to observe `store.objectWillChange` and refresh local properties, or use computed properties with `objectWillChange.send()` (though standard `@Published` with explicit sync is often cleaner for SwiftUI bindings).

### Pitfall 2: Memory Leaks with ObservedObjects
**What goes wrong:** Strong reference cycles between long-running Tasks or closures and the ViewModel.
**Why it happens:** Capturing `self` strongly in a Task or a progress closure.
**How to avoid:** Use `[weak self]` in closures and ensure Tasks are properly scoped.

## Code Examples

### LLM Download Pattern (VM-02)
```swift
@MainActor
func downloadLLMModel(modelName: String) async {
    llmDownloadInProgress = true
    llmDownloadModelName = modelName
    llmDownloadProgress = 0

    let modelID = "\(CurrentLLMModelRepo)/\(modelName)"
    do {
        // progress closure might run on background thread
        try await ModelStorage.shared.downloadModel(modelRepo: modelID, modelName: "", progress: { [weak self] progress in
            Task { @MainActor in
                self?.llmDownloadProgress = progress
            }
        })
        try await ModelStorage.shared.preLoadModel(modelRepo: modelID, modelName: "")
        
        // Finalize state on MainActor
        self.settings.selectedLLMModelName = modelName
        self.llmDownloadInProgress = false
        self.refreshModelsSize()
    } catch {
        self.llmDownloadInProgress = false
    }
}
```

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest |
| Config file | Package.swift (WhisperClipTests) |
| Quick run command | `swift test --filter HotkeySettingsViewModelTests` |
| Full suite command | `swift test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| VM-01 | Hotkey logic extraction | unit | `swift test --filter HotkeySettingsViewModelTests` | ❌ Wave 0 |
| VM-02 | LLM download logic | unit | `swift test --filter LLMModelViewModelTests` | ❌ Wave 0 |
| VM-03 | Prompt CRUD logic | unit | `swift test --filter PromptManagementViewModelTests` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `swift test --filter {CurrentVM}Tests`
- **Per wave merge:** `swift test`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `Tests/HotkeySettingsViewModelTests.swift` — covers VM-01
- [ ] `Tests/LLMModelViewModelTests.swift` — covers VM-02
- [ ] `Tests/PromptManagementViewModelTests.swift` — covers VM-03
- [ ] Mocks/Test instances for `SettingsStore` and `HotkeyManager` (e.g., using `UserDefaults(suiteName:)` for store testing).

## Sources

### Primary (HIGH confidence)
- `Sources/HotkeySettingsView.swift` - Source of current logic
- `Sources/SettingsStore.swift` - Dependency definition
- `Sources/HotkeyManager.swift` - Dependency definition
- `Package.swift` - Deployment target (macOS 14)

### Secondary (MEDIUM confidence)
- Official Apple Documentation on `@MainActor` and `ObservableObject`.
- SwiftUI MVVM community best practices (2024-2025).

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Native Swift/Apple frameworks.
- Architecture: HIGH - Standard MVVM pattern tailored to project's existing `ObservableObject` usage.
- Pitfalls: HIGH - Well-known SwiftUI/Concurrency issues.

**Research date:** 2026-03-21
**Valid until:** 2026-04-21 (30 days)
