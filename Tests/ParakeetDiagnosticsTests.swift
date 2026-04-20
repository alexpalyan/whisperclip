import AVFoundation
import XCTest
import FluidAudio
@testable import WhisperClip

final class ParakeetDiagnosticsTests: XCTestCase {
    private let liveLikeChunkSize = 2_560

    func testParakeetEnglishFixtureDiagnostics() async throws {
        try await runFixtureDiagnostics(baseName: "parakeet_en")
    }

    func testParakeetUkrainianFixtureDiagnostics() async throws {
        try await runFixtureDiagnostics(baseName: "parakeet_uk")
    }

    private func runFixtureDiagnostics(baseName: String) async throws {
        guard ProcessInfo.processInfo.environment["RUN_PARAKEET_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_PARAKEET_INTEGRATION=1 to run Parakeet integration diagnostics.")
        }

        guard LocalParakeet.modelsExist() else {
            throw XCTSkip("Offline Parakeet models are not installed.")
        }

        guard LocalParakeet.streamingModelsExist() else {
            throw XCTSkip("Streaming Parakeet models are not installed.")
        }

        let fixtureURL = fixtureFileURL(named: "\(baseName).wav")
        let expectedTextURL = fixtureFileURL(named: "\(baseName).txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedTextURL.path))

        let expectedText = try String(contentsOf: expectedTextURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let offlineDirect = try await directOfflineTranscript(for: fixtureURL)
        let wrapperBatch = await wrapperBatchTranscript(for: fixtureURL)
        let directStreaming = try await directStreamingTranscript(for: fixtureURL)
        let wrapperStreaming = try await wrapperStreamingTranscript(for: fixtureURL)

        let diagnostic = """
        fixture: \(baseName)
        expected: \(expectedText)
        offlineDirect: \(offlineDirect)
        wrapperBatch: \(wrapperBatch)
        directStreaming: \(directStreaming)
        wrapperStreaming: \(wrapperStreaming)
        """

        XCTAssertFalse(offlineDirect.isEmpty, "Direct offline Parakeet transcript is empty.\n\(diagnostic)")
        XCTAssertFalse(wrapperBatch.isEmpty, "Wrapper batch Parakeet transcript is empty.\n\(diagnostic)")
        XCTAssertFalse(directStreaming.isEmpty, "Direct streaming Parakeet transcript is empty.\n\(diagnostic)")
        XCTAssertFalse(wrapperStreaming.isEmpty, "Wrapper streaming Parakeet transcript is empty.\n\(diagnostic)")
    }

    private func fixtureFileURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func directOfflineTranscript(for url: URL) async throws -> String {
        let manager = try await LocalParakeet.loadModel()
        let result = try await manager.transcribe(url)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wrapperBatchTranscript(for url: URL) async -> String {
        do {
            return try await ParakeetVoiceToTextModel.shared.process(filepath: url.path)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    private func directStreamingTranscript(for url: URL) async throws -> String {
        let samples = try resampledSamples(for: url)

        let manager = StreamingEouAsrManager(chunkSize: .ms160)
        try await manager.loadModels(modelDir: LocalParakeet.getStreamingModelsDirectory(chunkSize: .ms160))
        for chunk in chunked(samples: samples, chunkSize: liveLikeChunkSize) {
            let buffer = try audioBuffer(from: chunk)
            _ = try await manager.process(audioBuffer: buffer)
        }
        let transcript = try await manager.finish()
        await manager.reset()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wrapperStreamingTranscript(for url: URL) async throws -> String {
        let samples = try resampledSamples(for: url)
        let wrapper = ParakeetVoiceToTextModel.shared
        try await wrapper.startStreamingSession(source: .microphone)
        defer {
            Task {
                try? await wrapper.stopStreamingSession(source: .microphone)
            }
        }

        for chunk in chunked(samples: samples, chunkSize: liveLikeChunkSize) {
            try await wrapper.feedFragment(chunk, source: .microphone) { _ in }
        }

        let transcript = try await wrapper.finalizeStreamingText(source: .microphone) ?? ""
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resampledSamples(for url: URL) throws -> [Float] {
        let converter = AudioConverter()
        return try converter.resampleAudioFile(path: url.path)
    }

    private func chunked(samples: [Float], chunkSize: Int) -> [[Float]] {
        stride(from: 0, to: samples.count, by: chunkSize).map { startIndex in
            let endIndex = min(startIndex + chunkSize, samples.count)
            return Array(samples[startIndex..<endIndex])
        }
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
                domain: "ParakeetDiagnosticsTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate AVAudioPCMBuffer for fixture chunk"]
            )
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw NSError(
                domain: "ParakeetDiagnosticsTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to access fixture chunk channel data"]
            )
        }

        channelData.update(from: samples, count: samples.count)
        return buffer
    }
}
