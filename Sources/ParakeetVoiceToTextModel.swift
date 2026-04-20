import Foundation
import AVFoundation
import FluidAudio

class ParakeetVoiceToTextModel: VoiceToTextProtocol {
    static let shared = ParakeetVoiceToTextModel()
    private var manager: AsrManager?
    private var streamingSessionMic: StreamingEouAsrManager?
    private var streamingSessionSystem: StreamingEouAsrManager?
    private var latestStreamingText: [AudioSource: String] = [:]
    private var finalizedStreamingText: [AudioSource: String] = [:]
    var onEOU: (@MainActor @Sendable (AudioSource) -> Void)?

    private init() {
        self.manager = nil
    }

    func load() async throws {
        // Always reload to ensure manager is valid (handles stale cache)
        do {
            self.manager = try await LocalParakeet.loadModel()
        } catch {
            // Clear manager on failure
            self.manager = nil
            throw error
        }

        guard let manager = self.manager, manager.isAvailable else {
            self.manager = nil
            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load Parakeet model. Please try again later."])
        }
    }

    func process(filepath: String) async throws -> String {
        try await load()

        guard let manager = self.manager else {
            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Parakeet manager not available"])
        }

        if GenericHelper.logSensitiveData() {
            Logger.log("Sending transcription query to Parakeet (FluidAudio)", log: Logger.general)
        }
        let ts = TimeSpenter()

        // Transcribe using FluidAudio's URL-based API
        let audioURL = URL(fileURLWithPath: filepath)
        let result = try await manager.transcribe(audioURL)
        let transcription = result.text

        if GenericHelper.logSensitiveData() {
            Logger.log("Received transcription result from Parakeet in \(ts.getDelay()) us", log: Logger.general)
            Logger.log("Parakeet transcription: '\(transcription)'", log: Logger.general)
        }

        if transcription.isEmpty {
            Logger.log("No transcription result received from Parakeet", log: Logger.general, type: .error)
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

        guard let manager = self.manager else {
            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Parakeet manager not available"])
        }

        if GenericHelper.logSensitiveData() {
            Logger.log("Sending streaming transcription query to Parakeet (FluidAudio)", log: Logger.general)
        }
        let ts = TimeSpenter()
        await MainActor.run {
            onEvent(.convertingAudio)
            onEvent(.decodingStarted)
        }

        let audioURL = URL(fileURLWithPath: filepath)
        let result = try await manager.transcribe(audioURL)
        let transcription = result.text

        if GenericHelper.logSensitiveData() {
            Logger.log("Received streaming transcription result from Parakeet in \(ts.getDelay()) us", log: Logger.general)
            Logger.log("Parakeet streaming transcription: '\(transcription)'", log: Logger.general)
        }

        if !transcription.isEmpty {
            await MainActor.run {
                onEvent(.firstToken)
                onToken(transcription)
            }
        }

        await MainActor.run {
            onEvent(.finished)
        }

        return transcription
    }

    func startStreamingSession(source: AudioSource) async throws {
        guard session(for: source) == nil else { return }

        let session = StreamingEouAsrManager(chunkSize: .ms160)
        latestStreamingText[source] = ""
        finalizedStreamingText[source] = ""
        await session.setPartialCallback { _ in }
        await session.setEouCallback { [weak self] _ in
            Task { @MainActor in
                self?.onEOU?(source)
            }
        }
        try await session.loadModels(modelDir: streamingModelsDirectory())
        setSession(session, for: source)
    }

    func feedFragment(
        _ samples: [Float],
        source: AudioSource,
        onToken: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        guard !samples.isEmpty else { return }
        try await startStreamingSession(source: source)
        guard let session = session(for: source) else { return }

        await session.setPartialCallback { text in
            self.latestStreamingText[source] = text
            let truncatedText = applyLastWordTruncation(text)
            Task { @MainActor in
                onToken(truncatedText)
            }
        }

        let buffer = try audioBuffer(from: samples)
        _ = try await session.process(audioBuffer: buffer)
    }

    func bestStreamingText(source: AudioSource) async -> String? {
        let finalizedText = finalizedStreamingText[source]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !finalizedText.isEmpty {
            return finalizedText
        }

        let latestText = latestStreamingText[source]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !latestText.isEmpty {
            return latestText
        }

        return nil
    }

    func finalizeStreamingText(source: AudioSource) async throws -> String? {
        let finalizedText = finalizedStreamingText[source]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !finalizedText.isEmpty {
            return finalizedText
        }

        guard let session = session(for: source) else {
            return await bestStreamingText(source: source)
        }

        let transcript = try await session.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
            finalizedStreamingText[source] = transcript
            latestStreamingText[source] = transcript
            return transcript
        }

        return await bestStreamingText(source: source)
    }

    func finalizeStreamingText(samples: [Float], source: AudioSource) async throws -> String? {
        let streamingTranscript = try await finalizeStreamingText(source: source)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !streamingTranscript.isEmpty {
            return streamingTranscript
        }

        let offlineTranscript = try await transcribeSamplesOffline(samples)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !offlineTranscript.isEmpty {
            finalizedStreamingText[source] = offlineTranscript
            latestStreamingText[source] = offlineTranscript
            return offlineTranscript
        }

        return nil
    }

    func stopStreamingSession(source: AudioSource) async throws {
        guard let session = session(for: source) else { return }
        if finalizedStreamingText[source]?.isEmpty ?? true {
            let transcript = try await session.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                finalizedStreamingText[source] = transcript
                latestStreamingText[source] = transcript
            }
        }
        await session.reset()
        setSession(nil, for: source)
        latestStreamingText[source] = nil
        finalizedStreamingText[source] = nil
    }

    private func session(for source: AudioSource) -> StreamingEouAsrManager? {
        switch source {
        case .microphone:
            return streamingSessionMic
        case .system:
            return streamingSessionSystem
        }
    }

    private func setSession(_ session: StreamingEouAsrManager?, for source: AudioSource) {
        switch source {
        case .microphone:
            streamingSessionMic = session
        case .system:
            streamingSessionSystem = session
        }
    }

    private func streamingModelsDirectory() -> URL {
        return LocalParakeet.getStreamingModelsDirectory(chunkSize: .ms160)
    }

    func transcribeSamplesForPreview(_ samples: [Float]) async throws -> String {
        try await transcribeSamplesOffline(samples)
    }

    private func transcribeSamplesOffline(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { return "" }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet_stream_finalize_\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try writeWAVFile(samples: samples, to: tempURL)
        let manager = try await LocalParakeet.loadModel()
        let result = try await manager.transcribe(tempURL)
        return result.text
    }

    private func audioBuffer(from samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw NSError(
                domain: "Transcriber",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create streaming audio buffer"]
            )
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw NSError(
                domain: "Transcriber",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to access streaming audio channel data"]
            )
        }

        channelData.update(from: samples, count: samples.count)
        return buffer
    }

    private func writeWAVFile(samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw NSError(
                domain: "Transcriber",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create Parakeet finalize buffer"]
            )
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw NSError(
                domain: "Transcriber",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to access Parakeet finalize buffer channel data"]
            )
        }

        channelData.update(from: samples, count: samples.count)
        let outputFile = try AVAudioFile(forWriting: url, settings: format.settings)
        try outputFile.write(from: buffer)
    }
}
