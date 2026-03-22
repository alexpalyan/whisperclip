import XCTest
import SwiftData
@testable import WhisperClip

@MainActor
final class PromptSwiftDataTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        container = SettingsDataContainer.create(inMemory: true)
        context = ModelContext(container)
        testDefaults = UserDefaults(suiteName: "com.whisperclip.swiftdata.tests")!
        testDefaults.removePersistentDomain(forName: "com.whisperclip.swiftdata.tests")
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "com.whisperclip.swiftdata.tests")
        testDefaults = nil
        context = nil
        container = nil
        super.tearDown()
    }

    func testPromptPersistsInContext() throws {
        let prompt = Prompt(label: "Test", content: "Test content")
        context.insert(prompt)
        try context.save()

        let descriptor = FetchDescriptor<Prompt>()
        let fetched = try context.fetch(descriptor)
        let savedPrompt = fetched.first(where: { $0.id == prompt.id })

        XCTAssertNotNil(savedPrompt)
        XCTAssertEqual(savedPrompt?.label, "Test")
        XCTAssertEqual(savedPrompt?.content, "Test content")
    }

    func testPromptCreatedViaStoreIsFetchable() {
        let inMemoryContainer = SettingsDataContainer.create(inMemory: true)
        let store = SettingsStore(defaults: testDefaults, container: inMemoryContainer)
        let initialCount = store.prompts.count

        _ = store.createPrompt(label: "SwiftData Test", content: "Persisted")

        XCTAssertEqual(store.prompts.count, initialCount + 1)
        XCTAssertTrue(store.prompts.contains(where: { $0.label == "SwiftData Test" }))
    }

    func testMigrationFromUserDefaults() throws {
        // Create a dedicated UserDefaults suite for migration test
        let migrationSuiteName = "com.whisperclip.swiftdata.migration.tests"
        let migrationDefaults = UserDefaults(suiteName: migrationSuiteName)!
        migrationDefaults.removePersistentDomain(forName: migrationSuiteName)

        // Seed legacy prompts JSON into UserDefaults under "prompts" key
        // This matches the private LegacyPrompt structure: { id, label, content }
        let legacyPrompts: [[String: String]] = [
            ["id": "legacy-1", "label": "Legacy Prompt One", "content": "Legacy content one"],
            ["id": "legacy-2", "label": "Legacy Prompt Two", "content": "Legacy content two"]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: legacyPrompts)
        migrationDefaults.set(jsonData, forKey: "prompts")

        // Ensure migration flag is NOT set so migration runs
        migrationDefaults.removeObject(forKey: "did_migrate_to_swiftdata")

        // Create store — init triggers migratePromptsFromUserDefaults()
        let inMemoryContainer = SettingsDataContainer.create(inMemory: true)
        let store = SettingsStore(defaults: migrationDefaults, container: inMemoryContainer)

        // Verify migrated prompts exist in store
        XCTAssertTrue(store.prompts.contains(where: { $0.label == "Legacy Prompt One" }))
        XCTAssertTrue(store.prompts.contains(where: { $0.label == "Legacy Prompt Two" }))

        // Verify migration flag was set
        XCTAssertTrue(migrationDefaults.bool(forKey: "did_migrate_to_swiftdata"))

        // Cleanup
        migrationDefaults.removePersistentDomain(forName: migrationSuiteName)
    }
}
