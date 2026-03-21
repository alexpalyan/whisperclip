import Foundation
import Cocoa

@MainActor
class HotkeySettingsViewModel: ObservableObject {
    private let store: SettingsStore
    private let hotkeyManager: any HotkeyManaging
    private let meetingHotkeyManager: any HotkeyManaging

    @Published var selectedModifierRawValue: UInt
    @Published var hotkeyKeyString: String
    @Published var selectedKeyCode: UInt16
    @Published var meetingModifierRawValue: UInt
    @Published var meetingKeyString: String
    @Published var meetingKeyCode: UInt16

    init(
        store: SettingsStore = .shared,
        hotkeyManager: any HotkeyManaging = HotkeyManager.shared,
        meetingHotkeyManager: any HotkeyManaging = HotkeyManager.meetingShared
    ) {
        self.store = store
        self.hotkeyManager = hotkeyManager
        self.meetingHotkeyManager = meetingHotkeyManager
        selectedModifierRawValue = store.hotkeyModifier.rawValue
        selectedKeyCode = store.hotkeyKey
        hotkeyKeyString = HotkeySettingsViewModel.keyCodeToString(store.hotkeyKey)
        meetingModifierRawValue = store.meetingHotkeyModifier.rawValue
        meetingKeyCode = store.meetingHotkeyKey
        meetingKeyString = HotkeySettingsViewModel.meetingKeyCodeToString(store.meetingHotkeyKey)
    }

    func loadHotkeySettings() {
        selectedModifierRawValue = store.hotkeyModifier.rawValue
        selectedKeyCode = store.hotkeyKey
        hotkeyKeyString = keyCodeToString(store.hotkeyKey)
        meetingModifierRawValue = store.meetingHotkeyModifier.rawValue
        meetingKeyCode = store.meetingHotkeyKey
        meetingKeyString = meetingKeyCodeToString(store.meetingHotkeyKey)
    }

    func updateHotkey() {
        hotkeyManager.updateSystemHotkey(
            hotkeyEnabled: store.hotkeyEnabled,
            modifier: store.hotkeyModifier,
            keyCode: store.hotkeyKey
        )
    }

    func updateMeetingHotkey() {
        meetingHotkeyManager.updateSystemHotkey(
            hotkeyEnabled: store.meetingHotkeyEnabled,
            modifier: store.meetingHotkeyModifier,
            keyCode: store.meetingHotkeyKey
        )
    }

    func getModifierString() -> String {
        let modifierRawValue = store.hotkeyModifier.rawValue
        for option in SettingsViewData.modifierOptions {
            if option.0 == modifierRawValue {
                return option.1
            }
        }
        return "⌘ Command"
    }

    func getMeetingModifierString() -> String {
        let modifierRawValue = store.meetingHotkeyModifier.rawValue
        for option in SettingsViewData.modifierOptions {
            if option.0 == modifierRawValue {
                return option.1
            }
        }
        return "⌃ Control"
    }

    func keyCodeToString(_ keyCode: UInt16) -> String {
        HotkeySettingsViewModel.keyCodeToString(keyCode)
    }

    func meetingKeyCodeToString(_ keyCode: UInt16) -> String {
        HotkeySettingsViewModel.meetingKeyCodeToString(keyCode)
    }

    func onModifierChanged(_ newValue: UInt) {
        store.hotkeyModifier = NSEvent.ModifierFlags(rawValue: newValue)
        updateHotkey()
    }

    func onKeyCodeChanged(_ newValue: UInt16) {
        store.hotkeyKey = newValue
        hotkeyKeyString = keyCodeToString(newValue)
        updateHotkey()
    }

    func onHotkeyEnabledChanged(_ newValue: Bool) {
        store.hotkeyEnabled = newValue
        updateHotkey()
    }

    func onMeetingModifierChanged(_ newValue: UInt) {
        store.meetingHotkeyModifier = NSEvent.ModifierFlags(rawValue: newValue)
        updateMeetingHotkey()
    }

    func onMeetingKeyCodeChanged(_ newValue: UInt16) {
        store.meetingHotkeyKey = newValue
        meetingKeyString = meetingKeyCodeToString(newValue)
        updateMeetingHotkey()
    }

    func onMeetingHotkeyEnabledChanged(_ newValue: Bool) {
        store.meetingHotkeyEnabled = newValue
        updateMeetingHotkey()
    }

    private static func keyCodeToString(_ keyCode: UInt16) -> String {
        for option in SettingsViewData.keyOptions {
            if option.0 == keyCode {
                return option.1
            }
        }
        return "Key \(keyCode)"
    }

    private static func meetingKeyCodeToString(_ keyCode: UInt16) -> String {
        for option in SettingsViewData.meetingKeyOptions {
            if option.0 == keyCode {
                return option.1
            }
        }
        return "Key \(keyCode)"
    }
}
