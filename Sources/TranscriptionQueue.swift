import Foundation

/// Serializes transcription requests to prevent concurrent CoreML predictions
/// which can cause crashes due to thread-safety issues.
///
/// Promoted from private actor in MeetingRecorder.swift to enable reuse in Phase 8.
actor TranscriptionQueue {
    private struct FragmentRequest {
        let sequence: Int
        let source: AudioSource
        let samples: [Float]
        let startTime: TimeInterval
        let processor: @MainActor (AudioSource, [Float], TimeInterval) async -> Void
    }

    private var isProcessing = false
    private var pendingRequests: [(AudioSource, [Float], TimeInterval, @MainActor (AudioSource, [Float], TimeInterval) async -> Void)] = []
    private var pendingBufferRequests: [(ClosedSpeakerBuffer, @MainActor (ClosedSpeakerBuffer) async -> Void)] = []
    private var micFragments: [FragmentRequest] = []
    private var systemFragments: [FragmentRequest] = []
    private var activeFragmentSource: AudioSource?
    private var nextFragmentSequence: [AudioSource: Int] = [:]
    private var completedFragmentSequence: [AudioSource: Int] = [:]
    private let maxQueuedSeconds: Double = 2.0
    private let fragmentSampleRate: Int = 16000

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

    func enqueueFragment(
        source: AudioSource,
        samples: [Float],
        startTime: TimeInterval,
        processor: @escaping @MainActor (AudioSource, [Float], TimeInterval) async -> Void
    ) async -> Int {
        let sequence = (nextFragmentSequence[source] ?? 0) + 1
        nextFragmentSequence[source] = sequence
        let request = FragmentRequest(
            sequence: sequence,
            source: source,
            samples: samples,
            startTime: startTime,
            processor: processor
        )

        if source == .microphone {
            micFragments.append(request)
        } else {
            while totalQueuedDuration(for: .system) + Double(samples.count) / Double(fragmentSampleRate) > maxQueuedSeconds,
                  !systemFragments.isEmpty {
                Logger.log(
                    "TranscriptionQueue: dropping oldest system fragment (backpressure, queue > \(maxQueuedSeconds)s)",
                    log: Logger.general,
                    type: .error
                )
                systemFragments.removeFirst()
            }
            systemFragments.append(request)
        }

        guard !isProcessing else { return sequence }
        await processNextFragment()
        return sequence
    }

    private func processNext() async {
        if !micFragments.isEmpty || !systemFragments.isEmpty {
            await processNextFragment()
        } else if !pendingRequests.isEmpty {
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

    func totalQueuedDuration(for source: AudioSource) -> TimeInterval {
        let lane = source == .microphone ? micFragments : systemFragments
        return lane.reduce(0.0) { partialResult, fragment in
            partialResult + Double(fragment.samples.count) / Double(fragmentSampleRate)
        }
    }

    private func processNextFragment() async {
        let nextRequest: FragmentRequest?
        if !micFragments.isEmpty {
            nextRequest = micFragments.removeFirst()
        } else if !systemFragments.isEmpty {
            nextRequest = systemFragments.removeFirst()
        } else {
            return
        }

        guard let fragment = nextRequest else { return }
        isProcessing = true
        activeFragmentSource = fragment.source
        Logger.log(
            "TranscriptionQueue: processing fragment seq=\(fragment.sequence) source=\(fragment.source == .microphone ? "mic" : "system") samples=\(fragment.samples.count)",
            log: Logger.general
        )
        await fragment.processor(fragment.source, fragment.samples, fragment.startTime)
        completedFragmentSequence[fragment.source] = fragment.sequence
        Logger.log(
            "TranscriptionQueue: finished fragment seq=\(fragment.sequence) source=\(fragment.source == .microphone ? "mic" : "system")",
            log: Logger.general
        )
        activeFragmentSource = nil
        isProcessing = false

        await processNext()
    }

    func drainFragments(for source: AudioSource) async {
        while activeFragmentSource == source
            || !(source == .microphone ? micFragments.isEmpty : systemFragments.isEmpty) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func waitUntilProcessed(source: AudioSource, upTo sequence: Int) async {
        guard sequence > 0 else { return }

        while (completedFragmentSequence[source] ?? 0) < sequence {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Wait until all in-flight and pending transcription work completes
    func drain() async {
        while isProcessing
            || !pendingRequests.isEmpty
            || !pendingBufferRequests.isEmpty
            || !micFragments.isEmpty
            || !systemFragments.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
    }
}
