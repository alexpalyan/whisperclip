import Foundation
import FluidAudio

/// Accumulates per-speaker audio buffers, detects speaker changes via diarization polling,
/// enforces 30s cap and 0.5s floor, resolves stable speaker labels, and emits closed buffers.
///
/// Audio ingestion (`onAudioBatch`) is O(n) append-only — zero inference on the hot path.
/// Diarization runs in a separate polling loop at configurable cadence (default 150ms).
actor SpeakerBufferManager {

    // MARK: - Output Stream

    /// Closed buffers ready for transcription. Caller: `for await buffer in manager.buffers { ... }`
    nonisolated let buffers: AsyncStream<ClosedSpeakerBuffer>

    // MARK: - Configuration

    /// Polling interval in nanoseconds. Default 150ms. Tuning knob for hardware profiles:
    /// - M4 Pro: 150_000_000 (150ms) — near real-time
    /// - M1 Air: 600_000_000 (600ms) — conservative
    nonisolated let pollingInterval: UInt64

    /// Sample rate in Hz. Must match DiarizerManager expectation.
    nonisolated let sampleRate: Int

    /// Micro-window duration: 7s by default.
    nonisolated let microWindowSamples: Int

    /// Maximum buffer duration: 30s = 480,000 samples at 16kHz
    nonisolated let maxSamplesPerBuffer: Int

    /// Minimum buffer duration: 0.5s = 8,000 samples at 16kHz
    nonisolated let minSamplesPerBuffer: Int

    // MARK: - Dependencies

    private let diarizer: any DiarizationProvider
    private var continuation: AsyncStream<ClosedSpeakerBuffer>.Continuation?
    nonisolated(unsafe) var onSpeechDetected: (@Sendable (TimeInterval, String) -> Void)?

    // MARK: - Buffer State

    private var accumulatedSamples: [Float] = []
    private var bufferStartTime: TimeInterval = 0
    private var currentSpeakerId: String?
    private var lastBatchSampleCount: Int = 0

    // MARK: - Speaker Label Resolution

    /// Maps raw diarizer speakerIds ("SPEAKER_00") to display labels ("Speaker 1")
    private var speakerLabelMap: [String: String] = [:]
    private var nextSpeakerNumber: Int = 1

    // MARK: - Polling Task

    private var pollingTask: Task<Void, Never>?

    // MARK: - Init

    init(
        diarizer: any DiarizationProvider,
        sampleRate: Int = 16_000,
        pollingInterval: UInt64 = 150_000_000,
        microWindowSeconds: Int = 7
    ) {
        self.diarizer = diarizer
        self.sampleRate = sampleRate
        self.pollingInterval = pollingInterval
        self.microWindowSamples = sampleRate * microWindowSeconds
        self.maxSamplesPerBuffer = sampleRate * 30   // 30 seconds
        self.minSamplesPerBuffer = sampleRate / 2    // 0.5 seconds (8,000 at 16kHz)

        // AsyncStream setup — synchronous closure form (safe under strict concurrency)
        var cap: AsyncStream<ClosedSpeakerBuffer>.Continuation?
        self.buffers = AsyncStream { continuation in
            cap = continuation
        }
        self.continuation = cap
    }

    // MARK: - Audio Ingestion (Hot Path)

    /// Append audio samples. Called from SCStreamOutput callback via Task { await manager.onAudioBatch(...) }.
    /// O(n) append only — NO diarizer call here.
    func onAudioBatch(_ samples: [Float], atTime time: TimeInterval) {
        if accumulatedSamples.isEmpty {
            bufferStartTime = time
        }
        accumulatedSamples.append(contentsOf: samples)
        lastBatchSampleCount = samples.count
    }

    // MARK: - Lifecycle

    /// Start the diarization polling loop.
    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task {
            while !Task.isCancelled {
                pollDiarizer()
                do {
                    try await Task.sleep(nanoseconds: pollingInterval)
                } catch {
                    break  // Task cancelled during sleep
                }
            }
        }
    }

    /// Stop polling, flush or discard the current buffer, finish the AsyncStream.
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        flushOrDiscardCurrentBuffer()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Polling

    private func pollDiarizer() {
        // Check 30s cap regardless of diarization result.
        // Loop handles the case where a single onAudioBatch exceeded 2x the cap.
        while accumulatedSamples.count >= maxSamplesPerBuffer {
            flushCappedBuffer()
        }

        // Need samples for diarization
        guard !accumulatedSamples.isEmpty else { return }

        let window = accumulatedSamples
        let windowStartTime = bufferStartTime

        do {
            let result = try diarizer.diarize(window, sampleRate: sampleRate, atTime: windowStartTime)

            // Empty result (silence/no speech) — discard full silent windows instead of
            // emitting phantom buffers that later become failed transcript bubbles.
            guard !result.segments.isEmpty else {
                if accumulatedSamples.count >= microWindowSamples {
                    discardSilentMicroWindow()
                }
                return
            }

            // Extract dominant speaker by total speech duration
            var durationBySpeaker: [String: Float] = [:]
            for seg in result.segments {
                durationBySpeaker[seg.speakerId, default: 0] += seg.durationSeconds
            }

            guard let dominantId = durationBySpeaker.max(by: { $0.value < $1.value })?.key,
                  !dominantId.isEmpty else { return }

            if let onSpeech = self.onSpeechDetected {
                onSpeech(bufferStartTime, resolveLabel(for: dominantId))
            }

            // Speaker change detection
            if let current = currentSpeakerId, current != dominantId {
                let diarizerOffset = result.segments.first(where: { $0.speakerId == dominantId })
                    .map { Double($0.startTimeSeconds) }
                    ?? Double(accumulatedSamples.count) / Double(sampleRate)
                let fallbackOffset = Double(max(0, accumulatedSamples.count - lastBatchSampleCount)) / Double(sampleRate)
                let changeOffset = diarizerOffset > 0 ? diarizerOffset : fallbackOffset

                Logger.log(
                    "SpeakerBufferManager: speaker change \(current) -> \(dominantId) at \(String(format: "%.2f", changeOffset))s",
                    log: Logger.general)
                splitAndFlushCurrentBuffer(atSeconds: changeOffset, previousSpeakerId: current, newSpeakerId: dominantId)
                currentSpeakerId = dominantId
                return
            }

            currentSpeakerId = dominantId

            if accumulatedSamples.count >= microWindowSamples {
                flushMicroWindow()
            }

        } catch {
            Logger.log("SpeakerBufferManager: diarization error: \(error)", log: Logger.general, type: .error)
        }
    }

    // MARK: - Buffer Flush

    nonisolated func splitBuffer(_ samples: [Float], atSeconds offset: Double) -> ([Float], [Float]) {
        let splitIndex = min(max(0, Int(offset * Double(sampleRate))), samples.count)
        return (Array(samples.prefix(splitIndex)), Array(samples.dropFirst(splitIndex)))
    }

    private func flushMicroWindow() {
        let windowSamples = Array(accumulatedSamples.prefix(microWindowSamples))
        let overflow = Array(accumulatedSamples.dropFirst(microWindowSamples))

        guard windowSamples.count >= minSamplesPerBuffer else {
            accumulatedSamples = overflow
            return
        }

        let label = resolveLabel(for: currentSpeakerId)
        let closed = ClosedSpeakerBuffer(
            samples: windowSamples,
            speakerLabel: label,
            startTime: bufferStartTime
        )

        Logger.log(
            "SpeakerBufferManager: micro-window flush \(label) \(windowSamples.count) samples",
            log: Logger.general
        )

        continuation?.yield(closed)
        bufferStartTime += Double(windowSamples.count) / Double(sampleRate)
        accumulatedSamples = overflow
    }

    private func discardSilentMicroWindow() {
        let discardedCount = min(accumulatedSamples.count, microWindowSamples)
        let overflow = Array(accumulatedSamples.dropFirst(discardedCount))

        Logger.log(
            "SpeakerBufferManager: discarded silent micro-window \(discardedCount) samples",
            log: Logger.general
        )

        bufferStartTime += Double(discardedCount) / Double(sampleRate)
        accumulatedSamples = overflow
        currentSpeakerId = nil
    }

    private func splitAndFlushCurrentBuffer(
        atSeconds offset: Double,
        previousSpeakerId: String,
        newSpeakerId: String
    ) {
        let (firstSamples, secondSamples) = splitBuffer(accumulatedSamples, atSeconds: offset)

        if firstSamples.count >= minSamplesPerBuffer {
            continuation?.yield(
                ClosedSpeakerBuffer(
                    samples: firstSamples,
                    speakerLabel: resolveLabel(for: previousSpeakerId),
                    startTime: bufferStartTime
                )
            )
        }

        let splitTime = bufferStartTime + Double(firstSamples.count) / Double(sampleRate)
        bufferStartTime = splitTime
        accumulatedSamples = secondSamples
        currentSpeakerId = newSpeakerId
    }

    /// Force-flush exactly `maxSamplesPerBuffer` samples, keeping any overflow in `accumulatedSamples`.
    /// Used only by the 30s cap check in `pollDiarizer()`.
    private func flushCappedBuffer() {
        let cappedSamples = Array(accumulatedSamples.prefix(maxSamplesPerBuffer))
        let overflow = Array(accumulatedSamples.dropFirst(maxSamplesPerBuffer))

        guard cappedSamples.count >= minSamplesPerBuffer else {
            accumulatedSamples = overflow
            return
        }

        let label = resolveLabel(for: currentSpeakerId)
        let closed = ClosedSpeakerBuffer(
            samples: cappedSamples,
            speakerLabel: label,
            startTime: bufferStartTime
        )

        Logger.log(
            "SpeakerBufferManager: force-flushed capped buffer \(label) \(cappedSamples.count) samples",
            log: Logger.general)

        continuation?.yield(closed)

        // Advance bufferStartTime for the overflow
        bufferStartTime += Double(maxSamplesPerBuffer) / Double(sampleRate)
        accumulatedSamples = overflow
    }

    private func flushCurrentBuffer() {
        guard accumulatedSamples.count >= minSamplesPerBuffer else {
            // Below 0.5s floor — discard
            Logger.log(
                "SpeakerBufferManager: discarded short buffer \(accumulatedSamples.count) < \(minSamplesPerBuffer) samples",
                log: Logger.general)
            accumulatedSamples = []
            return
        }

        let label = resolveLabel(for: currentSpeakerId)
        let closed = ClosedSpeakerBuffer(
            samples: accumulatedSamples,
            speakerLabel: label,
            startTime: bufferStartTime
        )

        Logger.log(
            "SpeakerBufferManager: flushed buffer \(label) \(accumulatedSamples.count) samples",
            log: Logger.general)

        continuation?.yield(closed)
        accumulatedSamples = []
    }

    /// Flush if >= minSamples, discard if shorter. Used by stop().
    private func flushOrDiscardCurrentBuffer() {
        guard !accumulatedSamples.isEmpty else { return }
        flushCurrentBuffer()
    }

    // MARK: - Speaker Label Resolution

    private func resolveLabel(for rawSpeakerId: String?) -> String {
        guard let rawId = rawSpeakerId, !rawId.isEmpty else {
            return "Speaker \(nextSpeakerNumber)"
        }

        if let existing = speakerLabelMap[rawId] {
            return existing
        }

        let label = "Speaker \(nextSpeakerNumber)"
        speakerLabelMap[rawId] = label
        nextSpeakerNumber += 1
        return label
    }
}
