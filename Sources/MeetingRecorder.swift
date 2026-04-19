import Foundation
import AVFoundation
import FluidAudio

/// Callback types for meeting transcription
typealias MeetingTranscriptCallback = (MeetingSegment) -> Void
typealias MeetingErrorCallback = (Error) -> Void

/// Manages audio recording and streaming transcription for meetings
/// Uses dual-channel capture: microphone (Me) and system audio (Other)
@MainActor
class MeetingRecorder: NSObject, ObservableObject {
    static let shared = MeetingRecorder()
    
    // MARK: - Published Properties
    
    @Published private(set) var isRecording = false
    @Published private(set) var micLevel: Float = -160
    @Published private(set) var systemLevel: Float = -160
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var segmentCount: Int = 0
    @Published private(set) var lastError: String?
    @Published private(set) var activeSpeakers: [String] = ["Me", "Other"]
    @Published private(set) var hasSystemAudioPermission = false
    @Published private(set) var activeSpeakerLabel: String = ""
    
    // MARK: - Audio Components

    private var dualCapture: DualChannelAudioCapture?
    private var voiceToText: VoiceToTextProtocol?
    private var diarizerManager: DiarizerManager?
    private var speakerBufferManager: SpeakerBufferManager?
    private var bufferConsumerTask: Task<Void, Never>?
    private var systemFallbackBuffer: [Float] = []
    private var systemFallbackStartTime: TimeInterval = 0
    private let systemFallbackChunkDuration: TimeInterval = 5.0

    // MARK: - State

    private var startTime: Date?
    private var durationTimer: Timer?
    private var transcriptCallback: MeetingTranscriptCallback?
    private var errorCallback: MeetingErrorCallback?
    private var micVAD: VADStateMachine?
    private var pendingMicSegmentId: UUID?
    private var pendingSystemSegmentId: UUID?
    private var ghostMicCleanupTask: Task<Void, Never>?
    private var ghostSystemCleanupTask: Task<Void, Never>?
    
    // Transcription queue to prevent concurrent CoreML predictions
    private let transcriptionQueue = TranscriptionQueue()
    private let minimumMicPendingVisibilityNanoseconds: UInt64 = 350_000_000
    private let minimumSystemPendingVisibilityNanoseconds: UInt64 = 900_000_000
    private let microphoneSilenceThresholdDB: Float = -45
    private let micGhostCleanupDelaySeconds: Double = 6.0
    private let systemGhostCleanupDelaySeconds: Double = 8.0
    
    // MARK: - Configuration
    
    private let sampleRate: Int = 16000  // Required by FluidAudio
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
    }
    
    // MARK: - Permission Check
    
    /// Check if system audio capture permission is available
    func checkSystemAudioPermission() async -> Bool {
        let capture = DualChannelAudioCapture()
        hasSystemAudioPermission = await capture.checkPermissions()
        return hasSystemAudioPermission
    }
    
    // MARK: - Recording Control
    
    func startRecording(
        onTranscript: @escaping MeetingTranscriptCallback,
        onError: @escaping MeetingErrorCallback
    ) async throws {
        guard !isRecording else {
            throw MeetingRecorderError.alreadyRecording
        }
        
        // Store callbacks
        transcriptCallback = onTranscript
        errorCallback = onError
        
        // Initialize ASR engine
        voiceToText = VoiceToTextFactory.createVoiceToText()

        do {
            let diarizer = DiarizerManager()
            let models = try await DiarizerModels.load()
            diarizer.initialize(models: models)

            let manager = SpeakerBufferManager(
                diarizer: diarizer,
                sampleRate: sampleRate,
                pollingInterval: 150_000_000,
                microWindowSeconds: 7
            )

            manager.onSpeechDetected = { [weak self] startTime, speakerLabel in
                guard let self = self else { return }
                Task { @MainActor in
                    self.handleSystemSpeechDetected(startTime: startTime, speakerLabel: speakerLabel)
                }
            }

            diarizerManager = diarizer
            speakerBufferManager = manager

            await manager.start()
            bufferConsumerTask = Task { [weak self] in
                guard let self = self else { return }
                for await buffer in manager.buffers {
                    await MainActor.run {
                        self.activeSpeakerLabel = buffer.speakerLabel
                    }
                    await self.transcriptionQueue.enqueue(buffer: buffer) { [weak self] buffered in
                        await self?.transcribeClosedBuffer(buffered)
                    }
                }
            }

            Logger.log("Diarization enabled with 7s micro-windows", log: Logger.general)
        } catch {
            diarizerManager = nil
            speakerBufferManager = nil
            bufferConsumerTask = nil
            Logger.log("Failed to initialize diarizer, falling back to source-based transcription: \(error)", log: Logger.general, type: .error)
        }
        
        // Create dual channel capture
        dualCapture = DualChannelAudioCapture()
        
        guard let capture = dualCapture else {
            throw MeetingRecorderError.recordingFailed
        }

        let activeBufferManager = speakerBufferManager
        
        // Start dual channel capture
        do {
            try await capture.startCapture(
                onAudioChunk: { [weak self] source, samples, startTime in
                    guard let self = self else { return }
                    // Mic channel is always "Me"; other callback sources remain unknown/empty.
                    Task { @MainActor in
                        self.activeSpeakerLabel = source == .microphone ? Speaker.me.displayName : ""
                    }
                    // Use transcription queue to serialize CoreML predictions
                    Task {
                        await self.transcriptionQueue.enqueue(
                            source: source,
                            samples: samples,
                            startTime: startTime,
                            processor: { src, samp, time in
                                await self.processAudioChunk(source: src, samples: samp, startTime: time)
                            }
                        )
                    }
                },
                onSystemBatch: { [weak self] samples, time in
                    guard let self = self else { return }
                    Task {
                        if let manager = activeBufferManager {
                            await MainActor.run {
                                self.activeSpeakerLabel = ""
                            }
                            await manager.onAudioBatch(samples, atTime: time)
                        } else {
                            await MainActor.run {
                                self.activeSpeakerLabel = ""
                            }
                            await self.accumulateSystemFallback(samples, atTime: time)
                        }
                    }
                },
                onMicrophoneLevel: { [weak self] db in
                    guard let self = self else { return }
                    Task { @MainActor in
                        await self.handleMicLevelUpdate(db: db)
                    }
                }
            )
        } catch {
            Logger.log("Failed to start dual capture: \(error)", log: Logger.general, type: .error)
            throw MeetingRecorderError.recordingFailed
        }
        
        // Initialize state
        startTime = Date()
        isRecording = true
        micVAD = VADStateMachine(thresholdDB: -45, onsetDuration: .milliseconds(200), offsetDuration: .milliseconds(500))
        pendingMicSegmentId = nil
        pendingSystemSegmentId = nil
        segmentCount = 0
        lastError = nil
        systemFallbackBuffer = []
        systemFallbackStartTime = 0
        activeSpeakerLabel = ""
        hasSystemAudioPermission = capture.hasScreenCapturePermission
        
        // Start duration timer
        startDurationTimer()
        
        // Update active speakers based on permissions
        if hasSystemAudioPermission {
            activeSpeakers = ["Me", "Other"]
        } else {
            activeSpeakers = ["Me"]
            lastError = "System audio not available. Only your voice will be captured."
        }
        
        Logger.log("Meeting recording started with dual-channel capture", log: Logger.general)
    }
    
    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        
        // Stop duration timer
        durationTimer?.invalidate()
        durationTimer = nil
        
        // === ZERO DATA LOSS TEARDOWN ===
        // This order is non-negotiable. Rationale:
        // 1. Stop producer -> flushes remaining open buffer, finishes the AsyncStream
        // 2. Await consumer -> drains all ClosedSpeakerBuffers emitted by step 1
        // 3. Stop capture -> returns final mic audio. Safe here because stopCapture()
        //    only retrieves buffered mic samples; it does not affect the system audio
        //    pipeline (SpeakerBufferManager already stopped in step 1).
        // 4. Drain ASR queue -> waits for all in-flight predictions to finish
        // 5. Process final mic chunk directly
        // Cancelling the consumer before the producer would silently drop the last speaker turn.

        // Step 1: Stop producer (flushes final buffer)
        if let manager = speakerBufferManager {
            await manager.stop()
            Logger.log("SpeakerBufferManager stopped", log: Logger.general)
        }

        // Step 2: Await consumer completion (drains all remaining closed buffers)
        if let task = bufferConsumerTask {
            _ = await task.value
            bufferConsumerTask = nil
        }

        // Step 2b: Flush any remaining system fallback buffer (no-diarizer path)
        if !systemFallbackBuffer.isEmpty {
            let remainingChunk = systemFallbackBuffer
            let remainingStart = systemFallbackStartTime
            systemFallbackBuffer = []
            systemFallbackStartTime = 0
            await transcriptionQueue.enqueue(
                source: .system,
                samples: remainingChunk,
                startTime: remainingStart,
                processor: { [weak self] src, samp, start in
                    await self?.processAudioChunk(source: src, samples: samp, startTime: start, isFinal: true)
                }
            )
        }

        // Step 3: Stop capture and retrieve remaining mic audio
        // stopCapture() only retrieves buffered mic samples; it does not affect the
        // system audio pipeline (SpeakerBufferManager already stopped in step 1).
        // Placed after consumer completion to avoid any race with system audio callbacks.
        var finalMicAudio: (samples: [Float], startTime: TimeInterval)?
        if let capture = dualCapture {
            finalMicAudio = await capture.stopCapture()
        }
        
        // Step 4: Drain ASR queue (ensures all enqueued transcriptions finish)
        await transcriptionQueue.drain()
        
        // Step 5: Process final mic chunk directly
        if let micAudio = finalMicAudio, !micAudio.samples.isEmpty {
            await processAudioChunk(
                source: .microphone,
                samples: micAudio.samples,
                startTime: micAudio.startTime,
                isFinal: true
            )
        }
        
        isRecording = false
        
        // Cleanup (safe now — all transcription work is complete)
        cleanup()
        
        Logger.log("Meeting recording stopped", log: Logger.general)
        return nil  // No file URL since we process in memory
    }
    
    func cancelRecording() {
        durationTimer?.invalidate()
        durationTimer = nil

        bufferConsumerTask?.cancel()
        bufferConsumerTask = nil

        if let manager = speakerBufferManager {
            Task {
                await manager.stop()
            }
        }
        
        if let capture = dualCapture {
            Task {
                await capture.stopCapture()
            }
        }
        
        isRecording = false
        cleanup()
        Logger.log("Meeting recording cancelled", log: Logger.general)
    }
    
    private func cleanup() {
        ghostMicCleanupTask?.cancel()
        ghostMicCleanupTask = nil
        ghostSystemCleanupTask?.cancel()
        ghostSystemCleanupTask = nil
        transcriptCallback = nil
        errorCallback = nil
        voiceToText = nil
        diarizerManager = nil
        dualCapture = nil
        speakerBufferManager = nil
        bufferConsumerTask = nil
        activeSpeakerLabel = ""
        systemFallbackBuffer = []
        systemFallbackStartTime = 0
        pendingMicSegmentId = nil
        pendingSystemSegmentId = nil
        micVAD = nil
    }
    
    // MARK: - Duration Timer
    
    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateDuration()
            }
        }
    }
    
    private func updateDuration() {
        guard let start = startTime else { return }
        recordingDuration = Date().timeIntervalSince(start)
        
        // Update levels from dual capture
        if let capture = dualCapture {
            micLevel = capture.micLevel
            systemLevel = capture.systemLevel
        }
    }
    
    // MARK: - Audio Processing

    /// Accumulates system audio samples when no diarizer is available.
    /// Dispatches fixed 5s chunks through the transcription queue as `.system`.
    private func accumulateSystemFallback(_ samples: [Float], atTime time: TimeInterval) {
        if systemFallbackBuffer.isEmpty {
            systemFallbackStartTime = time
        }

        systemFallbackBuffer.append(contentsOf: samples)

        let chunkSampleCount = Int(Double(sampleRate) * systemFallbackChunkDuration)
        while systemFallbackBuffer.count >= chunkSampleCount {
            let chunk = Array(systemFallbackBuffer.prefix(chunkSampleCount))
            let chunkStart = systemFallbackStartTime
            systemFallbackBuffer.removeFirst(chunkSampleCount)
            if systemFallbackBuffer.isEmpty {
                systemFallbackStartTime = 0
            } else {
                systemFallbackStartTime += Double(chunkSampleCount) / Double(sampleRate)
            }

            Task { [weak self] in
                guard let self = self else { return }
                await self.transcriptionQueue.enqueue(
                    source: .system,
                    samples: chunk,
                    startTime: chunkStart,
                    processor: { src, samp, start in
                        await self.processAudioChunk(source: src, samples: samp, startTime: start)
                    }
                )
            }
        }
    }

    private func processAudioChunk(source: AudioSource, samples: [Float], startTime: TimeInterval, isFinal: Bool = false) async {
        guard let voiceToText = voiceToText else {
            Logger.log("processAudioChunk: voiceToText not available", log: Logger.general, type: .error)
            return
        }

        guard isFinal || samples.count >= sampleRate * 2 else {
            Logger.log("processAudioChunk: not enough samples (\(samples.count))", log: Logger.general)
            return
        }

        let sourceName = source == .microphone ? "mic" : "system"

        if source == .microphone {
            let averagePower = averagePowerDB(for: samples)
            guard isFinal || averagePower > microphoneSilenceThresholdDB else {
                Logger.log(
                    "processAudioChunk: skipping silent mic chunk at \(String(format: "%.1f", startTime))s (\(String(format: "%.1f", averagePower)) dB)",
                    log: Logger.general,
                    type: .debug
                )
                return
            }
        }

        Logger.log("processAudioChunk: processing \(sourceName) chunk with \(samples.count) samples", log: Logger.general)

        let chunkDuration = Double(samples.count) / Double(sampleRate)
        let endTime = startTime + chunkDuration
        let pendingSegment: MeetingSegment
        if source == .microphone,
           let existingId = pendingMicSegmentId,
           let existing = MeetingSession.shared.liveTranscript.first(where: { $0.id == existingId }) {
            pendingSegment = existing
            pendingMicSegmentId = nil
            ghostMicCleanupTask?.cancel()
            ghostMicCleanupTask = nil
        } else if source == .system,
                  let existingId = pendingSystemSegmentId,
                  let existing = MeetingSession.shared.liveTranscript.first(where: { $0.id == existingId }),
                  abs(existing.startTime - startTime) < 6.0 {
            pendingSegment = existing
            pendingSystemSegmentId = nil
            ghostSystemCleanupTask?.cancel()
            ghostSystemCleanupTask = nil
        } else {
            pendingSegment = MeetingSegment(
                speaker: source.speaker,
                text: "",
                startTime: startTime,
                endTime: endTime,
                confidence: 0,
                isPending: true
            )
            segmentCount += 1
            transcriptCallback?(pendingSegment)
        }
        let pendingCreatedAt = ContinuousClock.now

        // Create temp WAV file for transcription
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting_\(sourceName)_\(UUID().uuidString).wav")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            // Write samples to WAV file
            try writeWAVFile(samples: samples, to: tempURL)

            let transcriptionText = try await voiceToText.processStream(
                filepath: tempURL.path,
                onEvent: { [weak self, weak pendingSegment] event in
                    self?.handleStreamingEvent(
                        event,
                        for: sourceName,
                        segment: pendingSegment
                    )
                }
            ) { [weak pendingSegment] partialText in
                pendingSegment?.text = partialText
            }

            let normalizedText = transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else {
                Logger.log("processAudioChunk: empty transcription from \(sourceName)", log: Logger.general)
                MeetingSession.shared.replaceSegment(id: pendingSegment.id, with: [])
                return
            }

            if source == .microphone && isFinal && shouldDropDuplicateFinalMicSegment(text: normalizedText, startTime: startTime) {
                Logger.log("processAudioChunk: dropping duplicate final mic segment '\(normalizedText.prefix(50))'", log: Logger.general)
                MeetingSession.shared.replaceSegment(id: pendingSegment.id, with: [])
                return
            }

            // Determine speaker using the capture source. Diarized system audio is handled
            // upstream by SpeakerBufferManager and transcribeClosedBuffer(_:).
            let speaker = source.speaker

            await ensureMinimumPendingVisibility(
                since: pendingCreatedAt,
                minimumNanoseconds: source == .microphone
                    ? minimumMicPendingVisibilityNanoseconds
                    : minimumSystemPendingVisibilityNanoseconds
            )
            pendingSegment.confidence = 0.95
            MeetingSession.shared.finalizeSegment(
                id: pendingSegment.id,
                text: normalizedText,
                speaker: speaker
            )

            Logger.log("processAudioChunk: created \(speaker.displayName) segment #\(segmentCount): '\(normalizedText.prefix(50))'", log: Logger.general)
        } catch {
            pendingSegment.confidence = 0
            MeetingSession.shared.finalizeSegment(
                id: pendingSegment.id,
                text: "[transcription failed]",
                speaker: source.speaker
            )
            Logger.log("processAudioChunk: error processing \(sourceName): \(error)", log: Logger.general, type: .error)
            lastError = error.localizedDescription
        }
    }

    private func transcribeClosedBuffer(_ buffer: ClosedSpeakerBuffer) async {
        guard let voiceToText = voiceToText else {
            Logger.log("transcribeClosedBuffer: voiceToText not available", log: Logger.general, type: .error)
            return
        }

        let sourceName = "system[\(buffer.speakerLabel)]"

        Logger.log(
            "transcribeClosedBuffer: processing \(sourceName) with \(buffer.samples.count) samples",
            log: Logger.general
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting_\(sourceName)_\(UUID().uuidString).wav")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let chunkDuration = Double(buffer.samples.count) / Double(sampleRate)
        let startTime = buffer.startTime
        let endTime = startTime + chunkDuration
        let speaker = Speaker(displayName: buffer.speakerLabel)
        let pendingSegment: MeetingSegment
        if let existingId = pendingSystemSegmentId,
           let existing = MeetingSession.shared.liveTranscript.first(where: { $0.id == existingId }),
           abs(existing.startTime - startTime) < 6.0 {
            pendingSegment = existing
            pendingSystemSegmentId = nil
            ghostSystemCleanupTask?.cancel()
            ghostSystemCleanupTask = nil
        } else {
            pendingSegment = MeetingSegment(
                speaker: speaker,
                text: "",
                startTime: startTime,
                endTime: endTime,
                confidence: 0,
                isPending: true
            )
            segmentCount += 1
            transcriptCallback?(pendingSegment)
        }
        let pendingCreatedAt = ContinuousClock.now

        do {
            try writeWAVFile(samples: buffer.samples, to: tempURL)
            let transcriptionText = try await voiceToText.processStream(
                filepath: tempURL.path,
                onEvent: { [weak self, weak pendingSegment] event in
                    self?.handleStreamingEvent(
                        event,
                        for: sourceName,
                        segment: pendingSegment
                    )
                }
            ) { [weak pendingSegment] partialText in
                pendingSegment?.text = partialText
            }

            let normalizedText = transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else {
                Logger.log("transcribeClosedBuffer: empty transcription from \(sourceName)", log: Logger.general)
                MeetingSession.shared.replaceSegment(id: pendingSegment.id, with: [])
                return
            }

            await ensureMinimumPendingVisibility(
                since: pendingCreatedAt,
                minimumNanoseconds: minimumSystemPendingVisibilityNanoseconds
            )
            pendingSegment.confidence = 0.95
            MeetingSession.shared.finalizeSegment(
                id: pendingSegment.id,
                text: normalizedText,
                speaker: speaker
            )

            Logger.log(
                "transcribeClosedBuffer: created \(buffer.speakerLabel) segment #\(segmentCount): '\(normalizedText.prefix(50))'",
                log: Logger.general
            )
        } catch {
            pendingSegment.confidence = 0
            MeetingSession.shared.finalizeSegment(
                id: pendingSegment.id,
                text: "[transcription failed]",
                speaker: speaker
            )
            Logger.log(
                "transcribeClosedBuffer: error processing \(sourceName): \(error)",
                log: Logger.general,
                type: .error
            )
            lastError = error.localizedDescription
        }
    }

    private func ensureMinimumPendingVisibility(
        since start: ContinuousClock.Instant,
        minimumNanoseconds: UInt64
    ) async {
        let elapsed = start.duration(to: .now)
        let minimum = Duration.nanoseconds(Int64(minimumNanoseconds))
        guard elapsed < minimum else { return }

        let remaining = minimum - elapsed
        try? await Task.sleep(for: remaining)
    }

    private func averagePowerDB(for samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -160 }

        let rms = sqrt(samples.reduce(Float.zero) { partialResult, sample in
            partialResult + (sample * sample)
        } / Float(samples.count))
        return 20 * log10(max(rms, 0.000_000_1))
    }

    private func shouldDropDuplicateFinalMicSegment(text: String, startTime: TimeInterval) -> Bool {
        let normalizedCandidate = normalizedTranscriptText(text)
        guard !normalizedCandidate.isEmpty else { return false }

        guard let lastFinalMicSegment = MeetingSession.shared.liveTranscript
            .reversed()
            .first(where: { !$0.isPending && $0.speaker == .me }) else {
            return false
        }

        let normalizedPrevious = normalizedTranscriptText(lastFinalMicSegment.text)
        guard normalizedCandidate == normalizedPrevious else { return false }

        let maxGap: TimeInterval = 6
        return abs(startTime - lastFinalMicSegment.startTime) <= maxGap
    }

    private func normalizedTranscriptText(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    // MARK: - VAD Coordination

    private enum AudioChannel {
        case mic
        case system
    }

    private func handleMicLevelUpdate(db: Float) async {
        guard let vad = micVAD, isRecording else { return }
        guard let event = await vad.update(levelDB: db) else { return }

        switch event {
        case .startSpeech:
            ghostMicCleanupTask?.cancel()
            ghostMicCleanupTask = nil
            guard pendingMicSegmentId == nil else { return }

            let now = Date().timeIntervalSince(startTime ?? Date())
            let segment = createPendingSegment(speaker: .me, startTime: now)
            pendingMicSegmentId = segment.id
            Logger.log("VAD mic: created pending segment \(segment.id) at \(String(format: "%.2f", now))s", log: Logger.general)
        case .endSpeech:
            startGhostCleanupTask(channel: .mic)
        }
    }

    private func handleSystemSpeechDetected(startTime: TimeInterval, speakerLabel: String) {
        guard pendingSystemSegmentId == nil else { return }

        let speaker = Speaker(displayName: speakerLabel)
        let segment = createPendingSegment(speaker: speaker, startTime: startTime)
        pendingSystemSegmentId = segment.id
        Logger.log(
            "VAD system: created pending segment \(segment.id) for \(speakerLabel) at \(String(format: "%.2f", startTime))s",
            log: Logger.general
        )
        startGhostCleanupTask(channel: .system)
    }

    @discardableResult
    private func createPendingSegment(speaker: Speaker, startTime: TimeInterval) -> MeetingSegment {
        let segment = MeetingSegment(
            speaker: speaker,
            text: "",
            startTime: startTime,
            endTime: startTime,
            confidence: 0,
            isPending: true
        )
        segmentCount += 1
        transcriptCallback?(segment)
        return segment
    }

    private func startGhostCleanupTask(channel: AudioChannel) {
        switch channel {
        case .mic:
            guard let pendingID = pendingMicSegmentId else { return }
            ghostMicCleanupTask?.cancel()
            ghostMicCleanupTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.micGhostCleanupDelaySeconds ?? 6.0))
                guard !Task.isCancelled, let self = self else { return }
                self.cleanupGhostSegment(channel: .mic, expectedSegmentID: pendingID)
            }
        case .system:
            guard let pendingID = pendingSystemSegmentId else { return }
            ghostSystemCleanupTask?.cancel()
            ghostSystemCleanupTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.systemGhostCleanupDelaySeconds ?? 8.0))
                guard !Task.isCancelled, let self = self else { return }
                self.cleanupGhostSegment(channel: .system, expectedSegmentID: pendingID)
            }
        }
    }

    private func cleanupGhostSegment(channel: AudioChannel, expectedSegmentID: UUID) {
        switch channel {
        case .mic:
            guard let id = pendingMicSegmentId else { return }
            guard id == expectedSegmentID else { return }
            if let segment = MeetingSession.shared.liveTranscript.first(where: { $0.id == id }),
               segment.text.isEmpty {
                Logger.log("VAD mic: removing ghost segment \(id)", log: Logger.general)
                MeetingSession.shared.removeSegment(id: id)
            }
            pendingMicSegmentId = nil
        case .system:
            guard let id = pendingSystemSegmentId else { return }
            guard id == expectedSegmentID else { return }
            if let segment = MeetingSession.shared.liveTranscript.first(where: { $0.id == id }),
               segment.text.isEmpty {
                Logger.log("VAD system: removing ghost segment \(id)", log: Logger.general)
                MeetingSession.shared.removeSegment(id: id)
            }
            pendingSystemSegmentId = nil
        }
    }

    private func handleStreamingEvent(
        _ event: StreamingTranscriptionEvent,
        for sourceName: String,
        segment: MeetingSegment?
    ) {
        switch event {
        case .convertingAudio:
            Logger.log("processAudioChunk: \(sourceName) audio accepted by ASR pipeline", log: Logger.general)
        case .decodingStarted:
            Logger.log("processAudioChunk: \(sourceName) decoder started", log: Logger.general)
        case .firstToken:
            Logger.log("processAudioChunk: \(sourceName) produced first token", log: Logger.general)
            if let segment, segment.text.isEmpty {
                segment.text = "…"
            }
        case .finished:
            Logger.log("processAudioChunk: \(sourceName) decoder finished", log: Logger.general)
        }
    }
    
    // MARK: - Helpers
    
    /// Write float samples to a WAV file with proper header
    private func writeWAVFile(samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw MeetingRecorderError.transcriptionFailed("Failed to create output buffer")
        }
        
        // Copy samples to buffer
        guard let floatData = buffer.floatChannelData else {
            throw MeetingRecorderError.transcriptionFailed("Failed to get buffer channel data")
        }
        
        for (i, sample) in samples.enumerated() {
            floatData[0][i] = sample
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        
        // Write to file
        let outputFile = try AVAudioFile(forWriting: url, settings: format.settings)
        try outputFile.write(from: buffer)
    }
    
    var formattedDuration: String {
        let totalSeconds = Int(recordingDuration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    /// Combined normalized level (max of mic and system)
    var normalizedLevel: Float {
        let level = max(micLevel, systemLevel)
        let minDb: Float = -60
        let maxDb: Float = 0
        let clampedLevel = max(minDb, min(maxDb, level))
        return (clampedLevel - minDb) / (maxDb - minDb)
    }
    
    /// Backward compatibility
    var currentLevel: Float {
        max(micLevel, systemLevel)
    }
}

// MARK: - Errors

enum MeetingRecorderError: LocalizedError {
    case alreadyRecording
    case modelLoadFailed(String)
    case invalidURL
    case recordingFailed
    case encodingError(String)
    case transcriptionFailed(String)
    case diarizationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already in progress"
        case .modelLoadFailed(let message):
            return "Failed to load transcription model: \(message)"
        case .invalidURL:
            return "Invalid recording URL"
        case .recordingFailed:
            return "Failed to start recording"
        case .encodingError(let message):
            return "Audio encoding error: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .diarizationFailed(let message):
            return "Speaker diarization failed: \(message)"
        }
    }
}
