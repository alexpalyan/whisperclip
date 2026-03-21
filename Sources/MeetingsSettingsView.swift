import SwiftUI

struct MeetingsSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var selectedSummaryLanguage: String = "auto"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Enable Meeting Auto-Detection", isOn: Binding(
                            get: { settings.meetingAutoDetect },
                            set: { newValue in
                                settings.meetingAutoDetect = newValue
                            }
                        ))
                        .font(.headline)

                        Text("Automatically detect when meeting apps (Zoom, Teams, Meet, etc.) are running and offer to record.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                }
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Automatic Recording")
                            .font(.headline)
                            .foregroundColor(.white)

                        Toggle("Auto-start recording when meeting detected", isOn: Binding(
                            get: { settings.meetingAutoStart },
                            set: { newValue in
                                settings.meetingAutoStart = newValue
                            }
                        ))
                        .disabled(!settings.meetingAutoDetect)

                        Text("Begin recording immediately when a meeting app is detected.")
                            .font(.caption)
                            .foregroundColor(.gray)

                        Divider()

                        Toggle("Auto-stop recording when meeting ends", isOn: Binding(
                            get: { settings.meetingAutoStop },
                            set: { newValue in
                                settings.meetingAutoStop = newValue
                            }
                        ))
                        .disabled(!settings.meetingAutoDetect)

                        autoStopDelaySection
                    }
                    .padding()
                }
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Auto-generate summary after meeting", isOn: Binding(
                            get: { settings.meetingAutoSummary },
                            set: { newValue in
                                settings.meetingAutoSummary = newValue
                            }
                        ))
                        .font(.headline)

                        Text("Automatically generate an AI summary, action items, and decisions when a meeting ends. Requires a downloaded AI model.")
                            .font(.caption)
                            .foregroundColor(.gray)

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Summary Language")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.white)

                            Picker("Summary Language", selection: $selectedSummaryLanguage) {
                                ForEach(SettingsViewData.summaryLanguageOptions, id: \.0) { option in
                                    Text(option.1).tag(option.0)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: selectedSummaryLanguage) { _, newValue in
                                settings.meetingSummaryLanguage = newValue
                            }

                            Text("Choose the language for AI summaries. Match Transcript will keep the output in the meeting's language.")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding()
                }
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)

                monitoredAppsSection
            }
            .padding()
        }
        .background(Color.black)
        .tabItem {
            Label("Meetings", systemImage: "text.bubble.fill")
        }
        .onAppear {
            selectedSummaryLanguage = settings.meetingSummaryLanguage
        }
        .onChange(of: settings.meetingSummaryLanguage) { _, newValue in
            selectedSummaryLanguage = newValue
        }
    }

    @ViewBuilder
    private var autoStopDelaySection: some View {
        if settings.meetingAutoStop && settings.meetingAutoDetect {
            VStack(alignment: .leading, spacing: 8) {
                Text("Stop delay: \(Int(settings.meetingAutoStopDelay)) seconds")
                    .font(.subheadline)
                    .foregroundColor(.white)

                Slider(
                    value: Binding(
                        get: { settings.meetingAutoStopDelay },
                        set: { newValue in
                            settings.meetingAutoStopDelay = newValue
                        }
                    ),
                    in: 0...30,
                    step: 1
                )

                Text("Wait this long after the meeting app closes before stopping the recording. Helps avoid false stops if the app is briefly hidden.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        } else {
            Text("Stop recording after the meeting app closes, with a configurable delay.")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }

    private var monitoredAppsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("Monitored Apps")
                    .font(.headline)
                    .foregroundColor(.white)

                Text("Choose which meeting applications to watch for. Only selected apps will trigger auto-detection.")
                    .font(.caption)
                    .foregroundColor(.gray)

                let detectableApps: [MeetingSource] = [.zoom, .teams, .meet, .webex, .slack, .discord, .facetime]

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(detectableApps, id: \.self) { source in
                        Toggle(isOn: Binding(
                            get: { settings.meetingDetectedApps.contains(source.rawValue) },
                            set: { enabled in
                                if enabled {
                                    if !settings.meetingDetectedApps.contains(source.rawValue) {
                                        settings.meetingDetectedApps.append(source.rawValue)
                                    }
                                } else {
                                    settings.meetingDetectedApps.removeAll { $0 == source.rawValue }
                                }
                            }
                        )) {
                            HStack(spacing: 8) {
                                Image(systemName: source.icon)
                                    .font(.system(size: 14))
                                    .foregroundColor(.teal)
                                    .frame(width: 20)
                                Text(source.rawValue)
                                    .font(.system(size: 13))
                            }
                        }
                        .disabled(!settings.meetingAutoDetect)
                    }
                }
            }
            .padding()
        }
        .background(Color.gray.opacity(0.2))
        .cornerRadius(8)
    }
}
