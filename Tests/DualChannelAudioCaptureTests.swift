import XCTest
@testable import WhisperClip

final class DualChannelAudioCaptureTests: XCTestCase {

    // MARK: - Streaming callback: sample extraction and delivery

    @MainActor
    func testProcessSystemAudioSamplesCallsOnSystemBatch() async throws {
        let capture = DualChannelAudioCapture()

        // Create known Float samples
        let inputSamples: [Float] = [0.1, 0.2, 0.3, -0.5, 0.0]
        let byteCount = inputSamples.count * MemoryLayout<Float>.size
        let elapsed: TimeInterval = 1.5

        var receivedSamples: [Float]?
        var receivedTime: TimeInterval?

        inputSamples.withUnsafeBytes { rawBuffer in
            capture.processSystemAudioSamples(
                data: rawBuffer.baseAddress!,
                byteCount: byteCount,
                onSystemBatch: { samples, time in
                    receivedSamples = samples
                    receivedTime = time
                },
                elapsed: elapsed
            )
        }

        XCTAssertNotNil(receivedSamples, "onSystemBatch should have been called")
        XCTAssertEqual(receivedSamples?.count, 5, "Should receive 5 samples")
        assertFloatArraysEqual(receivedSamples, inputSamples, accuracy: 0.0001)
        XCTAssertEqual(receivedTime, 1.5)
    }

    @MainActor
    func testProcessSystemAudioSamplesIgnoresZeroBytes() async throws {
        let capture = DualChannelAudioCapture()

        var called = false
        var dummy: Float = 0.0

        withUnsafeBytes(of: &dummy) { rawBuffer in
            capture.processSystemAudioSamples(
                data: rawBuffer.baseAddress!,
                byteCount: 0,
                onSystemBatch: { _, _ in called = true },
                elapsed: 0
            )
        }

        XCTAssertFalse(called, "onSystemBatch should NOT be called for zero-byte buffer")
    }

    @MainActor
    func testDispatchMicrophoneSamplesCallsAudioChunkImmediately() async throws {
        let capture = DualChannelAudioCapture()
        let expectedSamples: [Float] = [0.1, 0.2, 0.3]
        let elapsed: TimeInterval = 0.75
        var receivedSource: AudioSource?
        var receivedSamples: [Float] = []
        var receivedTime: TimeInterval?

        capture.dispatchMicrophoneSamples(
            expectedSamples,
            elapsed: elapsed,
            callbackOverride: { source, samples, startTime in
                receivedSource = source
                receivedSamples = samples
                receivedTime = startTime
            }
        )

        XCTAssertEqual(receivedSource, .microphone)
        assertFloatArraysEqual(receivedSamples, expectedSamples, accuracy: 0.0001)
        XCTAssertEqual(receivedTime, elapsed)
    }

    /// Compare two Float arrays element-wise with tolerance.
    private func assertFloatArraysEqual(
        _ a: [Float]?,
        _ b: [Float],
        accuracy: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let a = a else {
            XCTFail("First array is nil", file: file, line: line)
            return
        }

        XCTAssertEqual(a.count, b.count, "Array count mismatch", file: file, line: line)
        for (index, pair) in zip(a, b).enumerated() {
            XCTAssertEqual(pair.0, pair.1, accuracy: accuracy, "Element \(index) mismatch", file: file, line: line)
        }
    }
}
