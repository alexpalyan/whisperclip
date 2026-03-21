import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @StateObject var llmVM = LLMModelViewModel()
    @State private var selectedLanguage: String = "auto"
    @State private var showingResetConfirmation = false
    @State private var showingDeleteModelsConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sttEngineSection
                llmModelSection
                languageSection

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Auto Actions")
                            .font(.headline)
                            .foregroundColor(.white)

                        Toggle("Auto-press Enter after paste", isOn: Binding(
                            get: { settings.autoEnter },
                            set: { newValue in
                                settings.autoEnter = newValue
                            }
                        ))

                        Text("Automatically press Enter after pasting transcribed text into the active application.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                }
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Startup Behavior")
                            .font(.headline)
                            .foregroundColor(.white)

                        Toggle("Start minimized", isOn: Binding(
                            get: { settings.startMinimized },
                            set: { newValue in
                                settings.startMinimized = newValue
                            }
                        ))

                        Text("Start the application minimized to the Dock.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                }
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recording Overlay")
                            .font(.headline)
                            .foregroundColor(.white)

                        Toggle("Display Recording Overlay", isOn: Binding(
                            get: { settings.displayRecordingOverlay },
                            set: { newValue in
                                settings.displayRecordingOverlay = newValue
                            }
                        ))

                        if settings.displayRecordingOverlay {
                            Picker("Overlay Position", selection: Binding(
                                get: { settings.overlayPosition },
                                set: { newValue in
                                    settings.overlayPosition = newValue
                                }
                            )) {
                                Text("Top Left").tag("topLeft")
                                Text("Top Right").tag("topRight")
                                Text("Bottom Left").tag("bottomLeft")
                                Text("Bottom Right").tag("bottomRight")
                            }
                            .pickerStyle(.menu)
                        }

                        Text("Show a small overlay with audio visualization when recording starts.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                }
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Storage Management")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text("Delete all downloaded AI models from your system. This will free up disk space but you'll need to re-download models when needed. Downloaded models are typically stored in your Application Support directory.")
                            .font(.body)
                            .foregroundColor(.gray)

                        HStack {
                            Button("Delete All Models (\(GenericHelper.formatSize(size: llmVM.totalModelsSize)))") {
                                showingDeleteModelsConfirmation = true
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            .disabled(llmVM.totalModelsSize == 0)

                            Spacer()
                        }
                    }
                    .padding()
                }
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
                .onAppear {
                    llmVM.refreshModelsSize()
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Reset to Defaults")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text("This will reset all settings to their default values, including language, hotkeys, and prompts. This action cannot be undone.")
                            .font(.body)
                            .foregroundColor(.gray)

                        HStack {
                            Button("Reset All Settings") {
                                showingResetConfirmation = true
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)

                            Spacer()
                        }
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
            Label("General", systemImage: "gear")
        }
        .alert("Reset Settings", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                resetSettings()
            }
        } message: {
            Text("Are you sure you want to reset all settings to their default values? This will reset language preferences, hotkeys, and all prompts. This action cannot be undone.")
        }
        .alert("Delete All Models", isPresented: $showingDeleteModelsConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                llmVM.deleteAllModels()
            }
        } message: {
            Text("Are you sure you want to delete all downloaded AI models? This will free up disk space but you'll need to re-download models when they're needed again. This action cannot be undone.")
        }
        .onAppear {
            selectedLanguage = settings.language
        }
        .onChange(of: settings.language) { _, newValue in
            selectedLanguage = newValue
        }
    }

    private var sttEngineSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Speech-to-Text Engine")
                    .font(.headline)
                    .foregroundColor(.white)

                Picker("Engine", selection: $settings.sttEngine) {
                    ForEach(STTEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: settings.sttEngine) { _, newValue in
                    if newValue == .parakeet {
                        settings.language = "auto"
                        selectedLanguage = "auto"
                    }
                }

                Text("Both engines support multiple languages. Parakeet uses CoreML/ANE for fast inference.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding()
        }
        .background(Color.gray.opacity(0.2))
        .cornerRadius(8)
    }

    private var llmModelSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI Text Model")
                    .font(.headline)
                    .foregroundColor(.white)

                Text("Select which downloaded model to use for text enhancement. You can download additional models below.")
                    .font(.caption)
                    .foregroundColor(.gray)

                VStack(spacing: 10) {
                    ForEach(LLMModels) { model in
                        let isDownloaded = ModelStorage.shared.isLLMModelDownloaded(modelName: model.id)
                        let isSelected = settings.selectedLLMModelName == model.id
                        let isDownloading = llmVM.llmDownloadInProgress && llmVM.llmDownloadModelName == model.id

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.displayName)
                                    .foregroundColor(.white)
                                    .font(.subheadline)

                                if isSelected && isDownloaded {
                                    Text("Active")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                } else if isSelected {
                                    Text("Selected (not downloaded)")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                } else if isDownloaded {
                                    Text("Downloaded")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                } else {
                                    Text("Not downloaded")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }

                            Spacer()

                            if isDownloading {
                                ProgressView(value: llmVM.llmDownloadProgress)
                                    .progressViewStyle(.linear)
                                    .frame(width: 120)
                            } else if isDownloaded {
                                if !isSelected {
                                    Button("Select") {
                                        settings.selectedLLMModelName = model.id
                                    }
                                    .buttonStyle(.bordered)
                                }

                                Button("Delete") {
                                    llmVM.deleteLLMModel(modelName: model.id)
                                }
                                .buttonStyle(.bordered)
                                .foregroundColor(.red)
                            } else {
                                Button("Download") {
                                    llmVM.downloadLLMModel(modelName: model.id)
                                }
                                .buttonStyle(.bordered)
                                .disabled(llmVM.llmDownloadInProgress)
                            }
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                    }
                }
            }
            .padding()
        }
        .background(Color.gray.opacity(0.2))
        .cornerRadius(8)
    }

    private var languageSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Transcription Language")
                    .font(.headline)
                    .foregroundColor(.white)

                Picker("Language", selection: $selectedLanguage) {
                    ForEach(SettingsViewData.languageOptions, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                }
                .pickerStyle(.menu)
                .disabled(settings.sttEngine == .parakeet)
                .onChange(of: selectedLanguage) { _, newValue in
                    settings.language = newValue
                }

                if settings.sttEngine == .parakeet {
                    Text("Parakeet automatically detects the spoken language. Language selection is only available with WhisperKit.")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else {
                    Text("Select the language for speech recognition. Auto Detect will try to identify the language automatically.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .padding()
        }
        .background(Color.gray.opacity(0.2))
        .cornerRadius(8)
    }

    private func resetSettings() {
        settings.resetToDefaults()
        selectedLanguage = settings.language
    }
}
