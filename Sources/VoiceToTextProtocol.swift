import Foundation

enum StreamingTranscriptionEvent: Sendable, Equatable {
    case convertingAudio
    case decodingStarted
    case firstToken
    case finished
}

/// Protocol defining the interface for audio transcription
protocol VoiceToTextProtocol {
    /// Transcribe an audio file to text
    /// - Parameter filepath: The path to the audio file (m4a format)
    /// - Returns: The transcribed text
    /// - Throws: TranscriptionError if the transcription fails
    func process(filepath: String) async throws -> String

    /// Transcribe an audio file while emitting partial cumulative text updates.
    /// - Parameters:
    ///   - filepath: The path to the audio file.
    ///   - onToken: Called on the main actor whenever partial text changes.
    /// - Returns: The final transcription text.
    func processStream(
        filepath: String,
        onEvent: @escaping @MainActor @Sendable (StreamingTranscriptionEvent) -> Void,
        onToken: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String
}

extension VoiceToTextProtocol {
    func processStream(
        filepath: String,
        onEvent: @escaping @MainActor @Sendable (StreamingTranscriptionEvent) -> Void,
        onToken: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        await MainActor.run {
            onEvent(.decodingStarted)
        }
        let result = try await process(filepath: filepath)
        await MainActor.run {
            onToken(result)
            onEvent(.firstToken)
            onEvent(.finished)
        }
        return result
    }
}
