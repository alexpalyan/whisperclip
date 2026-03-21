import XCTest
import Cocoa
@testable import WhisperClip

struct NullHotkeyManager: HotkeyManaging {
    func updateSystemHotkey(hotkeyEnabled: Bool, modifier: NSEvent.ModifierFlags, keyCode: UInt16) {}
}

@MainActor
final class HotkeySettingsViewModelTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var store: SettingsStore!
    private var vm: HotkeySettingsViewModel!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.whisperclip.tests.hotkey")!
        testDefaults.removePersistentDomain(forName: "com.whisperclip.tests.hotkey")
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
        testDefaults.removePersistentDomain(forName: "com.whisperclip.tests.hotkey")
        testDefaults = nil
        super.tearDown()
    }

    func testKeyCodeToStringSpace() {
        XCTAssertEqual(vm.keyCodeToString(49), "Space")
    }

    func testKeyCodeToStringF5() {
        XCTAssertEqual(vm.keyCodeToString(96), "F5")
    }

    func testGetModifierStringSingleOption() {
        store.hotkeyModifier = .option
        vm.loadHotkeySettings()
        XCTAssertTrue(vm.getModifierString().contains("Option"))
    }

    func testGetModifierStringCombinedCommandOption() {
        store.hotkeyModifier = [.command, .option]
        vm.loadHotkeySettings()
        let modifier = vm.getModifierString()
        XCTAssertTrue(modifier.contains("Command"))
        XCTAssertTrue(modifier.contains("Option"))
    }

    func testOnKeyCodeChangedPersistsToStore() {
        vm.onKeyCodeChanged(49)
        XCTAssertEqual(store.hotkeyKey, 49)
    }
}
