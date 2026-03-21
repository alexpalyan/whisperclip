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
}
