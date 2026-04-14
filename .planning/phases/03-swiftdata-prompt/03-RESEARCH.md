# Phase 3 Research: SwiftData for Prompt Migration

## Standard Stack
- **Framework:** SwiftData (iOS 17+ / macOS 14+).
- **Persistence:** SQLite (default for SwiftData) with `ModelContainer`.
- **Testing:** In-memory `ModelContainer` for isolated unit tests.

## Architecture Patterns

### 1. SettingsDataContainer (Factory)
To ensure testability and clean separation, we implement a factory that provides the `ModelContainer`.
```swift
@MainActor
enum SettingsDataContainer {
    static func create(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema([Prompt.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }
}
```

### 2. Singleton Store Integration
`SettingsStore` remains an `ObservableObject` and a singleton. It will own a `ModelContext` and synchronize its `@Published var prompts` array manually.
- **Initialization:** `SettingsStore` receives or creates the `ModelContainer` and obtains its `mainContext`.
- **Synchronization:** Since we aren't using `@Query` (which is for SwiftUI Views), we must manually fetch prompts during `loadSettings()` and after each CRUD operation to keep the `@Published` property in sync.

### 3. Migration Handler
A dedicated private method in `SettingsStore` (or a separate helper) that:
1. Checks for a "migration completed" flag in `UserDefaults`.
2. Decodes the legacy JSON array.
3. Inserts each item into SwiftData with a generated `createdAt` timestamp to preserve order.
4. Backs up the old key and sets the migration flag.

## Don't Hand-Roll
- **JSON Serialization:** Stop using `JSONEncoder`/`JSONDecoder` for prompts after migration. SwiftData handles binary serialization automatically.
- **Manual ID Generation:** Use the existing `id` from the migrated `struct`, but let SwiftData handle the persistent identity of the `@Model` class.

## Common Pitfalls

### 1. Thread Safety
SwiftData models are not thread-safe. `SettingsStore` must be marked with `@MainActor` to ensure all access to `ModelContext` and `@Published` properties happens on the main thread, matching SwiftUI's requirements.

### 2. Relationship Drift
While not applicable now (no relationships for Prompt yet), ensure that `Prompt.id` remains unique using `@Attribute(.unique)` to prevent duplicate imports during migration or edge cases.

### 3. Missing Default Seed
If it's a fresh install (no UserDefaults to migrate), we must still seed the `DefaultSettings.prompts`. The logic should handle "No UserDefaults AND Empty SwiftData" by inserting defaults.

## Code Examples

### Prompt Model
```swift
@Model
final class Prompt {
    @Attribute(.unique) var id: String
    var label: String
    var content: String
    var createdAt: Date
    
    init(id: String = UUID().uuidString, label: String, content: String, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.content = content
        self.createdAt = createdAt
    }
}
```

### Fetching in Store
```swift
private func fetchPrompts() {
    let descriptor = FetchDescriptor<Prompt>(sortBy: [SortDescriptor(\.createdAt)])
    do {
        self.prompts = try modelContext.fetch(descriptor)
    } catch {
        print("Failed to fetch prompts: \(error)")
    }
}
```

## Confidence Levels
- **SwiftData API:** 5/5 (Well-documented, standard for modern macOS apps).
- **Migration Logic:** 5/5 (Standard UserDefaults-to-Database pattern).
- **Singleton Integration:** 4/5 (Requires careful `@MainActor` usage to avoid deadlocks or UI glitches).

---
*Generated: 2026-03-21*
