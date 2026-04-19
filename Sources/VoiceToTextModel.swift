import Foundation
import WhisperKit

@MainActor
class VoiceToTextModel: VoiceToTextProtocol {
    static let shared = VoiceToTextModel()
    private var pipe: WhisperKit?

    private init() {
        self.pipe = nil
    }

    func load() async throws {

        if self.pipe == nil {
            self.pipe = try await LocalWhisperKit.loadModel(modelRepo: CurrentSTTModelRepo, modelName: CurrentSTTModelName)
        }

        if self.pipe == nil {
            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load voice-to-text model. Please try again later."])
        }
    }

    func process(filepath: String) async throws -> String {
        try await load()
        guard let pipe else {
            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load voice-to-text model. Please try again later."])
        }

        let language = SettingsStore.shared.language
        let languageCode = language == "auto" ? nil : language

        if GenericHelper.logSensitiveData() {
            Logger.log("Sending transcription query to WhisperKit with lang: \(languageCode ?? "auto")", log: Logger.general)
        }
        let ts = TimeSpenter()

        let results = try await pipe.transcribe(
            audioPath: filepath,
            decodeOptions: DecodingOptions(
                language: languageCode,
                usePrefillPrompt: true,
                detectLanguage: language == "auto",
                compressionRatioThreshold: 2.0,
                logProbThreshold: -0.5,
                noSpeechThreshold: 0.3
            )
        )
        let transcription = results.first?.text
        if GenericHelper.logSensitiveData() {
            Logger.log("Received transcription result from WhisperKit in \(ts.getDelay()) us", log: Logger.general)
        }

        if transcription == nil {
            Logger.log("No transcription result received", log: Logger.general, type: .error)

            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No transcription result received"])
        }

        return transcription!
    }

    func processStream(
        filepath: String,
        onEvent: @escaping @MainActor @Sendable (StreamingTranscriptionEvent) -> Void,
        onToken: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        try await load()
        guard let pipe else {
            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load voice-to-text model. Please try again later."])
        }

        let language = SettingsStore.shared.language
        let languageCode = language == "auto" ? nil : language
        let ts = TimeSpenter()
        var lastPartialText = ""
        var didEmitFirstToken = false

        if GenericHelper.logSensitiveData() {
            Logger.log("Sending streaming transcription query to WhisperKit with lang: \(languageCode ?? "auto")", log: Logger.general)
        }

        pipe.transcriptionStateCallback = { state in
            Task { @MainActor in
                switch state {
                case .convertingAudio:
                    onEvent(.convertingAudio)
                case .transcribing:
                    onEvent(.decodingStarted)
                case .finished:
                    onEvent(.finished)
                }
            }
        }

        defer {
            pipe.transcriptionStateCallback = nil
        }

        let results = try await pipe.transcribe(
            audioPath: filepath,
            decodeOptions: DecodingOptions(
                language: languageCode,
                usePrefillPrompt: true,
                detectLanguage: language == "auto",
                compressionRatioThreshold: 2.0,
                logProbThreshold: -0.5,
                noSpeechThreshold: 0.3
            ),
            callback: { progress in
                let partialText = progress.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !didEmitFirstToken, !progress.tokens.isEmpty {
                    didEmitFirstToken = true
                    Task { @MainActor in
                        onEvent(.firstToken)
                    }
                }
                guard !partialText.isEmpty, partialText != lastPartialText else {
                    return nil
                }
                lastPartialText = partialText
                Task { @MainActor in
                    onToken(partialText)
                }
                return nil
            }
        )

        if GenericHelper.logSensitiveData() {
            Logger.log("Received streaming transcription result from WhisperKit in \(ts.getDelay()) us", log: Logger.general)
        }

        guard let transcription = results.first?.text else {
            Logger.log("No streaming transcription result received", log: Logger.general, type: .error)
            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No transcription result received"])
        }

        let normalized = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty, normalized != lastPartialText {
            await MainActor.run {
                onToken(normalized)
            }
        }

        if !normalized.isEmpty {
            return transcription
        }

        if !lastPartialText.isEmpty {
            if GenericHelper.logSensitiveData() {
                Logger.log(
                    "WhisperKit returned empty final text; falling back to last partial text",
                    log: Logger.general
                )
            }
            return lastPartialText
        }

        return transcription
    }
}
