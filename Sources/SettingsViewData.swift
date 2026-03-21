import Cocoa

enum SettingsViewData {
    static let languageOptions: [(String, String)] = [
        ("auto", "Auto Detect"),
        ("en", "English"),
        ("uk", "Ukrainian"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ru", "Russian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("tr", "Turkish"),
        ("pl", "Polish"),
        ("nl", "Dutch"),
        ("sv", "Swedish"),
        ("da", "Danish"),
        ("no", "Norwegian"),
        ("fi", "Finnish")
    ]

    static let summaryLanguageOptions: [(String, String)] = [
        ("auto", "Match Transcript"),
        ("en", "English"),
        ("uk", "Ukrainian")
    ]

    static let modifierOptions: [(UInt, String)] = [
        (NSEvent.ModifierFlags.command.rawValue, "⌘ Command"),
        (NSEvent.ModifierFlags.option.rawValue, "⌥ Option"),
        (NSEvent.ModifierFlags.control.rawValue, "⌃ Control"),
        (NSEvent.ModifierFlags.shift.rawValue, "⇧ Shift"),
        (NSEvent.ModifierFlags([.command, .option]).rawValue, "⌘⌥ Command+Option"),
        (NSEvent.ModifierFlags([.command, .control]).rawValue, "⌘⌃ Command+Control"),
        (NSEvent.ModifierFlags([.command, .shift]).rawValue, "⌘⇧ Command+Shift"),
        (NSEvent.ModifierFlags([.option, .control]).rawValue, "⌥⌃ Option+Control"),
        (NSEvent.ModifierFlags([.option, .shift]).rawValue, "⌥⇧ Option+Shift"),
        (NSEvent.ModifierFlags([.control, .shift]).rawValue, "⌃⇧ Control+Shift")
    ]

    static let meetingKeyOptions: [(UInt16, String)] = [
        (46, "M"), (45, "N"), (15, "R"), (49, "Space"), (36, "Return"),
        (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"), (101, "F9"),
        (109, "F10"), (103, "F11"), (111, "F12"), (105, "F13"), (107, "F14"), (113, "F15")
    ]

    static let keyOptions: [(UInt16, String)] = [
        (49, "Space"), (36, "Return"), (48, "Tab"), (51, "Delete"), (53, "Escape"),
        (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"), (101, "F9"),
        (109, "F10"), (103, "F11"), (111, "F12"), (105, "F13"), (107, "F14"), (113, "F15")
    ]
}
