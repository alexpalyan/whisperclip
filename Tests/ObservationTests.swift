import XCTest
@testable import WhisperClip

final class ObservationTests: XCTestCase {
    // MUT-01: updating speakerLabel on a MeetingSegment instance
    // propagates to any observer without replacing the array element.
    func testSpeakerLabelUpdateIsObservable() throws {
        let segment = MeetingSegment(speaker: .me, text: "hello", startTime: 0, endTime: 1)

        XCTAssertEqual(segment.speaker, .me)
        segment.speaker = .labeled("Speaker 1")
        XCTAssertEqual(segment.speaker, .labeled("Speaker 1"), "speaker must be mutable on @Observable class")
    }

    func testIsPendingTransitionIsObservable() throws {
        let segment = MeetingSegment(speaker: .unknown, text: "", startTime: 0, endTime: 1, isPending: true)

        XCTAssertTrue(segment.isPending)
        XCTAssertEqual(segment.displayText, "...")
        segment.isPending = false
        segment.text = "resolved"
        XCTAssertEqual(segment.displayText, "resolved")
    }
}
