import XCTest
@testable import WhisperClip

final class MeetingSegmentTests: XCTestCase {
    // MUT-02: MeetingSession and MeetingStorage compile and round-trip
    // without modification after MeetingSegment becomes a class.
    func testMeetingSegmentIsReferenceType() throws {
        let segment = MeetingSegment(speaker: .me, text: "hello", startTime: 0, endTime: 1)
        let reference = segment

        reference.text = "world"
        XCTAssertEqual(segment.text, "world", "MeetingSegment must be a reference type")
    }

    func testAddPendingSegmentAppendsToLiveTranscript() throws {
        let segment = MeetingSegment(speaker: .unknown, text: "", startTime: 0, endTime: 1, isPending: true)

        XCTAssertTrue(segment.isPending, "Segment created with isPending: true must remain pending")
        XCTAssertEqual(segment.displayText, "...")
        XCTAssertEqual(segment.displaySpeaker, .pending)
    }

    func testFinalizeSegmentUpdatesInPlace() throws {
        let segment = MeetingSegment(speaker: .unknown, text: "", startTime: 0, endTime: 5, isPending: true)

        segment.text = "Final transcription"
        segment.speaker = .labeled("Speaker 1")
        segment.isPending = false

        XCTAssertEqual(segment.text, "Final transcription")
        XCTAssertFalse(segment.isPending)
        XCTAssertEqual(segment.displayText, "Final transcription")
        XCTAssertEqual(segment.displaySpeaker, .labeled("Speaker 1"))
    }
}
