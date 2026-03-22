import Foundation

/// Serializes transcription requests to prevent concurrent CoreML predictions
/// which can cause crashes due to thread-safety issues.
///
/// Promoted from private actor in MeetingRecorder.swift to enable reuse in Phase 8.
actor TranscriptionQueue {
    private var isProcessing = false
    private var pendingRequests: [(AudioSource, [Float], TimeInterval, @MainActor (AudioSource, [Float], TimeInterval) async -> Void)] = []
    private var pendingBufferRequests: [(ClosedSpeakerBuffer, @MainActor (ClosedSpeakerBuffer) async -> Void)] = []

    func enqueue(
        source: AudioSource,
        samples: [Float],
        startTime: TimeInterval,
        processor: @escaping @MainActor (AudioSource, [Float], TimeInterval) async -> Void
    ) async {
        if isProcessing {
            pendingRequests.append((source, samples, startTime, processor))
            return
        }

        isProcessing = true
        await processor(source, samples, startTime)
        isProcessing = false

        await processNext()
    }

    func enqueue(
        buffer: ClosedSpeakerBuffer,
        processor: @escaping @MainActor (ClosedSpeakerBuffer) async -> Void
    ) async {
        if isProcessing {
            pendingBufferRequests.append((buffer, processor))
            return
        }

        isProcessing = true
        await processor(buffer)
        isProcessing = false

        await processNext()
    }

    private func processNext() async {
        if !pendingRequests.isEmpty {
            let (source, samples, startTime, processor) = pendingRequests.removeFirst()
            isProcessing = true
            await processor(source, samples, startTime)
            isProcessing = false

            await processNext()
        } else if !pendingBufferRequests.isEmpty {
            let (buffer, processor) = pendingBufferRequests.removeFirst()
            isProcessing = true
            await processor(buffer)
            isProcessing = false

            await processNext()
        }
    }

    /// Wait until all in-flight and pending transcription work completes
    func drain() async {
        while isProcessing || !pendingRequests.isEmpty || !pendingBufferRequests.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
    }
}
