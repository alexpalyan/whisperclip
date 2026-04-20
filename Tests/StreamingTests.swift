import XCTest
@testable import WhisperClip

final class StreamingTests: XCTestCase {
    func testDisplayTextShowsTokensWhenPending() throws {
        let segment = MeetingSegment(
            speaker: .me,
            text: "hello world",
            startTime: 0,
            endTime: 1,
            isPending: true
        )

        XCTAssertEqual(
            segment.displayText,
            "hello world",
            "displayText must return text even when isPending=true"
        )
    }

    func testDisplayTextShowsEllipsisWhenEmptyAndPending() throws {
        let segment = MeetingSegment(
            speaker: .me,
            text: "",
            startTime: 0,
            endTime: 1,
            isPending: true
        )

        XCTAssertEqual(
            segment.displayText,
            "...",
            "displayText must return ellipsis when text is empty and isPending=true"
        )
    }

    func testSpeakerPendingDisplayName() throws {
        XCTAssertEqual(Speaker.pending.displayName, "Pending")
    }

    func testSpeakerPendingIcon() throws {
        XCTAssertEqual(Speaker.pending.icon, "ellipsis.circle")
    }

    func testSpeakerPendingColorIndex() throws {
        XCTAssertEqual(Speaker.pending.colorIndex, 8)
    }

    func testDisplaySpeakerReturnsMeForMicPendingSegment() throws {
        let segment = MeetingSegment(
            speaker: .me,
            text: "",
            startTime: 0,
            endTime: 1,
            isPending: true
        )

        XCTAssertEqual(
            segment.displaySpeaker,
            .me,
            "Mic channel segments must display as .me while pending"
        )
    }

    func testDisplaySpeakerReturnsPendingForSystemAudioSegment() throws {
        let segment = MeetingSegment(
            speaker: .other,
            text: "",
            startTime: 0,
            endTime: 1,
            isPending: true
        )

        XCTAssertEqual(
            segment.displaySpeaker,
            .pending,
            "System audio segments must display as .pending while awaiting diarization"
        )
    }

    func testSpeakerPendingCodableRoundTrip() throws {
        let original = Speaker.pending
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Speaker.self, from: data)

        XCTAssertEqual(decoded, .pending, "Speaker.pending must survive Codable round-trip")
    }

    // MARK: - Phase 11.2: LCP and Last-Word Truncation Tests

    func testLastWordTruncationHidesPartialWord() throws {
        XCTAssertEqual(
            applyLastWordTruncation("hello wor"),
            "hello ",
            "Partial trailing word must be hidden until confirmed"
        )
    }

    func testLastWordTruncationPreservesCompleteWord() throws {
        XCTAssertEqual(
            applyLastWordTruncation("hello world "),
            "hello world ",
            "Word followed by space must be preserved"
        )
    }

    func testLastWordTruncationPreservesPunctuation() throws {
        XCTAssertEqual(
            applyLastWordTruncation("hello world."),
            "hello world.",
            "Word followed by punctuation must be preserved"
        )
    }

    func testLastWordTruncationEmptyString() throws {
        XCTAssertEqual(
            applyLastWordTruncation(""),
            "",
            "Empty string must return empty string"
        )
    }

    func testLCPReturnsLongestCommonPrefix() throws {
        XCTAssertEqual(
            calculateLCP("hello world", "hello wor"),
            "hello ",
            "LCP must return stable prefix up to last complete word boundary"
        )
    }

    func testLCPIdenticalStrings() throws {
        XCTAssertEqual(
            calculateLCP("hello", "hello"),
            "hello",
            "Identical strings must return the full string as LCP"
        )
    }

    func testLCPNoCommonPrefix() throws {
        XCTAssertEqual(
            calculateLCP("abc", "xyz"),
            "",
            "No common prefix must return empty string"
        )
    }

    func testSanitizeWhisperKitTextRemovesControlTags() throws {
        XCTAssertEqual(
            sanitizeWhisperKitText("<|startoftranscript|><|ru|><|transcribe|><|0.00|> - Окей, хорошо."),
            "Окей, хорошо."
        )
    }

    func testSanitizeWhisperKitTextCollapsesWhitespace() throws {
        XCTAssertEqual(
            sanitizeWhisperKitText("  <|0.00|>  hello   world  "),
            "hello world"
        )
    }

    // MARK: - Phase 11.2: Backpressure Tests

    func testBackpressureDropsOldestSystemFragment() async throws {
        let queue = TranscriptionQueue()
        let sampleRate = 16_000

        for index in 0..<5 {
            let samples = [Float](repeating: Float(index) * 0.01, count: sampleRate / 2)
            await queue.enqueueFragment(
                source: .system,
                samples: samples,
                startTime: TimeInterval(index) * 0.5,
                processor: { _, _, _ in }
            )
        }

        let duration = await queue.totalQueuedDuration(for: .system)
        XCTAssertLessThanOrEqual(
            duration,
            2.0,
            "System fragment queue must not exceed 2.0s of buffered audio"
        )
    }

    func testMicFragmentsNotDroppedUnderBackpressure() async throws {
        let queue = TranscriptionQueue()
        let sampleRate = 16_000
        let tasks = (0..<3).map { index in
            Task {
                let samples = [Float](
                    repeating: Float(index) * 0.01,
                    count: Int(Double(sampleRate) * 0.4)
                )
                await queue.enqueueFragment(
                    source: .microphone,
                    samples: samples,
                    startTime: TimeInterval(index) * 0.4,
                    processor: { _, _, _ in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                )
            }
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        let micDuration = await queue.totalQueuedDuration(for: .microphone)
        XCTAssertGreaterThan(
            micDuration,
            0.0,
            "Mic fragments must not be dropped when below backpressure threshold"
        )

        for task in tasks {
            _ = await task.value
        }
    }

    func testDrainFragmentsWaitsForActiveMicrophoneFragment() async throws {
        let queue = TranscriptionQueue()
        let started = expectation(description: "fragment started")
        let release = expectation(description: "release fragment")

        Task {
            await queue.enqueueFragment(
                source: .microphone,
                samples: Array(repeating: 0.1, count: 4_800),
                startTime: 0,
                processor: { _, _, _ in
                    started.fulfill()
                    await self.fulfillment(of: [release], timeout: 1.0)
                }
            )
        }

        await fulfillment(of: [started], timeout: 1.0)

        let drainTask = Task {
            await queue.drainFragments(for: .microphone)
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(drainTask.isCancelled, "Drain task should remain pending while mic fragment is active")

        release.fulfill()
        _ = await drainTask.value
    }
}
