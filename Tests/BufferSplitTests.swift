import XCTest
@testable import WhisperClip

final class BufferSplitTests: XCTestCase {
    private func makeManager(microWindowSeconds: Int = 7) -> SpeakerBufferManager {
        SpeakerBufferManager(
            diarizer: MockDiarizationProvider(),
            sampleRate: 16_000,
            pollingInterval: 150_000_000,
            microWindowSeconds: microWindowSeconds
        )
    }

    func testSplitBufferAtExactSampleBoundary() throws {
        let manager = makeManager()
        let samples = [Float](repeating: 0.5, count: 160_000)

        let (first, second) = manager.splitBuffer(samples, atSeconds: 5.0)

        XCTAssertEqual(first.count, 80_000)
        XCTAssertEqual(second.count, 80_000)
        XCTAssertEqual(first.count + second.count, samples.count)
    }

    func testSplitBufferOffsetZeroReturnsEmptyFirstAndFullSecond() throws {
        let manager = makeManager()
        let samples = [Float](repeating: 0.1, count: 16_000)

        let (first, second) = manager.splitBuffer(samples, atSeconds: 0.0)

        XCTAssertEqual(first.count, 0)
        XCTAssertEqual(second.count, 16_000)
    }

    func testSplitBufferOffsetBeyondEndClampsToEnd() throws {
        let manager = makeManager()
        let samples = [Float](repeating: 0.1, count: 16_000)

        let (first, second) = manager.splitBuffer(samples, atSeconds: 99.0)

        XCTAssertEqual(first.count, 16_000)
        XCTAssertEqual(second.count, 0)
    }

    func testSplitYieldsTwoClosedBuffers() throws {
        let manager = makeManager()
        let samples = [Float](repeating: 0.3, count: 112_000)
        let splitSeconds = 3.5

        let (first, second) = manager.splitBuffer(samples, atSeconds: splitSeconds)

        XCTAssertEqual(first.count, Int(splitSeconds * 16_000))
        XCTAssertEqual(second.count, samples.count - first.count)
    }
}
