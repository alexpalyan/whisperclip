import Foundation
import FluidAudio
@testable import WhisperClip

/// Mock diarization provider for unit tests. Does not load any CoreML models.
/// Configure `resultSequence` before test to control what each `diarize()` call returns.
final class MockDiarizationProvider: DiarizationProvider, @unchecked Sendable {
    /// Results returned in order. If exhausted, returns the last result.
    /// If empty, returns an empty DiarizationResult.
    private var resultSequence: [DiarizationResult] = []
    private var callIndex: Int = 0

    /// Number of times `diarize()` was called
    private(set) var diarizeCallCount: Int = 0

    /// Set the sequence of results the mock will return on successive calls
    func setResults(_ results: [DiarizationResult]) {
        resultSequence = results
        callIndex = 0
        diarizeCallCount = 0
    }

    func diarize(_ samples: [Float], sampleRate: Int, atTime: TimeInterval) throws -> DiarizationResult {
        diarizeCallCount += 1
        guard !resultSequence.isEmpty else {
            return DiarizationResult(segments: [])
        }
        let result = resultSequence[min(callIndex, resultSequence.count - 1)]
        callIndex += 1
        return result
    }
}
