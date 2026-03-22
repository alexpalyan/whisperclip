import XCTest
import FluidAudio
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
