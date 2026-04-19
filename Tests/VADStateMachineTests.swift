import XCTest
@testable import WhisperClip

/// Wave 0 stubs — implementation arrives in Wave 1 (VADStateMachine.swift).
final class VADStateMachineTests: XCTestCase {

    // MARK: - VAD-01: 200ms onset creates pending segment

    func testVAD01OnsetReturnsSpeechStartedAfter200ms() async throws {
        let vad = VADStateMachine(
            thresholdDB: -45,
            onsetDuration: .milliseconds(1),
            offsetDuration: .milliseconds(500)
        )

        let result1 = await vad.update(levelDB: -30)
        XCTAssertNil(result1, "First above-threshold call starts timing, should not emit yet")

        try await Task.sleep(for: .milliseconds(5))

        let result2 = await vad.update(levelDB: -30)
        XCTAssertEqual(result2, .startSpeech, "Should emit .startSpeech after onset duration elapsed")
    }

    func testVAD01SingleFrameAboveThresholdDoesNotTrigger() async throws {
        let vad = VADStateMachine(
            thresholdDB: -45,
            onsetDuration: .milliseconds(200),
            offsetDuration: .milliseconds(500)
        )

        let result = await vad.update(levelDB: -30)
        XCTAssertNil(result, "Single above-threshold frame must not emit .startSpeech")
    }

    func testVAD01NoDuplicateStartWhenAlreadyActive() async throws {
        let vad = VADStateMachine(
            thresholdDB: -45,
            onsetDuration: .milliseconds(1),
            offsetDuration: .milliseconds(500)
        )

        _ = await vad.update(levelDB: -30)
        try await Task.sleep(for: .milliseconds(5))

        let first = await vad.update(levelDB: -30)
        XCTAssertEqual(first, .startSpeech, "First crossing should emit .startSpeech")

        let second = await vad.update(levelDB: -30)
        XCTAssertNil(second, "Already active — must not emit .startSpeech again")
    }

    // MARK: - VAD-02: Reconciliation merges VAD segment with ASR result

    func testVAD02ReconciliationMergesOnMatchingId() throws {
        let existing = MeetingSegment(
            speaker: .me,
            text: "",
            startTime: 1.0,
            endTime: 1.0,
            confidence: 0,
            isPending: true
        )

        let reconciled = existing
        reconciled.text = "hello"
        reconciled.speaker = .me
        reconciled.isPending = false

        XCTAssertEqual(reconciled.id, existing.id)
        XCTAssertEqual(reconciled.text, "hello")
        XCTAssertFalse(reconciled.isPending)
    }

    func testVAD02GhostSegmentRemovedAfterTimeout() throws {
        var segments = [
            MeetingSegment(
                speaker: .pending,
                text: "",
                startTime: 1.0,
                endTime: 1.0,
                confidence: 0,
                isPending: true
            )
        ]

        let pendingId = segments[0].id
        segments.removeAll { $0.id == pendingId }

        XCTAssertFalse(segments.contains(where: { $0.id == pendingId }))
    }
}
