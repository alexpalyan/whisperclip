import SwiftUI
import Cocoa

struct HotkeySettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var selectedModifierRawValue: UInt = NSEvent.ModifierFlags.command.rawValue
    @State private var hotkeyKeyString: String = "Space"
    @State private var selectedKeyCode: UInt16 = 49
    @State private var meetingModifierRawValue: UInt = NSEvent.ModifierFlags.control.rawValue
    @State private var meetingKeyString: String = "M"
    @State private var meetingKeyCode: UInt16 = 46

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Enable Global Hotkey", isOn: Binding(
                            get: { settings.hotkeyEnabled },
                            set: { newValue in
                                settings.hotkeyEnabled = newValue
                                updateHotkey()
                            }
                        ))
                        .font(.headline)

                        if settings.hotkeyEnabled {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Modifier Keys")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)

                                Picker("Modifier", selection: $selectedModifierRawValue) {
                                    ForEach(SettingsViewData.modifierOptions, id: \.0) { option in
                                        Text(option.1).tag(option.0)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: selectedModifierRawValue) { _, newValue in
                                    let modifierFlags = NSEvent.ModifierFlags(rawValue: newValue)
                                    settings.hotkeyModifier = modifierFlags
                                    updateHotkey()
                                }

                                Text("Key")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)

                                Picker("Key", selection: $selectedKeyCode) {
                                    ForEach(SettingsViewData.keyOptions, id: \.0) { option in
                                        Text(option.1).tag(option.0)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: selectedKeyCode) { _, newValue in
                                    settings.hotkeyKey = newValue
                                    hotkeyKeyString = keyCodeToString(newValue)
                                    updateHotkey()
                                }

                                Text("Current hotkey: \(getModifierString()) + \(hotkeyKeyString)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }

                        Text("Use the global hotkey to start/stop recording from anywhere on your system.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                }
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recording Mode")
                            .font(.headline)
                            .foregroundColor(.white)

                        Toggle("Hold to talk", isOn: Binding(
                            get: { settings.holdToTalk },
                            set: { newValue in
                                settings.holdToTalk = newValue
                            }
                        ))

                        Text("When enabled, hold the hotkey to record and release to stop. When disabled, press once to start and again to stop.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                }
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Enable Meeting Hotkey", isOn: Binding(
                            get: { settings.meetingHotkeyEnabled },
                            set: { newValue in
                                settings.meetingHotkeyEnabled = newValue
                                updateMeetingHotkey()
                            }
                        ))
                        .font(.headline)

                        if settings.meetingHotkeyEnabled {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Modifier Keys")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)

                                Picker("Modifier", selection: $meetingModifierRawValue) {
                                    ForEach(SettingsViewData.modifierOptions, id: \.0) { option in
                                        Text(option.1).tag(option.0)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: meetingModifierRawValue) { _, newValue in
                                    settings.meetingHotkeyModifier = NSEvent.ModifierFlags(rawValue: newValue)
                                    updateMeetingHotkey()
                                }

                                Text("Key")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)

                                Picker("Key", selection: $meetingKeyCode) {
                                    ForEach(SettingsViewData.meetingKeyOptions, id: \.0) { option in
                                        Text(option.1).tag(option.0)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: meetingKeyCode) { _, newValue in
                                    settings.meetingHotkeyKey = newValue
                                    meetingKeyString = meetingKeyCodeToString(newValue)
                                    updateMeetingHotkey()
                                }

                                Text("Current hotkey: \(getMeetingModifierString()) + \(meetingKeyString)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }

                        Text("Use this hotkey to start/stop meeting recording from anywhere on your system.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                }
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
            }
            .padding()
        }
        .background(Color.black)
        .tabItem {
            Label("Hot Key", systemImage: "keyboard")
        }
        .onAppear {
            loadHotkeySettings()
        }
        .onChange(of: settings.hotkeyModifier) { _, newValue in
            selectedModifierRawValue = newValue.rawValue
        }
        .onChange(of: settings.hotkeyKey) { _, newValue in
            selectedKeyCode = newValue
            hotkeyKeyString = keyCodeToString(newValue)
        }
    }

    private func loadHotkeySettings() {
        selectedModifierRawValue = settings.hotkeyModifier.rawValue
        selectedKeyCode = settings.hotkeyKey
        hotkeyKeyString = keyCodeToString(settings.hotkeyKey)
        meetingModifierRawValue = settings.meetingHotkeyModifier.rawValue
        meetingKeyCode = settings.meetingHotkeyKey
        meetingKeyString = meetingKeyCodeToString(settings.meetingHotkeyKey)
    }

    private func updateHotkey() {
        HotkeyManager.shared.updateSystemHotkey(
            hotkeyEnabled: settings.hotkeyEnabled,
            modifier: settings.hotkeyModifier,
            keyCode: settings.hotkeyKey
        )
    }

    private func updateMeetingHotkey() {
        HotkeyManager.meetingShared.updateSystemHotkey(
            hotkeyEnabled: settings.meetingHotkeyEnabled,
            modifier: settings.meetingHotkeyModifier,
            keyCode: settings.meetingHotkeyKey
        )
    }

    private func getModifierString() -> String {
        let modifierRawValue = settings.hotkeyModifier.rawValue
        for option in SettingsViewData.modifierOptions {
            if option.0 == modifierRawValue {
                return option.1
            }
        }
        return "⌘ Command"
    }

    private func getMeetingModifierString() -> String {
        let modifierRawValue = settings.meetingHotkeyModifier.rawValue
        for option in SettingsViewData.modifierOptions {
            if option.0 == modifierRawValue {
                return option.1
            }
        }
        return "⌃ Control"
    }

    private func keyCodeToString(_ keyCode: UInt16) -> String {
        for option in SettingsViewData.keyOptions {
            if option.0 == keyCode {
                return option.1
            }
        }
        return "Key \(keyCode)"
    }

    private func meetingKeyCodeToString(_ keyCode: UInt16) -> String {
        for option in SettingsViewData.meetingKeyOptions {
            if option.0 == keyCode {
                return option.1
            }
        }
        return "Key \(keyCode)"
    }
}
