import XCTest
import SwiftData
@testable import WhisperClip

@MainActor
final class PromptManagementViewModelTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var store: SettingsStore!
    private var vm: PromptManagementViewModel!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.whisperclip.tests.prompt-management")!
        testDefaults.removePersistentDomain(forName: "com.whisperclip.tests.prompt-management")
        let inMemoryContainer = SettingsDataContainer.create(inMemory: true)
        store = SettingsStore(defaults: testDefaults, container: inMemoryContainer)
        vm = PromptManagementViewModel(store: store)
    }

    override func tearDown() {
        vm = nil
        store = nil
        testDefaults.removePersistentDomain(forName: "com.whisperclip.tests.prompt-management")
        testDefaults = nil
        super.tearDown()
    }

    func testCreateNewPromptAppends() {
        let initialCount = store.prompts.count

        vm.newPromptLabel = "Test Prompt"
        vm.newPromptContent = "Test content"
        vm.createNewPrompt()

        XCTAssertEqual(store.prompts.count, initialCount + 1)
        XCTAssertTrue(store.prompts.contains(where: { $0.label == "Test Prompt" }))
    }

    func testSavePromptEditsUpdatesLabel() {
        let prompt = store.prompts.first!

        vm.startEditing(prompt)
        vm.editingPromptLabel = "Updated Label"
        vm.savePromptEdits(prompt.id)

        XCTAssertEqual(store.prompts.first(where: { $0.id == prompt.id })?.label, "Updated Label")
    }

    func testCancelEditingClearsState() {
        let prompt = store.prompts.first!

        vm.startEditing(prompt)
        XCTAssertNotNil(vm.editingPromptId)

        vm.cancelEditing()

        XCTAssertNil(vm.editingPromptId)
        XCTAssertEqual(vm.editingPromptLabel, "")
        XCTAssertEqual(vm.editingPromptContent, "")
    }

    func testDeletePromptRemovesFromStore() {
        let prompt = store.prompts.first!
        let promptId = prompt.id

        vm.deletePrompt(promptId)

        XCTAssertFalse(store.prompts.contains(where: { $0.id == promptId }))
    }
}
