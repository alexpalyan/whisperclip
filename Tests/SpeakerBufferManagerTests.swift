import XCTest
import FluidAudio
@testable import WhisperClip

final class SpeakerBufferManagerTests: XCTestCase {

    // PIPE-01: onAudioBatch() appends to accumulation buffer
    func testOnAudioBatchAppends() async throws {
        XCTFail("Not yet implemented — Plan 02")
    }

    // PIPE-01: Multiple concurrent onAudioBatch() calls result in correct total sample count
    func testConcurrentBatchIngestion() async throws {
        XCTFail("Not yet implemented — Plan 02")
    }

    // PIPE-02: Speaker change triggers buffer close and emission via AsyncStream
    func testSpeakerChangeFlushesPreviousBuffer() async throws {
        XCTFail("Not yet implemented — Plan 02")
    }

    // PIPE-03: Buffer exceeding 30s (480,000 samples at 16kHz) is force-flushed
    func testMaxDurationCapForceFlush() async throws {
        XCTFail("Not yet implemented — Plan 02")
    }

    // PIPE-04: Emitted ClosedSpeakerBuffer.speakerLabel matches the resolved label
    func testEmittedBufferHasResolvedLabel() async throws {
        XCTFail("Not yet implemented — Plan 02")
    }

    // PIPE-06: Buffer shorter than 0.5s (< 8,000 samples) is discarded without emission
    func testShortBufferDiscarded() async throws {
        XCTFail("Not yet implemented — Plan 02")
    }

    // PIPE-06: Buffer >= 8,000 samples on stop() is flushed
    func testStopFlushesAdequateBuffer() async throws {
        XCTFail("Not yet implemented — Plan 02")
    }

    // SPKR-01: Same rawSpeakerId across multiple polls maps to same label
    func testSpeakerLabelStability() async throws {
        XCTFail("Not yet implemented — Plan 02")
    }

    // SPKR-02: clusteringThreshold=0.3 is used (verified through mock)
    func testDiarizerConfigThreshold() async throws {
        XCTFail("Not yet implemented — Plan 02")
    }

    // SPKR-03: Labels are "Speaker 1", "Speaker 2" in order of first appearance
    func testSpeakerLabelOrdering() async throws {
        XCTFail("Not yet implemented — Plan 02")
    }
}
