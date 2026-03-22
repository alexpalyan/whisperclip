import Foundation
import FluidAudio

// MARK: - DiarizationProvider Protocol

/// Protocol wrapping DiarizerManager to enable unit testing without FluidAudio model loading.
/// SpeakerBufferManager stores `any DiarizationProvider` — all diarizer calls happen from within
/// actor isolation, preventing cross-isolation data races.
protocol DiarizationProvider: Sendable {
    func diarize(_ samples: [Float], sampleRate: Int, atTime: TimeInterval) throws -> DiarizationResult
}

// MARK: - DiarizerManager Conformance

/// DiarizerManager is a `public final class` in FluidAudio with no Sendable conformance.
/// This @unchecked Sendable extension is safe because SpeakerBufferManager (a Swift actor)
/// is the sole owner — the actor's serialization guarantees single-threaded access.
/// TODO: Remove when FluidAudio adds its own Sendable conformance.
extension DiarizerManager: @unchecked Sendable {}

extension DiarizerManager: DiarizationProvider {
    func diarize(_ samples: [Float], sampleRate: Int, atTime time: TimeInterval) throws -> DiarizationResult {
        try performCompleteDiarization(samples, sampleRate: sampleRate, atTime: time)
    }
}

// MARK: - ClosedSpeakerBuffer

/// A closed, ready-to-transcribe audio buffer with a resolved speaker label.
/// Emitted by SpeakerBufferManager via AsyncStream when a speaker change is detected,
/// the 30s cap is hit, or stop() flushes the final buffer.
struct ClosedSpeakerBuffer: Sendable, Equatable {
    /// Raw PCM samples at 16kHz mono
    let samples: [Float]
    /// Resolved human-readable label ("Speaker 1", "Speaker 2", etc.)
    let speakerLabel: String
    /// Time offset from recording start when this buffer began accumulating
    let startTime: TimeInterval
}
