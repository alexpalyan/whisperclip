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
    private var micFragmentBuffer: [Float] = []
    private var micFragmentStartTime: TimeInterval = 0
    private var micPreRollBuffer: [Float] = []
    private var micPreRollStartTime: TimeInterval = 0
    private let defaultMicFragmentTargetSamples: Int = 16000
    private let parakeetMicFragmentTargetSamples: Int = 2_560
    private let micFinalPartialGraceNanoseconds: UInt64 = 800_000_000
    private let micLatePartialRetentionNanoseconds: UInt64 = 1_500_000_000

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
    private var micFinalizeTasks: [UUID: Task<Void, Never>] = [:]
    private var micLateCleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var micPreviewTasks: [UUID: Task<Void, Never>] = [:]
    private var micBestStreamingTextBySegment: [UUID: String] = [:]
    private var micUtteranceSamplesBySegment: [UUID: [Float]] = [:]
    private var micChunkEventsBySegment: [UUID: [MicChunkEvent]] = [:]
    private var micLastPreviewSampleCountBySegment: [UUID: Int] = [:]
    private var latestMicFragmentSequence = 0
    private var micSessionGeneration = 0
    
    // Transcription queue to prevent concurrent CoreML predictions
    private let transcriptionQueue = TranscriptionQueue()
    private let minimumMicPendingVisibilityNanoseconds: UInt64 = 350_000_000
    private let minimumSystemPendingVisibilityNanoseconds: UInt64 = 900_000_000
    private let microphoneSilenceThresholdDB: Float = -45
    private let micGhostCleanupDelaySeconds: Double = 6.0
    private let systemGhostCleanupDelaySeconds: Double = 8.0
    private let parakeetPreviewInitialSamples = 16_000
    private let parakeetPreviewAdditionalSamples = 8_000
    
    // MARK: - Configuration
    
    private let sampleRate: Int = 16000  // Required by FluidAudio

    private var currentMicFragmentTargetSamples: Int {
        if voiceToText is ParakeetVoiceToTextModel {
            return parakeetMicFragmentTargetSamples
        }
        return defaultMicFragmentTargetSamples
    }

    private var currentMicPreRollSamples: Int {
        currentMicFragmentTargetSamples / 2
    }
    
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
        micVAD = VADStateMachine(
            thresholdDB: microphoneSilenceThresholdDB,
            onsetDuration: .milliseconds(200),
            offsetDuration: .milliseconds(500)
        )
        pendingMicSegmentId = nil
        pendingSystemSegmentId = nil
        segmentCount = 0
        lastError = nil
        systemFallbackBuffer = []
        systemFallbackStartTime = 0
        micFragmentBuffer = []
        micFragmentStartTime = 0
        micPreRollBuffer = []
        micPreRollStartTime = 0
        latestMicFragmentSequence = 0
        micSessionGeneration = 0
        micFinalizeTasks.values.forEach { $0.cancel() }
        micFinalizeTasks = [:]
        micLateCleanupTasks.values.forEach { $0.cancel() }
        micLateCleanupTasks = [:]
        micPreviewTasks.values.forEach { $0.cancel() }
        micPreviewTasks = [:]
        micBestStreamingTextBySegment = [:]
        micUtteranceSamplesBySegment = [:]
        micChunkEventsBySegment = [:]
        micLastPreviewSampleCountBySegment = [:]
        activeSpeakerLabel = ""

        // Initialize ASR engine
        voiceToText = VoiceToTextFactory.createVoiceToText()
        if let parakeetVoiceToText = voiceToText as? ParakeetVoiceToTextModel {
            parakeetVoiceToText.onEOU = { [weak self] source in
                self?.handleParakeetEOU(source: source)
            }
        }
        if let whisperVoiceToText = voiceToText as? VoiceToTextModel {
            try? await whisperVoiceToText.load()
        }
        if voiceToText is ParakeetVoiceToTextModel {
            Logger.log(
                "Parakeet debug audio dump enabled: \(shouldDumpParakeetDebugAudio())",
                log: Logger.general,
                type: .debug
            )
        }

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
                    if source == .microphone {
                        Task { @MainActor in
                            self.accumulateMicFragment(samples, atTime: startTime)
                        }
                    } else {
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
        let flushedMicSequence = await flushPendingMicFragmentBuffer()
        let finalPendingMicSegmentId = pendingMicSegmentId
        let finalMicFragmentSequence = max(latestMicFragmentSequence, flushedMicSequence ?? 0)
        pendingMicSegmentId = nil

        Logger.log(
            "stopRecording: waiting for mic fragments through sequence \(finalMicFragmentSequence), finalizeTasks=\(micFinalizeTasks.count)",
            log: Logger.general
        )

        await transcriptionQueue.waitUntilProcessed(source: .microphone, upTo: finalMicFragmentSequence)
        finalizePendingMicSegmentIfNeeded(
            id: finalPendingMicSegmentId,
            reason: "during stop",
            allowDeferredRemoval: false
        )

        let finalizeTasks = Array(micFinalizeTasks.values)
        for task in finalizeTasks {
            _ = await task.value
        }

        let lateCleanupTasks = Array(micLateCleanupTasks.values)
        for task in lateCleanupTasks {
            _ = await task.value
        }

        // Step 4: Drain ASR queue (ensures all enqueued transcriptions finish)
        await transcriptionQueue.drain()

        if let voiceToText {
            try? await voiceToText.stopStreamingSession(source: .microphone)
            try? await voiceToText.stopStreamingSession(source: .system)
        }
        
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
        micFinalizeTasks.values.forEach { $0.cancel() }
        micFinalizeTasks = [:]
        micLateCleanupTasks.values.forEach { $0.cancel() }
        micLateCleanupTasks = [:]
        micBestStreamingTextBySegment = [:]
        micUtteranceSamplesBySegment = [:]
        transcriptCallback = nil
        errorCallback = nil
        if let parakeetVoiceToText = voiceToText as? ParakeetVoiceToTextModel {
            parakeetVoiceToText.onEOU = nil
        }
        voiceToText = nil
        diarizerManager = nil
        dualCapture = nil
        speakerBufferManager = nil
        bufferConsumerTask = nil
        activeSpeakerLabel = ""
        systemFallbackBuffer = []
        systemFallbackStartTime = 0
        micFragmentBuffer = []
        micFragmentStartTime = 0
        micPreRollBuffer = []
        micPreRollStartTime = 0
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

    private func accumulateMicFragment(_ samples: [Float], atTime time: TimeInterval) {
        appendMicPreRoll(samples, atTime: time)

        guard let activeSegmentID = pendingMicSegmentId else {
            return
        }

        micUtteranceSamplesBySegment[activeSegmentID, default: []].append(contentsOf: samples)

        if micFragmentBuffer.isEmpty {
            micFragmentStartTime = time
        }
        micFragmentBuffer.append(contentsOf: samples)

        let fragmentTargetSamples = currentMicFragmentTargetSamples
        while micFragmentBuffer.count >= fragmentTargetSamples {
            let fragment = Array(micFragmentBuffer.prefix(fragmentTargetSamples))
            let fragmentStart = micFragmentStartTime
            micFragmentBuffer.removeFirst(fragmentTargetSamples)
            micFragmentStartTime += Double(fragmentTargetSamples) / Double(sampleRate)

            Task { [weak self] in
                guard let self = self else { return }
                _ = await self.enqueueMicFragment(
                    fragment,
                    startTime: fragmentStart,
                    segmentID: activeSegmentID
                )
            }
        }
    }

    private func appendMicPreRoll(_ samples: [Float], atTime time: TimeInterval) {
        if pendingMicSegmentId != nil {
            return
        }

        if micPreRollBuffer.isEmpty {
            micPreRollStartTime = time
        }
        micPreRollBuffer.append(contentsOf: samples)

        let preRollSamples = currentMicPreRollSamples
        if micPreRollBuffer.count > preRollSamples {
            let overflow = micPreRollBuffer.count - preRollSamples
            micPreRollBuffer.removeFirst(overflow)
            micPreRollStartTime += Double(overflow) / Double(sampleRate)
        }
    }

    private func beginMicUtterancePreRollIfNeeded(segmentID: UUID) {
        guard !micPreRollBuffer.isEmpty else { return }
        guard micFragmentBuffer.isEmpty else { return }

        micFragmentBuffer = micPreRollBuffer
        micFragmentStartTime = micPreRollStartTime
        micUtteranceSamplesBySegment[segmentID] = micPreRollBuffer
        micChunkEventsBySegment[segmentID] = []
        Logger.log(
            "VAD mic: seeded pre-roll for segment \(segmentID.uuidString) with \(micPreRollBuffer.count) samples at \(String(format: "%.2f", micPreRollStartTime))s",
            log: Logger.general
        )
        micPreRollBuffer = []
        micPreRollStartTime = 0
    }

    private func enqueueMicFragment(
        _ samples: [Float],
        startTime: TimeInterval,
        segmentID: UUID?,
        chunkKind: MicChunkKind = .regular
    ) async -> Int {
        let sequence = await transcriptionQueue.enqueueFragment(
            source: .microphone,
            samples: samples,
            startTime: startTime,
            processor: { src, samp, _ in
                let targetSegmentID = segmentID
                guard let voiceToText = self.voiceToText else { return }
                do {
                    try await voiceToText.feedFragment(samp, source: src) { partialText in
                        Logger.log(
                            "mic fragment: partial segment=\(targetSegmentID?.uuidString ?? "nil") chars=\(partialText.count)",
                            log: Logger.general
                        )
                        if let id = targetSegmentID,
                           let segment = MeetingSession.shared.liveTranscript.first(where: { $0.id == id }),
                           segment.isPending {
                            let preferredPartialText = self.preferredLivePreviewText(
                                currentText: segment.text,
                                candidateText: partialText,
                                isAwaitingFinalPartial: segment.isAwaitingFinalPartial
                            )
                            if preferredPartialText != segment.text {
                                segment.text = preferredPartialText
                            }
                            let isAwaitingLateTail = segment.isAwaitingFinalPartial && self.pendingMicSegmentId != id
                            segment.isAwaitingFinalPartial = isAwaitingLateTail
                            if !isAwaitingLateTail {
                                self.micLateCleanupTasks[id]?.cancel()
                                self.micLateCleanupTasks[id] = nil
                            }
                        }
                    }

                    if let id = targetSegmentID,
                       let bestStreamingText = await voiceToText.bestStreamingText(source: src) {
                        let currentBest = self.micBestStreamingTextBySegment[id] ?? ""
                        let preferredBest = self.preferredFinalStreamingText(
                            currentText: currentBest,
                            candidateText: bestStreamingText
                        )
                        if preferredBest != currentBest {
                            self.micBestStreamingTextBySegment[id] = preferredBest
                        }
                    }

                    if let id = targetSegmentID {
                        self.maybeScheduleParakeetPreview(
                            for: id,
                            voiceToText: voiceToText
                        )
                    }
                } catch {
                    Logger.log(
                        "mic fragment: error segment=\(targetSegmentID?.uuidString ?? "nil"): \(error)",
                        log: Logger.general,
                        type: .error
                    )
                }
            }
        )
        latestMicFragmentSequence = max(latestMicFragmentSequence, sequence)
        if let segmentID {
            micChunkEventsBySegment[segmentID, default: []].append(
                MicChunkEvent(
                    sequence: sequence,
                    startTime: startTime,
                    sampleCount: samples.count,
                    chunkKind: chunkKind
                )
            )
        }
        Logger.log(
            "mic fragment: enqueued seq=\(sequence) segment=\(segmentID?.uuidString ?? "nil") samples=\(samples.count) start=\(String(format: "%.2f", startTime))s",
            log: Logger.general
        )
        return sequence
    }

    private func flushPendingMicFragmentBuffer(for segmentID: UUID? = nil) async -> Int? {
        guard !micFragmentBuffer.isEmpty else { return nil }
        guard let targetSegmentID = segmentID ?? pendingMicSegmentId else {
            Logger.log("mic fragment: dropping buffered mic audio without active segment", log: Logger.general)
            micFragmentBuffer = []
            micFragmentStartTime = 0
            return nil
        }

        let fragment = micFragmentBuffer
        let fragmentStart = micFragmentStartTime
        micFragmentBuffer = []
        micFragmentStartTime = 0

        return await enqueueMicFragment(
            fragment,
            startTime: fragmentStart,
            segmentID: targetSegmentID,
            chunkKind: .flush
        )
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
            if shouldDumpParakeetDebugAudio(),
               voiceToText is ParakeetVoiceToTextModel {
                _ = dumpParakeetDebugAudio(
                    samples: buffer.samples,
                    channel: "system",
                    segmentID: pendingSegment.id,
                    startTime: startTime
                )
            }
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

    private enum MicChunkKind: String, Codable {
        case regular
        case flush
    }

    private struct MicChunkEvent: Codable {
        let sequence: Int
        let startTime: TimeInterval
        let sampleCount: Int
        let chunkKind: MicChunkKind
    }

    private struct ParakeetMicDebugManifest: Codable {
        let segmentID: UUID
        let startTime: TimeInterval
        let sampleCount: Int
        let durationSeconds: Double
        let avgAbs: Float
        let maxAbs: Float
        let chunkEvents: [MicChunkEvent]
    }

    private func handleMicLevelUpdate(db: Float) async {
        guard let vad = micVAD else { return }
        guard let event = await vad.update(levelDB: db) else { return }

        switch event {
        case .startSpeech:
            ghostMicCleanupTask?.cancel()
            ghostMicCleanupTask = nil
            guard pendingMicSegmentId == nil else { return }

            let now = Date().timeIntervalSince(startTime ?? Date())
            let segment = createPendingSegment(speaker: .me, startTime: now)
            pendingMicSegmentId = segment.id
            beginMicUtterancePreRollIfNeeded(segmentID: segment.id)
            micSessionGeneration += 1
            let sessionGeneration = micSessionGeneration
            Task { [weak self] in
                guard let self = self, let voiceToText = self.voiceToText else { return }
                guard self.micSessionGeneration == sessionGeneration else { return }
                try? await voiceToText.startStreamingSession(source: .microphone)
            }
            Logger.log(
                "VAD mic: created pending segment \(segment.id) at \(String(format: "%.2f", now))s generation=\(sessionGeneration)",
                log: Logger.general
            )
        case .endSpeech:
            let endingSegmentID = pendingMicSegmentId
            let endingSessionGeneration = micSessionGeneration
            let targetSequenceBeforeFlush = latestMicFragmentSequence
            pendingMicSegmentId = nil

            guard let endingSegmentID else { return }

            Logger.log(
                "VAD mic: speech ended segment=\(endingSegmentID.uuidString) generation=\(endingSessionGeneration) targetSequenceBeforeFlush=\(targetSequenceBeforeFlush)",
                log: Logger.general
            )

            let finalizeTask = Task { [weak self] in
                guard let self = self else { return }
                let flushedSequence = await self.flushPendingMicFragmentBuffer(for: endingSegmentID)
                let targetSequence = max(
                    targetSequenceBeforeFlush,
                    self.latestMicFragmentSequence,
                    flushedSequence ?? 0
                )
                let finalUtteranceSamples = self.micUtteranceSamplesBySegment[endingSegmentID] ?? []
                let segmentStartTime = MeetingSession.shared.liveTranscript
                    .first(where: { $0.id == endingSegmentID })?
                    .startTime ?? 0
                if self.shouldDumpParakeetDebugAudio(),
                   self.voiceToText is ParakeetVoiceToTextModel {
                    let audioURL = self.dumpParakeetDebugAudio(
                        samples: finalUtteranceSamples,
                        channel: "mic",
                        segmentID: endingSegmentID,
                        startTime: segmentStartTime
                    )
                    self.dumpParakeetMicDebugManifest(
                        segmentID: endingSegmentID,
                        startTime: segmentStartTime,
                        samples: finalUtteranceSamples,
                        chunkEvents: self.micChunkEventsBySegment[endingSegmentID] ?? [],
                        matchingAudioURL: audioURL
                    )
                }
                Logger.log(
                    "VAD mic: waiting for segment \(endingSegmentID.uuidString) through sequence \(targetSequence)",
                    log: Logger.general
                )
                await self.transcriptionQueue.waitUntilProcessed(source: .microphone, upTo: targetSequence)
                if let voiceToText = self.voiceToText {
                    do {
                        let finalizedStreamingText = try await voiceToText.finalizeStreamingText(
                            samples: finalUtteranceSamples,
                            source: .microphone
                        )?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let finalizedStreamingText, !finalizedStreamingText.isEmpty {
                            let currentBest = self.micBestStreamingTextBySegment[endingSegmentID] ?? ""
                            let preferredBest = self.preferredFinalStreamingText(
                                currentText: currentBest,
                                candidateText: finalizedStreamingText
                            )
                            if preferredBest != currentBest {
                                self.micBestStreamingTextBySegment[endingSegmentID] = preferredBest
                                Logger.log(
                                    "VAD mic: captured final streaming text for segment \(endingSegmentID.uuidString) chars=\(preferredBest.count)",
                                    log: Logger.general
                                )
                            }
                        } else if voiceToText is ParakeetVoiceToTextModel {
                            await self.runParakeetMicEmptyStreamingDiagnostics(
                                samples: finalUtteranceSamples,
                                segmentID: endingSegmentID,
                                startTime: segmentStartTime
                            )
                        }
                    } catch {
                        Logger.log(
                            "VAD mic: final streaming decode failed for segment \(endingSegmentID.uuidString): \(error)",
                            log: Logger.general,
                            type: .error
                        )
                    }
                }
                await MainActor.run {
                    MeetingSession.shared.markSegmentAwaitingFinalPartial(id: endingSegmentID, isAwaiting: true)
                }
                try? await Task.sleep(nanoseconds: self.micFinalPartialGraceNanoseconds)
                Logger.log(
                    "VAD mic: finished waiting for segment \(endingSegmentID.uuidString) through sequence \(targetSequence)",
                    log: Logger.general
                )
                await MainActor.run {
                    self.finalizePendingMicSegmentIfNeeded(
                        id: endingSegmentID,
                        reason: "after speech end",
                        allowDeferredRemoval: true
                    )
                }
                if self.micSessionGeneration == endingSessionGeneration,
                   let voiceToText = self.voiceToText {
                    try? await voiceToText.stopStreamingSession(source: .microphone)
                }
                await MainActor.run {
                    self.micFinalizeTasks[endingSegmentID] = nil
                }
            }
            micFinalizeTasks[endingSegmentID] = finalizeTask
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

    private func scheduleLateMicSegmentCleanup(id: UUID, reason: String) {
        micLateCleanupTasks[id]?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: self.micLatePartialRetentionNanoseconds)
            guard !Task.isCancelled else { return }
            self.micLateCleanupTasks[id] = nil
            self.finalizePendingMicSegmentIfNeeded(
                id: id,
                reason: reason,
                allowDeferredRemoval: false
            )
        }
        micLateCleanupTasks[id] = task
    }

    private func finalizePendingMicSegmentIfNeeded(
        id: UUID?,
        reason: String,
        allowDeferredRemoval: Bool = true
    ) {
        guard let id else { return }
        if pendingMicSegmentId == id {
            pendingMicSegmentId = nil
        }

        guard let segment = MeetingSession.shared.liveTranscript.first(where: { $0.id == id }) else {
            micPreviewTasks[id]?.cancel()
            micPreviewTasks[id] = nil
            micBestStreamingTextBySegment[id] = nil
            micUtteranceSamplesBySegment[id] = nil
            micChunkEventsBySegment[id] = nil
            micLastPreviewSampleCountBySegment[id] = nil
            return
        }

        let bestStreamingText = micBestStreamingTextBySegment[id] ?? ""
        let preferredText = preferredFinalStreamingText(
            currentText: segment.text,
            candidateText: bestStreamingText
        )
        if preferredText != segment.text {
            segment.text = preferredText
        }

        let normalizedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedText.isEmpty {
            if allowDeferredRemoval {
                segment.isAwaitingFinalPartial = true
                Logger.log("VAD mic: deferring empty pending segment \(id) \(reason)", log: Logger.general)
                scheduleLateMicSegmentCleanup(id: id, reason: "after late partial grace")
                return
            }

            micLateCleanupTasks[id]?.cancel()
            micLateCleanupTasks[id] = nil
            micPreviewTasks[id]?.cancel()
            micPreviewTasks[id] = nil
            micBestStreamingTextBySegment[id] = nil
            micUtteranceSamplesBySegment[id] = nil
            micChunkEventsBySegment[id] = nil
            micLastPreviewSampleCountBySegment[id] = nil
            segment.isAwaitingFinalPartial = false
            Logger.log("VAD mic: removing empty pending segment \(id) \(reason)", log: Logger.general)
            MeetingSession.shared.removeSegment(id: id)
            return
        }

        micLateCleanupTasks[id]?.cancel()
        micLateCleanupTasks[id] = nil
        micPreviewTasks[id]?.cancel()
        micPreviewTasks[id] = nil
        micBestStreamingTextBySegment[id] = nil
        micUtteranceSamplesBySegment[id] = nil
        micChunkEventsBySegment[id] = nil
        micLastPreviewSampleCountBySegment[id] = nil
        segment.confidence = 0.95
        segment.isAwaitingFinalPartial = false
        MeetingSession.shared.finalizeSegment(
            id: id,
            text: normalizedText,
            speaker: .me
        )
        Logger.log("VAD mic: finalized pending segment \(id) \(reason)", log: Logger.general)
    }

    private func handleParakeetEOU(source: AudioSource) {
        switch source {
        case .microphone:
            finalizePendingMicSegmentIfNeeded(
                id: pendingMicSegmentId,
                reason: "after EOU",
                allowDeferredRemoval: true
            )
        case .system:
            startGhostCleanupTask(channel: .system)
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
        case .lcpCommitted:
            Logger.log("processAudioChunk: \(sourceName) promoted stable LCP text", log: Logger.general)
        case .sessionStarted:
            Logger.log("processAudioChunk: \(sourceName) streaming session started", log: Logger.general)
        case .sessionStopped:
            Logger.log("processAudioChunk: \(sourceName) streaming session stopped", log: Logger.general)
        case .finished:
            Logger.log("processAudioChunk: \(sourceName) decoder finished", log: Logger.general)
        }
    }

    private func preferredFinalStreamingText(currentText: String, candidateText: String) -> String {
        let normalizedCurrent = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCandidate = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedCandidate.isEmpty else { return currentText }
        guard !normalizedCurrent.isEmpty else { return normalizedCandidate }

        if normalizedCandidate.hasPrefix(normalizedCurrent) {
            return normalizedCandidate
        }

        if normalizedCurrent.hasPrefix(normalizedCandidate) {
            return currentText
        }

        if normalizedCandidate.count > normalizedCurrent.count {
            return normalizedCandidate
        }

        return currentText
    }

    private func preferredLivePreviewText(
        currentText: String,
        candidateText: String,
        isAwaitingFinalPartial: Bool
    ) -> String {
        let normalizedCurrent = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCandidate = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedCandidate.isEmpty else { return normalizedCurrent }
        guard !normalizedCurrent.isEmpty else { return normalizedCandidate }

        if normalizedCandidate.hasPrefix(normalizedCurrent) {
            return collapseLeadingPreviewDuplication(
                currentText: normalizedCurrent,
                candidateText: normalizedCandidate
            )
        }

        if normalizedCurrent.hasPrefix(normalizedCandidate) {
            return normalizedCurrent
        }

        if isAwaitingFinalPartial {
            let preferredFinalText = preferredFinalStreamingText(
                currentText: normalizedCurrent,
                candidateText: normalizedCandidate
            )
            return preferredFinalText == normalizedCurrent ? normalizedCurrent : normalizedCandidate
        }

        return normalizedCandidate.count >= normalizedCurrent.count ? normalizedCandidate : normalizedCurrent
    }

    private func collapseLeadingPreviewDuplication(currentText: String, candidateText: String) -> String {
        guard currentText.count >= 8 else { return candidateText }

        let trimmedCandidate = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCandidate.hasPrefix(currentText) else { return trimmedCandidate }

        var suffixStart = trimmedCandidate.index(trimmedCandidate.startIndex, offsetBy: currentText.count)
        while suffixStart < trimmedCandidate.endIndex,
              trimmedCandidate[suffixStart].isWhitespace || trimmedCandidate[suffixStart].isPunctuation {
            suffixStart = trimmedCandidate.index(after: suffixStart)
        }

        let suffix = String(trimmedCandidate[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { return trimmedCandidate }

        if suffix.hasPrefix(currentText) {
            return currentText
        }

        let currentWords = currentText.split(separator: " ")
        guard currentWords.count >= 3 else { return trimmedCandidate }

        let repeatedPrefix = currentWords.prefix(max(2, currentWords.count / 2)).joined(separator: " ")
        if suffix.hasPrefix(repeatedPrefix) {
            return currentText
        }

        return trimmedCandidate
    }

    private func shouldDumpParakeetDebugAudio() -> Bool {
        ProcessInfo.processInfo.environment["PARAKEET_DEBUG_AUDIO_DUMP"] == "1"
    }

    @discardableResult
    private func dumpParakeetDebugAudio(
        samples: [Float],
        channel: String,
        segmentID: UUID,
        startTime: TimeInterval
    ) -> URL? {
        guard !samples.isEmpty else { return nil }

        let diagnosticsDirectory = GenericHelper.getAppSupportDirectory()
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Parakeet", isDirectory: true)

        do {
            try GenericHelper.folderCreate(folder: diagnosticsDirectory)
            let sanitizedStartTime = String(format: "%.2f", startTime).replacingOccurrences(of: ".", with: "_")
            let fileURL = diagnosticsDirectory
                .appendingPathComponent("\(channel)_\(sanitizedStartTime)_\(segmentID.uuidString).wav")
            try writeWAVFile(samples: samples, to: fileURL)

            if GenericHelper.logSensitiveData() {
                Logger.log("Parakeet debug audio dumped to \(fileURL.path)", log: Logger.audio)
            } else {
                Logger.log(
                    "Parakeet debug audio dumped for \(channel) segment \(segmentID.uuidString)",
                    log: Logger.audio,
                    type: .debug
                )
            }
            return fileURL
        } catch {
            Logger.log(
                "Failed to dump Parakeet debug audio for \(channel) segment \(segmentID.uuidString): \(error)",
                log: Logger.audio,
                type: .error
            )
            return nil
        }
    }

    private func dumpParakeetMicDebugManifest(
        segmentID: UUID,
        startTime: TimeInterval,
        samples: [Float],
        chunkEvents: [MicChunkEvent],
        matchingAudioURL: URL?
    ) {
        let diagnostics = audioDiagnostics(for: samples)
        let manifest = ParakeetMicDebugManifest(
            segmentID: segmentID,
            startTime: startTime,
            sampleCount: diagnostics.sampleCount,
            durationSeconds: diagnostics.durationSeconds,
            avgAbs: diagnostics.avgAbs,
            maxAbs: diagnostics.maxAbs,
            chunkEvents: chunkEvents
        )

        let diagnosticsDirectory = GenericHelper.getAppSupportDirectory()
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Parakeet", isDirectory: true)

        do {
            try GenericHelper.folderCreate(folder: diagnosticsDirectory)
            let sanitizedStartTime = String(format: "%.2f", startTime).replacingOccurrences(of: ".", with: "_")
            let manifestURL = diagnosticsDirectory
                .appendingPathComponent("mic_manifest_\(sanitizedStartTime)_\(segmentID.uuidString).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)

            if GenericHelper.logSensitiveData(), let matchingAudioURL {
                Logger.log(
                    "Parakeet mic debug manifest dumped to \(manifestURL.path) for audio \(matchingAudioURL.lastPathComponent)",
                    log: Logger.audio
                )
            } else {
                Logger.log(
                    "Parakeet mic debug manifest dumped for segment \(segmentID.uuidString)",
                    log: Logger.audio,
                    type: .debug
                )
            }
        } catch {
            Logger.log(
                "Failed to dump Parakeet mic debug manifest for segment \(segmentID.uuidString): \(error)",
                log: Logger.audio,
                type: .error
            )
        }
    }

    private func maybeScheduleParakeetPreview(
        for segmentID: UUID,
        voiceToText: VoiceToTextProtocol
    ) {
        guard let parakeet = voiceToText as? ParakeetVoiceToTextModel else { return }
        guard pendingMicSegmentId == segmentID else { return }
        guard micPreviewTasks[segmentID] == nil else { return }

        let currentBest = micBestStreamingTextBySegment[segmentID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard currentBest.isEmpty else { return }

        guard let segment = MeetingSession.shared.liveTranscript.first(where: { $0.id == segmentID }),
              segment.isPending else {
            return
        }

        let samples = micUtteranceSamplesBySegment[segmentID] ?? []
        guard samples.count >= parakeetPreviewInitialSamples else { return }

        let lastPreviewSampleCount = micLastPreviewSampleCountBySegment[segmentID] ?? 0
        guard samples.count >= lastPreviewSampleCount + parakeetPreviewAdditionalSamples else { return }

        micLastPreviewSampleCountBySegment[segmentID] = samples.count
        let previewSamples = samples
        let task = Task { [weak self] in
            guard let self = self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.micPreviewTasks[segmentID] = nil
                }
            }

            do {
                let previewText = try await parakeet.transcribeSamplesForPreview(previewSamples)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !previewText.isEmpty else { return }

                await MainActor.run {
                    guard self.pendingMicSegmentId == segmentID,
                          let segment = MeetingSession.shared.liveTranscript.first(where: { $0.id == segmentID }),
                          segment.isPending else {
                        return
                    }

                    let mergedPreview = self.preferredLivePreviewText(
                        currentText: segment.text,
                        candidateText: previewText,
                        isAwaitingFinalPartial: segment.isAwaitingFinalPartial
                    )
                    if mergedPreview != segment.text {
                        segment.text = mergedPreview
                        Logger.log(
                            "mic fragment: speculative preview segment=\(segmentID.uuidString) chars=\(mergedPreview.count)",
                            log: Logger.general,
                            type: .debug
                        )
                    }
                }
            } catch {
                Logger.log(
                    "mic fragment: speculative preview failed segment=\(segmentID.uuidString): \(error)",
                    log: Logger.general,
                    type: .debug
                )
            }
        }
        micPreviewTasks[segmentID] = task
    }

    private func runParakeetMicEmptyStreamingDiagnostics(
        samples: [Float],
        segmentID: UUID,
        startTime: TimeInterval
    ) async {
        let diagnostics = audioDiagnostics(for: samples)
        Logger.log(
            "Parakeet mic diagnostic: empty streaming result segment=\(segmentID.uuidString) samples=\(diagnostics.sampleCount) duration=\(String(format: "%.2f", diagnostics.durationSeconds))s avgAbs=\(String(format: "%.4f", diagnostics.avgAbs)) maxAbs=\(String(format: "%.4f", diagnostics.maxAbs))",
            log: Logger.general,
            type: .debug
        )

        guard !samples.isEmpty else { return }

        let audioURL: URL
        let shouldDeleteAudioURL: Bool
        if let dumpedURL = shouldDumpParakeetDebugAudio()
            ? dumpParakeetDebugAudio(
                samples: samples,
                channel: "mic_diag",
                segmentID: segmentID,
                startTime: startTime
            )
            : nil {
            audioURL = dumpedURL
            shouldDeleteAudioURL = false
        } else {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("parakeet_mic_diag_\(segmentID.uuidString).wav")
            do {
                try writeWAVFile(samples: samples, to: tempURL)
            } catch {
                Logger.log(
                    "Parakeet mic diagnostic: failed to write temp audio for segment \(segmentID.uuidString): \(error)",
                    log: Logger.general,
                    type: .error
                )
                return
            }
            audioURL = tempURL
            shouldDeleteAudioURL = true
        }

        defer {
            if shouldDeleteAudioURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        do {
            let manager = try await LocalParakeet.loadModel()
            let offlineResult = try await manager.transcribe(audioURL)
            let offlineText = offlineResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            Logger.log(
                "Parakeet mic diagnostic: streaming chars=0 offline chars=\(offlineText.count) segment=\(segmentID.uuidString)",
                log: Logger.general,
                type: .debug
            )
            if GenericHelper.logSensitiveData(), !offlineText.isEmpty {
                Logger.log(
                    "Parakeet mic diagnostic offline transcript: '\(offlineText)'",
                    log: Logger.general,
                    type: .debug
                )
            }
        } catch {
            Logger.log(
                "Parakeet mic diagnostic: offline fallback failed for segment \(segmentID.uuidString): \(error)",
                log: Logger.general,
                type: .error
            )
        }
    }

    private func audioDiagnostics(for samples: [Float]) -> (
        sampleCount: Int,
        durationSeconds: Double,
        avgAbs: Float,
        maxAbs: Float
    ) {
        guard !samples.isEmpty else {
            return (0, 0, 0, 0)
        }

        var sumAbs: Float = 0
        var maxAbs: Float = 0
        for sample in samples {
            let absSample = abs(sample)
            sumAbs += absSample
            if absSample > maxAbs {
                maxAbs = absSample
            }
        }

        return (
            sampleCount: samples.count,
            durationSeconds: Double(samples.count) / Double(sampleRate),
            avgAbs: sumAbs / Float(samples.count),
            maxAbs: maxAbs
        )
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
