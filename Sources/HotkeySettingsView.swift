import SwiftUI
import Cocoa

struct HotkeySettingsView: View {
    @ObservedObject var settings: SettingsStore
    @StateObject var vm = HotkeySettingsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Enable Global Hotkey", isOn: Binding(
                            get: { settings.hotkeyEnabled },
                            set: { newValue in
                                vm.onHotkeyEnabledChanged(newValue)
                            }
                        ))
                        .font(.headline)

                        if settings.hotkeyEnabled {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Modifier Keys")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)

                                Picker("Modifier", selection: $vm.selectedModifierRawValue) {
                                    ForEach(SettingsViewData.modifierOptions, id: \.0) { option in
                                        Text(option.1).tag(option.0)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: vm.selectedModifierRawValue) { _, newValue in
                                    vm.onModifierChanged(newValue)
                                }

                                Text("Key")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)

                                Picker("Key", selection: $vm.selectedKeyCode) {
                                    ForEach(SettingsViewData.keyOptions, id: \.0) { option in
                                        Text(option.1).tag(option.0)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: vm.selectedKeyCode) { _, newValue in
                                    vm.onKeyCodeChanged(newValue)
                                }

                                Text("Current hotkey: \(vm.getModifierString()) + \(vm.hotkeyKeyString)")
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
                                vm.onMeetingHotkeyEnabledChanged(newValue)
                            }
                        ))
                        .font(.headline)

                        if settings.meetingHotkeyEnabled {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Modifier Keys")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)

                                Picker("Modifier", selection: $vm.meetingModifierRawValue) {
                                    ForEach(SettingsViewData.modifierOptions, id: \.0) { option in
                                        Text(option.1).tag(option.0)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: vm.meetingModifierRawValue) { _, newValue in
                                    vm.onMeetingModifierChanged(newValue)
                                }

                                Text("Key")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)

                                Picker("Key", selection: $vm.meetingKeyCode) {
                                    ForEach(SettingsViewData.meetingKeyOptions, id: \.0) { option in
                                        Text(option.1).tag(option.0)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: vm.meetingKeyCode) { _, newValue in
                                    vm.onMeetingKeyCodeChanged(newValue)
                                }

                                Text("Current hotkey: \(vm.getMeetingModifierString()) + \(vm.meetingKeyString)")
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
            vm.loadHotkeySettings()
        }
        .onChange(of: settings.hotkeyModifier) { _, newValue in
            vm.selectedModifierRawValue = newValue.rawValue
        }
        .onChange(of: settings.hotkeyKey) { _, newValue in
            vm.selectedKeyCode = newValue
            vm.hotkeyKeyString = vm.keyCodeToString(newValue)
        }
    }
}
