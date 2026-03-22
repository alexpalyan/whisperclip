import Cocoa
import Carbon.HIToolbox
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let recording = Self("recording")
    static let meetingRecording = Self("meetingRecording")
}

protocol HotkeyManaging {
    func updateSystemHotkey(hotkeyEnabled: Bool, modifier: NSEvent.ModifierFlags, keyCode: UInt16)
}

class HotkeyManager: ObservableObject, HotkeyManaging {
    var action: () -> Void = {}
    var keyUpAction: () -> Void = {}
    var currentModifier: NSEvent.ModifierFlags?
    var currentKeyCode: UInt16?
    private let name: KeyboardShortcuts.Name
    private var isEnabled: Bool = false

    static let shared = HotkeyManager(shortcutName: .recording)
    static let meetingShared = HotkeyManager(shortcutName: .meetingRecording)

    private init(shortcutName: KeyboardShortcuts.Name) {
        self.name = shortcutName
        KeyboardShortcuts.onKeyDown(for: shortcutName) { [weak self] in self?.action() }
        KeyboardShortcuts.onKeyUp(for: shortcutName) { [weak self] in self?.keyUpAction() }
    }

    func setAction(action: @escaping () -> Void) {
        self.action = action
    }

    func setKeyUpAction(action: @escaping () -> Void) {
        self.keyUpAction = action
    }

    func updateSystemHotkey(hotkeyEnabled: Bool, modifier: NSEvent.ModifierFlags, keyCode: UInt16) {
        if currentModifier == modifier && currentKeyCode == keyCode && isEnabled == hotkeyEnabled {
            Logger.log("Same hotkey combination already active, skipping", log: Logger.hotkey)
            return
        }
        currentModifier = modifier
        currentKeyCode = keyCode
        isEnabled = hotkeyEnabled

        if hotkeyEnabled {
            var carbonModifiers = 0
            if modifier.contains(.control) { carbonModifiers |= controlKey }
            if modifier.contains(.option)  { carbonModifiers |= optionKey }
            if modifier.contains(.shift)   { carbonModifiers |= shiftKey }
            if modifier.contains(.command) { carbonModifiers |= cmdKey }
            let shortcut = KeyboardShortcuts.Shortcut(
                carbonKeyCode: Int(keyCode),
                carbonModifiers: carbonModifiers
            )
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            KeyboardShortcuts.enable(name)
            Logger.log("Hotkey registered for \(name.rawValue): modifier=\(modifier), keyCode=\(keyCode)", log: Logger.hotkey)
        } else {
            KeyboardShortcuts.disable(name)
            Logger.log("Hotkey disabled for \(name.rawValue)", log: Logger.hotkey)
        }
    }

    deinit {
        KeyboardShortcuts.disable(name)
    }
}
