import XCTest
@testable import WhisperClip

final class DiarizerMicroWindowTests: XCTestCase {
    func testMicroWindowDefaultIsSeven() throws {
        let manager = SpeakerBufferManager(diarizer: MockDiarizationProvider())
        XCTAssertEqual(manager.microWindowSamples, 16_000 * 7)
    }

    func testMicroWindowCustomValueIsApplied() throws {
        let manager = SpeakerBufferManager(diarizer: MockDiarizationProvider(), microWindowSeconds: 10)
        XCTAssertEqual(manager.microWindowSamples, 16_000 * 10)
    }

    func testHardCeilingRemainsThirtySeconds() throws {
        let manager = SpeakerBufferManager(diarizer: MockDiarizationProvider())
        XCTAssertEqual(manager.maxSamplesPerBuffer, 16_000 * 30)
        XCTAssertLessThan(manager.microWindowSamples, manager.maxSamplesPerBuffer)
    }

    func testSpeakerChangeTriggersBufferSplit() throws {
        let manager = SpeakerBufferManager(diarizer: MockDiarizationProvider(), microWindowSeconds: 7)
        XCTAssertGreaterThan(manager.microWindowSamples, manager.minSamplesPerBuffer)
    }
}
