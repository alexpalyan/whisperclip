import Foundation
import WhisperKit

@MainActor
class VoiceToTextModel: VoiceToTextProtocol {
    static let shared = VoiceToTextModel()
    private var pipe: WhisperKit?
    private var loadingTask: Task<WhisperKit, Error>?
    private var slidingBuffers: [AudioSource: [Float]] = [:]
    private var lastTranscriptions: [AudioSource: String] = [:]
    private var committedPrefixes: [AudioSource: String] = [:]
    private var previewTexts: [AudioSource: String] = [:]
    private let maxSlidingWindowSeconds: Double = 5.0
    private let streamingSampleRate: Int = 16000

    private init() {
        self.pipe = nil
    }

    func load() async throws {
        if pipe != nil {
            return
        }

        if let loadingTask {
            self.pipe = try await loadingTask.value
        } else {
            let task = Task {
                try await LocalWhisperKit.loadModel(
                    modelRepo: CurrentSTTModelRepo,
                    modelName: CurrentSTTModelName
                )
            }
            loadingTask = task

            do {
                self.pipe = try await task.value
            } catch {
                loadingTask = nil
                throw error
            }
        }

        loadingTask = nil

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
        let transcription = sanitizeWhisperKitText(results.first?.text ?? "")
        if GenericHelper.logSensitiveData() {
            Logger.log("Received transcription result from WhisperKit in \(ts.getDelay()) us", log: Logger.general)
        }

        if transcription.isEmpty {
            Logger.log("No transcription result received", log: Logger.general, type: .error)

            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No transcription result received"])
        }

        return transcription
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
                @unknown default:
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
                let partialText = sanitizeWhisperKitText(progress.text)
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

        let transcription = sanitizeWhisperKitText(results.first?.text ?? "")
        guard !transcription.isEmpty else {
            Logger.log("No streaming transcription result received", log: Logger.general, type: .error)
            let fallbackPartial = sanitizeWhisperKitText(lastPartialText)
            if !fallbackPartial.isEmpty {
                if GenericHelper.logSensitiveData() {
                    Logger.log(
                        "WhisperKit returned empty final text; falling back to sanitized last partial text",
                        log: Logger.general
                    )
                }
                return fallbackPartial
            }
            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No transcription result received"])
        }

        let normalized = transcription
        if !normalized.isEmpty, normalized != lastPartialText {
            await MainActor.run {
                onToken(normalized)
            }
        }

        if !normalized.isEmpty {
            return transcription
        }

        if !lastPartialText.isEmpty {
            let fallbackPartial = sanitizeWhisperKitText(lastPartialText)
            guard !fallbackPartial.isEmpty else {
                return transcription
            }
            if GenericHelper.logSensitiveData() {
                Logger.log(
                    "WhisperKit returned empty final text; falling back to sanitized last partial text",
                    log: Logger.general
                )
            }
            return fallbackPartial
        }

        return transcription
    }

    func startStreamingSession(source: AudioSource) async throws {
        try await load()
        // Always reset source-local streaming state when a new utterance starts.
        // Otherwise a fast next speech-start can inherit the previous utterance's
        // sliding buffer and committed prefix before the old finalize task stops it.
        slidingBuffers[source] = []
        lastTranscriptions[source] = ""
        committedPrefixes[source] = ""
        previewTexts[source] = ""
    }

    func feedFragment(
        _ samples: [Float],
        source: AudioSource,
        onToken: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        guard !samples.isEmpty else { return }
        try await load()
        guard let pipe else {
            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load voice-to-text model. Please try again later."])
        }

        var buffer = slidingBuffers[source] ?? []
        buffer.append(contentsOf: samples)

        let maxSamples = Int(maxSlidingWindowSeconds * Double(streamingSampleRate))
        if buffer.count > maxSamples {
            buffer.removeFirst(buffer.count - maxSamples)
        }
        slidingBuffers[source] = buffer

        let language = SettingsStore.shared.language
        let languageCode = language == "auto" ? nil : language
        let results = try await pipe.transcribe(
            audioArray: buffer,
            decodeOptions: DecodingOptions(
                language: languageCode,
                usePrefillPrompt: true,
                detectLanguage: language == "auto",
                compressionRatioThreshold: 2.0,
                logProbThreshold: -0.5,
                noSpeechThreshold: 0.3
            )
        )

        let currentText = sanitizeWhisperKitText(results.first?.text ?? "")
        let previousText = lastTranscriptions[source] ?? ""
        lastTranscriptions[source] = currentText

        let lcpText: String
        if previousText.isEmpty {
            lcpText = currentText
        } else {
            lcpText = calculateLCP(currentText, previousText)
        }

        let truncatedText = applyLastWordTruncation(lcpText)
        let committedText = committedPrefixes[source] ?? ""
        let nextCommittedText = truncatedText.hasPrefix(committedText) ? truncatedText : committedText
        if nextCommittedText != committedText {
            committedPrefixes[source] = nextCommittedText
        }

        let previousPreviewText = previewTexts[source] ?? committedPrefixes[source] ?? ""
        let nextPreviewText = mergedPreviewText(
            committedText: committedPrefixes[source] ?? "",
            previousPreviewText: previousPreviewText,
            currentText: currentText
        )
        previewTexts[source] = nextPreviewText

        guard nextPreviewText != previousPreviewText || nextCommittedText != committedText else { return }
        onToken(nextPreviewText)
    }

    func stopStreamingSession(source: AudioSource) async throws {
        slidingBuffers[source] = nil
        lastTranscriptions[source] = nil
        committedPrefixes[source] = nil
        previewTexts[source] = nil
    }

    func bestStreamingText(source: AudioSource) async -> String? {
        let currentText = sanitizeWhisperKitText(lastTranscriptions[source] ?? "")
        let previewText = sanitizeWhisperKitText(previewTexts[source] ?? "")
        let committedText = sanitizeWhisperKitText(committedPrefixes[source] ?? "")

        if !currentText.isEmpty {
            return currentText
        }
        if !previewText.isEmpty {
            return previewText
        }
        if !committedText.isEmpty {
            return committedText
        }
        return nil
    }

    func finalizeStreamingText(source: AudioSource) async throws -> String? {
        try await load()
        guard let pipe else { return await bestStreamingText(source: source) }
        guard let buffer = slidingBuffers[source], !buffer.isEmpty else {
            return await bestStreamingText(source: source)
        }

        let language = SettingsStore.shared.language
        let languageCode = language == "auto" ? nil : language
        let results = try await pipe.transcribe(
            audioArray: buffer,
            decodeOptions: DecodingOptions(
                language: languageCode,
                usePrefillPrompt: true,
                detectLanguage: language == "auto",
                compressionRatioThreshold: 2.0,
                logProbThreshold: -0.5,
                noSpeechThreshold: 0.3
            )
        )

        let finalizedText = sanitizeWhisperKitText(results.first?.text ?? "")
        if !finalizedText.isEmpty {
            lastTranscriptions[source] = finalizedText
            previewTexts[source] = finalizedText
            committedPrefixes[source] = finalizedText
            return finalizedText
        }

        return await bestStreamingText(source: source)
    }

    func finalizeStreamingText(samples: [Float], source: AudioSource) async throws -> String? {
        guard !samples.isEmpty else { return await bestStreamingText(source: source) }
        try await load()
        guard let pipe else { return await bestStreamingText(source: source) }

        let language = SettingsStore.shared.language
        let languageCode = language == "auto" ? nil : language
        let results = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(
                language: languageCode,
                usePrefillPrompt: true,
                detectLanguage: language == "auto",
                compressionRatioThreshold: 2.0,
                logProbThreshold: -0.5,
                noSpeechThreshold: 0.3
            )
        )

        let finalizedText = sanitizeWhisperKitText(results.first?.text ?? "")
        if !finalizedText.isEmpty {
            return finalizedText
        }

        return await bestStreamingText(source: source)
    }
}

// MARK: - Streaming Helpers

func calculateLCP(_ a: String, _ b: String) -> String {
    guard !a.isEmpty, !b.isEmpty else { return "" }

    var commonEnd = a.startIndex
    var ai = a.startIndex
    var bi = b.startIndex

    while ai < a.endIndex, bi < b.endIndex, a[ai] == b[bi] {
        if a[ai] == " " {
            commonEnd = a.index(after: ai)
        }
        ai = a.index(after: ai)
        bi = b.index(after: bi)
    }

    if ai == a.endIndex, bi == b.endIndex {
        return a
    }

    return String(a[..<commonEnd])
}

func applyLastWordTruncation(_ text: String) -> String {
    guard !text.isEmpty else { return "" }

    let terminators: Set<Character> = [" ", ".", ",", "!", "?", ":", ";", "…", "\n"]
    if let lastCharacter = text.last, terminators.contains(lastCharacter) {
        return text
    }

    guard let lastSpaceIndex = text.lastIndex(of: " ") else {
        return ""
    }

    return String(text[...lastSpaceIndex])
}

func mergedPreviewText(committedText: String, previousPreviewText: String, currentText: String) -> String {
    let committed = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
    let previewCandidate = applyLastWordTruncation(currentText)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let previousPreview = previousPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)

    if previewCandidate.isEmpty {
        return committedText.isEmpty ? previousPreviewText : committedText
    }

    if committed.isEmpty {
        if previewCandidate.count >= previousPreview.count {
            return previewCandidate
        }
        return previousPreviewText
    }

    if previewCandidate.hasPrefix(committed) {
        if previewCandidate.count >= previousPreview.count {
            return previewCandidate
        }
        return previousPreviewText
    }

    return committedText
}

func sanitizeWhisperKitText(_ text: String) -> String {
    guard !text.isEmpty else { return "" }

    let tagPattern = #"<\|[^|>]+?\|>"#
    let withoutTags = text.replacingOccurrences(
        of: tagPattern,
        with: " ",
        options: .regularExpression
    )

    let withoutLeadingDecorators = withoutTags.replacingOccurrences(
        of: #"^\s*[-–—:,]+\s*"#,
        with: "",
        options: .regularExpression
    )

    let collapsedWhitespace = withoutLeadingDecorators.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )

    return collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
}
