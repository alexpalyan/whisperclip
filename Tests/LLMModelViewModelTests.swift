import XCTest
@testable import WhisperClip

@MainActor
final class LLMModelViewModelTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var store: SettingsStore!
    private var vm: LLMModelViewModel!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.whisperclip.tests.llm-model")!
        testDefaults.removePersistentDomain(forName: "com.whisperclip.tests.llm-model")
        store = SettingsStore(defaults: testDefaults)
        vm = LLMModelViewModel(store: store)
    }

    override func tearDown() {
        vm = nil
        store = nil
        testDefaults.removePersistentDomain(forName: "com.whisperclip.tests.llm-model")
        testDefaults = nil
        super.tearDown()
    }

    func testRefreshModelsSizeReturnsNonNegative() {
        vm.refreshModelsSize()
        XCTAssertGreaterThanOrEqual(vm.totalModelsSize, 0)
    }

    func testDeleteLLMModelUpdatesFallback() {
        let fakeName = "nonexistent-model-for-test"
        store.selectedLLMModelName = fakeName

        vm.deleteLLMModel(modelName: fakeName)

        XCTAssertNotEqual(store.selectedLLMModelName, fakeName)
    }
}
