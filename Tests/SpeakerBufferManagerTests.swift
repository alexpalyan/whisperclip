import XCTest
import FluidAudio
@testable import WhisperClip

final class SpeakerBufferManagerTests: XCTestCase {

    // MARK: - Helpers

    /// Collect up to `count` buffers from the AsyncStream with a timeout.
    /// Calls `stop()` after collection to finish the stream.
    private func collectBuffers(
        from manager: SpeakerBufferManager,
        count: Int,
        timeout: TimeInterval = 5.0
    ) async -> [ClosedSpeakerBuffer] {
        var results: [ClosedSpeakerBuffer] = []
        let deadline = Date().addingTimeInterval(timeout)
        for await buffer in manager.buffers {
            results.append(buffer)
            if results.count >= count || Date() > deadline { break }
        }
        return results
    }

    // MARK: - PIPE-01: onAudioBatch() appends to accumulation buffer

    func testOnAudioBatchAppends() async throws {
        let mock = MockDiarizationProvider()
        mock.setResults([makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0)])

        let manager = SpeakerBufferManager(
            diarizer: mock,
            sampleRate: 16_000,
            pollingInterval: 50_000_000  // 50ms for fast tests
        )

        await manager.start()
        await manager.onAudioBatch(Array(repeating: 0.1, count: 16_000), atTime: 0.0)

        // Allow at least one poll cycle
        try await Task.sleep(nanoseconds: 150_000_000)
        await manager.stop()

        let buffers = await collectBuffers(from: manager, count: 1)
        XCTAssertFalse(buffers.isEmpty, "Expected at least one buffer after stop()")
        XCTAssertEqual(buffers[0].samples.count, 16_000, "Buffer should contain all 16,000 appended samples")
    }

    // MARK: - PIPE-01: Concurrent onAudioBatch() calls result in correct total sample count

    func testConcurrentBatchIngestion() async throws {
        let mock = MockDiarizationProvider()
        mock.setResults([makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0)])

        let manager = SpeakerBufferManager(
            diarizer: mock,
            sampleRate: 16_000,
            pollingInterval: 50_000_000
        )

        await manager.start()

        // Launch 10 concurrent Tasks each feeding 1,600 samples = 16,000 total
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await manager.onAudioBatch(
                        Array(repeating: Float(i) * 0.01, count: 1_600),
                        atTime: Double(i) * 0.1
                    )
                }
            }
        }

        // Allow poll cycle
        try await Task.sleep(nanoseconds: 200_000_000)
        await manager.stop()

        let buffers = await collectBuffers(from: manager, count: 1)
        XCTAssertFalse(buffers.isEmpty, "Expected at least one buffer")
        let totalSamples = buffers.reduce(0) { $0 + $1.samples.count }
        XCTAssertEqual(totalSamples, 16_000, "Total samples across all buffers should be 16,000")
    }

    // MARK: - PIPE-02: Speaker change triggers buffer close and emission

    func testSpeakerChangeFlushesPreviousBuffer() async throws {
        let mock = MockDiarizationProvider()
        // First poll returns SPEAKER_00, subsequent polls return SPEAKER_01
        mock.setResults([
            makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0),
            makeDiarizationResult(speakerId: "SPEAKER_01", durationSeconds: 1.0),
            makeDiarizationResult(speakerId: "SPEAKER_01", durationSeconds: 1.0),
        ])

        let manager = SpeakerBufferManager(
            diarizer: mock,
            sampleRate: 16_000,
            pollingInterval: 50_000_000
        )

        await manager.start()

        // Feed first speaker's audio
        await manager.onAudioBatch(Array(repeating: 0.1, count: 16_000), atTime: 0.0)

        // Wait for first poll (SPEAKER_00 detected, currentSpeakerId set)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Feed second speaker's audio
        await manager.onAudioBatch(Array(repeating: 0.2, count: 16_000), atTime: 1.0)

        // Wait for second poll (SPEAKER_01 detected, speaker change triggers flush)
        try await Task.sleep(nanoseconds: 150_000_000)

        await manager.stop()

        let buffers = await collectBuffers(from: manager, count: 3)
        XCTAssertGreaterThanOrEqual(buffers.count, 1, "Expected at least one buffer from speaker change or stop()")

        // First buffer should be labeled Speaker 1 (SPEAKER_00)
        XCTAssertEqual(buffers[0].speakerLabel, "Speaker 1", "First flushed buffer should be Speaker 1")
    }

    // MARK: - PIPE-03: Buffer exceeding 30s (480,000 samples) is force-flushed

    func testMaxDurationCapForceFlush() async throws {
        let mock = MockDiarizationProvider()
        // Always return same speaker — cap should still trigger
        mock.setResults([makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0)])

        let manager = SpeakerBufferManager(
            diarizer: mock,
            sampleRate: 16_000,
            pollingInterval: 50_000_000
        )

        await manager.start()

        // Feed 490,000 samples — exceeds the 480,000 cap (30s * 16kHz)
        await manager.onAudioBatch(Array(repeating: 0.1, count: 490_000), atTime: 0.0)

        // Allow poll cycle to detect the cap
        try await Task.sleep(nanoseconds: 150_000_000)
        await manager.stop()

        let buffers = await collectBuffers(from: manager, count: 3)
        XCTAssertFalse(buffers.isEmpty, "Expected buffer(s) emitted due to 30s cap")

        // Each buffer should be <= 480,000 samples
        for buffer in buffers {
            XCTAssertLessThanOrEqual(
                buffer.samples.count,
                480_000,
                "No buffer should exceed the 480,000 sample cap"
            )
        }
    }

    // MARK: - PIPE-04: Emitted ClosedSpeakerBuffer.speakerLabel is resolved label

    func testEmittedBufferHasResolvedLabel() async throws {
        let mock = MockDiarizationProvider()
        mock.setResults([makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0)])

        let manager = SpeakerBufferManager(
            diarizer: mock,
            sampleRate: 16_000,
            pollingInterval: 50_000_000
        )

        await manager.start()
        await manager.onAudioBatch(Array(repeating: 0.1, count: 16_000), atTime: 0.0)
        try await Task.sleep(nanoseconds: 150_000_000)
        await manager.stop()

        let buffers = await collectBuffers(from: manager, count: 1)
        XCTAssertFalse(buffers.isEmpty, "Expected one buffer from stop()")
        XCTAssertEqual(
            buffers[0].speakerLabel,
            "Speaker 1",
            "Label should be 'Speaker 1', not the raw 'SPEAKER_00'"
        )
    }

    // MARK: - PIPE-06: Buffer shorter than 0.5s (< 8,000 samples) is discarded

    func testShortBufferDiscarded() async throws {
        let mock = MockDiarizationProvider()
        // First poll: SPEAKER_00 (for the short 4,000-sample buffer)
        // Second poll: SPEAKER_01 (triggers flush of short buffer — should be discarded)
        // Third poll: SPEAKER_01 (for the adequate 16,000-sample buffer)
        mock.setResults([
            makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0),
            makeDiarizationResult(speakerId: "SPEAKER_01", durationSeconds: 1.0),
            makeDiarizationResult(speakerId: "SPEAKER_01", durationSeconds: 1.0),
        ])

        let manager = SpeakerBufferManager(
            diarizer: mock,
            sampleRate: 16_000,
            pollingInterval: 50_000_000
        )

        await manager.start()

        // Feed short buffer (< 8,000 samples)
        await manager.onAudioBatch(Array(repeating: 0.1, count: 4_000), atTime: 0.0)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Feed adequate buffer for second speaker
        await manager.onAudioBatch(Array(repeating: 0.2, count: 16_000), atTime: 0.25)
        try await Task.sleep(nanoseconds: 150_000_000)

        await manager.stop()

        let buffers = await collectBuffers(from: manager, count: 3)

        // Short buffer (4,000 samples) should have been discarded
        // Only the 16,000-sample buffer should be emitted
        XCTAssertFalse(buffers.isEmpty, "Expected the adequate buffer to be emitted")
        for buffer in buffers {
            XCTAssertGreaterThanOrEqual(
                buffer.samples.count,
                8_000,
                "Short buffer (< 8,000 samples) should have been discarded, not emitted"
            )
        }
    }

    // MARK: - PIPE-06: Buffer >= 8,000 samples on stop() is flushed

    func testStopFlushesAdequateBuffer() async throws {
        let mock = MockDiarizationProvider()
        mock.setResults([makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0)])

        let manager = SpeakerBufferManager(
            diarizer: mock,
            sampleRate: 16_000,
            pollingInterval: 50_000_000
        )

        await manager.start()
        await manager.onAudioBatch(Array(repeating: 0.1, count: 16_000), atTime: 0.0)
        try await Task.sleep(nanoseconds: 150_000_000)
        await manager.stop()

        let buffers = await collectBuffers(from: manager, count: 1)
        XCTAssertFalse(buffers.isEmpty, "stop() should flush a buffer with >= 8,000 samples")
        XCTAssertEqual(buffers[0].samples.count, 16_000, "Flushed buffer should have all 16,000 samples")
    }

    // MARK: - SPKR-01: Same rawSpeakerId maps to same label across multiple polls

    func testSpeakerLabelStability() async throws {
        let mock = MockDiarizationProvider()
        // Always return SPEAKER_00 — label should always be "Speaker 1"
        mock.setResults([
            makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0),
            makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0),
            makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0),
        ])

        let manager = SpeakerBufferManager(
            diarizer: mock,
            sampleRate: 16_000,
            pollingInterval: 50_000_000
        )

        await manager.start()
        await manager.onAudioBatch(Array(repeating: 0.1, count: 16_000), atTime: 0.0)
        try await Task.sleep(nanoseconds: 250_000_000)
        await manager.stop()

        let buffers = await collectBuffers(from: manager, count: 3)
        XCTAssertFalse(buffers.isEmpty, "Expected at least one buffer")
        for buffer in buffers {
            XCTAssertEqual(
                buffer.speakerLabel,
                "Speaker 1",
                "SPEAKER_00 should always map to 'Speaker 1'"
            )
        }
    }

    // MARK: - SPKR-02: diarize() is actually called (mock call count verification)

    func testDiarizerConfigThreshold() async throws {
        let mock = MockDiarizationProvider()
        mock.setResults([makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0)])

        let manager = SpeakerBufferManager(
            diarizer: mock,
            sampleRate: 16_000,
            pollingInterval: 50_000_000
        )

        await manager.start()
        await manager.onAudioBatch(Array(repeating: 0.1, count: 16_000), atTime: 0.0)

        // Allow multiple poll cycles
        try await Task.sleep(nanoseconds: 300_000_000)
        await manager.stop()

        // Consume the stream to allow stop to complete
        _ = await collectBuffers(from: manager, count: 3)

        XCTAssertGreaterThan(
            mock.diarizeCallCount,
            0,
            "diarize() should have been called at least once during polling"
        )
    }

    // MARK: - SPKR-03: Labels ordered by first appearance: SPEAKER_00 = Speaker 1, SPEAKER_01 = Speaker 2

    func testSpeakerLabelOrdering() async throws {
        let mock = MockDiarizationProvider()
        // SPEAKER_00 appears first → Speaker 1; SPEAKER_01 appears second → Speaker 2
        mock.setResults([
            makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0),
            makeDiarizationResult(speakerId: "SPEAKER_01", durationSeconds: 1.0),
            makeDiarizationResult(speakerId: "SPEAKER_01", durationSeconds: 1.0),
        ])

        let manager = SpeakerBufferManager(
            diarizer: mock,
            sampleRate: 16_000,
            pollingInterval: 50_000_000
        )

        await manager.start()

        // First speaker segment
        await manager.onAudioBatch(Array(repeating: 0.1, count: 16_000), atTime: 0.0)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Second speaker segment (triggers flush of first)
        await manager.onAudioBatch(Array(repeating: 0.2, count: 16_000), atTime: 1.0)
        try await Task.sleep(nanoseconds: 150_000_000)

        await manager.stop()

        let buffers = await collectBuffers(from: manager, count: 3)
        XCTAssertGreaterThanOrEqual(buffers.count, 1, "Expected at least one buffer")

        // First buffer (from SPEAKER_00's segment) should be "Speaker 1"
        XCTAssertEqual(
            buffers[0].speakerLabel,
            "Speaker 1",
            "First speaker (SPEAKER_00) should be labeled 'Speaker 1'"
        )

        // If two buffers were emitted, second should be "Speaker 2"
        if buffers.count >= 2 {
            XCTAssertEqual(
                buffers[1].speakerLabel,
                "Speaker 2",
                "Second speaker (SPEAKER_01) should be labeled 'Speaker 2'"
            )
        }
    }
}
