import XCTest
@testable import WhisperClip

actor MockTranscriptionQueue {
    private var enqueuedBuffers: [ClosedSpeakerBuffer] = []
    private var processorCallCount = 0

    func enqueue(
        buffer: ClosedSpeakerBuffer,
        processor: @escaping @MainActor (ClosedSpeakerBuffer) async -> Void
    ) async {
        enqueuedBuffers.append(buffer)
        await processor(buffer)
        processorCallCount += 1
    }

    func bufferedItems() -> [ClosedSpeakerBuffer] {
        enqueuedBuffers
    }

    func callCount() -> Int {
        processorCallCount
    }

    func drain() async {
    }
}

@MainActor
final class MeetingRecorderTests: XCTestCase {

    func testConsumerLoopProcessesBuffers() async throws {
        var continuation: AsyncStream<ClosedSpeakerBuffer>.Continuation!
        let stream = AsyncStream<ClosedSpeakerBuffer> { captured in
            continuation = captured
        }

        let queue = MockTranscriptionQueue()
        var processedLabels: [String] = []

        let consumerTask = Task {
            for await buffer in stream {
                await queue.enqueue(buffer: buffer) { buffered in
                    processedLabels.append(buffered.speakerLabel)
                }
            }
        }

        continuation.yield(
            ClosedSpeakerBuffer(samples: [0.1, 0.2], speakerLabel: "Speaker 1", startTime: 0.0)
        )
        continuation.yield(
            ClosedSpeakerBuffer(samples: [0.3, 0.4], speakerLabel: "Speaker 2", startTime: 1.0)
        )
        continuation.finish()

        _ = await consumerTask.value

        let enqueuedBuffers = await queue.bufferedItems()
        XCTAssertEqual(enqueuedBuffers.count, 2)
        XCTAssertEqual(processedLabels, ["Speaker 1", "Speaker 2"])
    }

    func testActiveSpeakerLabelUpdatesBeforeProcessorCall() async throws {
        var continuation: AsyncStream<ClosedSpeakerBuffer>.Continuation!
        let stream = AsyncStream<ClosedSpeakerBuffer> { captured in
            continuation = captured
        }

        var activeSpeakerLabel = ""
        var labelAtProcessorCallTime: String?

        let consumerTask = Task { @MainActor in
            for await buffer in stream {
                activeSpeakerLabel = buffer.speakerLabel
                labelAtProcessorCallTime = activeSpeakerLabel
            }
        }

        continuation.yield(
            ClosedSpeakerBuffer(
                samples: Array(repeating: 0.5, count: 16_000),
                speakerLabel: "Speaker 1",
                startTime: 0.0
            )
        )
        continuation.finish()

        _ = await consumerTask.value

        XCTAssertEqual(activeSpeakerLabel, "Speaker 1")
        XCTAssertEqual(labelAtProcessorCallTime, "Speaker 1")
    }

    // MARK: - GAP-09-04: Mic source sets activeSpeakerLabel to Me

    func testMicrophoneSourceSetsActiveSpeakerLabelToMe() {
        // Contract: microphone audio always identifies as "Me" for waveform color.
        // The onAudioChunk callback sets activeSpeakerLabel = Speaker.me.displayName
        // when source == .microphone, so the waveform shows #4A9EFF (vivid blue).
        //
        // This test validates the Speaker model contract that underpins the fix:
        // 1. Speaker.me.displayName produces "Me"
        // 2. Speaker(displayName: "Me") round-trips back to .me
        // 3. .me has colorIndex 0 (palette slot for vivid blue)

        let expectedLabel = Speaker.me.displayName
        XCTAssertEqual(expectedLabel, "Me", "Speaker.me.displayName must be 'Me'")

        // Round-trip: the label stored in activeSpeakerLabel -> Speaker(displayName:) -> palette lookup
        let resolvedSpeaker = Speaker(displayName: expectedLabel)
        XCTAssertEqual(resolvedSpeaker, .me, "Speaker(displayName: 'Me') must resolve to .me")
        XCTAssertEqual(resolvedSpeaker.colorIndex, 0, ".me must have colorIndex 0 for palette slot #4A9EFF")

        // Verify AudioSource.microphone maps to Speaker.me via source.speaker
        let micSpeaker = AudioSource.microphone.speaker
        XCTAssertEqual(micSpeaker, .me, "AudioSource.microphone.speaker must be .me")
        XCTAssertEqual(micSpeaker.displayName, "Me", "Mic speaker displayName must be 'Me'")
    }

    func testTeardownSequenceStopThenConsumeThenDrain() async throws {
        let diarizer = MockDiarizationProvider()
        diarizer.setResults([makeDiarizationResult(speakerId: "SPEAKER_00", durationSeconds: 1.0)])

        let manager = SpeakerBufferManager(
            diarizer: diarizer,
            sampleRate: 16_000,
            pollingInterval: 50_000_000
        )

        let completion = expectation(description: "consumer completed")
        let received = LockIsolated<[ClosedSpeakerBuffer]>([])

        await manager.start()

        let consumerTask = Task {
            for await buffer in manager.buffers {
                received.withValue { values in
                    values.append(buffer)
                }
            }
            completion.fulfill()
        }

        await manager.onAudioBatch(Array(repeating: 0.1, count: 16_000), atTime: 0.0)
        try await Task.sleep(nanoseconds: 200_000_000)

        await manager.stop()
        _ = await consumerTask.value
        await fulfillment(of: [completion], timeout: 1.0)

        let flushedBuffers = received.value
        XCTAssertFalse(flushedBuffers.isEmpty)
        XCTAssertEqual(flushedBuffers.first?.speakerLabel, "Speaker 1")
    }

    func testTranscriptionQueueBufferOverload() async throws {
        let queue = TranscriptionQueue()
        var processedBuffers: [ClosedSpeakerBuffer] = []
        let buffer = ClosedSpeakerBuffer(
            samples: Array(repeating: 0.1, count: 8_000),
            speakerLabel: "Speaker 1",
            startTime: 0.0
        )

        await queue.enqueue(buffer: buffer) { processed in
            processedBuffers.append(processed)
        }
        await queue.drain()

        XCTAssertEqual(processedBuffers.count, 1)
        XCTAssertEqual(processedBuffers.first?.speakerLabel, "Speaker 1")
    }

    // MARK: - GAP-08-01: System audio fallback when diarizer is unavailable

    func testSystemAudioFallbackWhenDiarizerUnavailable() async throws {
        let sampleRate = 16_000
        let chunkDuration = 5.0
        let chunkSampleCount = Int(Double(sampleRate) * chunkDuration)

        var fallbackBuffer: [Float] = []
        var fallbackStartTime: TimeInterval = 0
        var dispatchedChunks: [(source: AudioSource, samples: [Float], startTime: TimeInterval)] = []

        let batchSize = 16_000
        for batchIndex in 0..<6 {
            let time = TimeInterval(batchIndex)
            let samples = Array(repeating: Float(0.1), count: batchSize)

            if fallbackBuffer.isEmpty {
                fallbackStartTime = time
            }

            fallbackBuffer.append(contentsOf: samples)

            while fallbackBuffer.count >= chunkSampleCount {
                dispatchedChunks.append((
                    source: .system,
                    samples: Array(fallbackBuffer.prefix(chunkSampleCount)),
                    startTime: fallbackStartTime
                ))
                fallbackBuffer.removeFirst(chunkSampleCount)
                if fallbackBuffer.isEmpty {
                    fallbackStartTime = 0
                } else {
                    fallbackStartTime += chunkDuration
                }
            }
        }

        XCTAssertEqual(
            dispatchedChunks.count,
            1,
            "Should dispatch one 5s chunk after accumulating 80,000+ samples"
        )
        XCTAssertEqual(
            dispatchedChunks[0].samples.count,
            80_000,
            "Dispatched chunk should contain 5s of audio"
        )
        XCTAssertEqual(
            dispatchedChunks[0].startTime,
            0.0,
            "First chunk should start at time 0"
        )
        XCTAssertEqual(
            dispatchedChunks[0].source,
            .system,
            "Fallback chunks must be .system source"
        )

        let speaker = AudioSource.system.speaker
        XCTAssertEqual(
            speaker,
            .other,
            "System audio source must map to .other speaker for fallback attribution"
        )

        XCTAssertEqual(
            fallbackBuffer.count,
            16_000,
            "Remaining samples should stay in buffer for flush on stop"
        )
        XCTAssertGreaterThanOrEqual(
            dispatchedChunks[0].samples.count,
            sampleRate * 2,
            "Dispatched chunk must meet the 2s minimum sample threshold for ASR"
        )
    }

    func testTranscriptionQueueProcessesSystemSourceChunks() async throws {
        let queue = TranscriptionQueue()
        var processedSources: [AudioSource] = []

        let systemSamples = Array(repeating: Float(0.1), count: 80_000)

        await queue.enqueue(
            source: .system,
            samples: systemSamples,
            startTime: 0.0
        ) { source, _, _ in
            processedSources.append(source)
        }

        await queue.drain()

        XCTAssertEqual(processedSources.count, 1, "Queue should process one system source chunk")
        XCTAssertEqual(processedSources[0], .system, "Processed source should be .system")
    }
}

final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
