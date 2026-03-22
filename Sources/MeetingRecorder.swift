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
    
    // MARK: - Audio Components

    private var dualCapture: DualChannelAudioCapture?
    private var asrManager: AsrManager?
    private var diarizerManager: DiarizerManager?
    private var speakerBufferManager: SpeakerBufferManager?

    // MARK: - State

    private var startTime: Date?
    private var durationTimer: Timer?
    private var transcriptCallback: MeetingTranscriptCallback?
    private var errorCallback: MeetingErrorCallback?

    // Text deduplication per speaker
    private var processedMicTexts: Set<String> = []
    private var processedSystemTexts: Set<String> = []

    // Maps raw diarizer speakerIds (e.g. "SPEAKER_00") to display labels (e.g. "Speaker 1")
    private var speakerLabelMap: [String: String] = [:]
    private var nextSpeakerNumber: Int = 1
    
    // Transcription queue to prevent concurrent CoreML predictions
    private let transcriptionQueue = TranscriptionQueue()
    
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
        
        // Initialize ASR manager
        do {
            asrManager = try await LocalParakeet.loadModel()
        } catch {
            Logger.log("Failed to load ASR model: \(error)", log: Logger.general, type: .error)
            throw MeetingRecorderError.modelLoadFailed(error.localizedDescription)
        }

        // Initialize diarizer (optional — falls back to channel-based attribution if unavailable)
        if ModelStorage.shared.diarizerModelsExist() {
            do {
                let diarizerModels = try await DiarizerModels.load()
                // clusteringThreshold=0.3 → speakerThreshold=0.36 (lower than 0.4→0.48 which still
                // collapsed all speakers into one — logs showed single "Created new speaker 1" with
                // no second speaker ever created across an entire multi-person meeting).
                // DiarizerConfig.default uses 0.7 → speakerThreshold=0.84, way too permissive.
                let diarizer = DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.3))
                diarizer.initialize(models: diarizerModels)
                diarizerManager = diarizer
                Logger.log("DiarizerManager initialized successfully", log: Logger.general)
            } catch {
                Logger.log("Failed to load diarizer models (will use channel-based speaker attribution): \(error)", log: Logger.general, type: .error)
                diarizerManager = nil
            }
        } else {
            Logger.log("Diarizer models not downloaded — using channel-based speaker attribution", log: Logger.general)
            diarizerManager = nil
        }

        // Create SpeakerBufferManager if diarizer is available
        if let diarizer = diarizerManager {
            let manager = SpeakerBufferManager(diarizer: diarizer, sampleRate: sampleRate)
            speakerBufferManager = manager
            await manager.start()
            Logger.log("SpeakerBufferManager started", log: Logger.general)
        }
        
        // Create dual channel capture
        dualCapture = DualChannelAudioCapture()
        
        guard let capture = dualCapture else {
            throw MeetingRecorderError.recordingFailed
        }
        
        // Start dual channel capture
        do {
            try await capture.startCapture(
                onAudioChunk: { [weak self] source, samples, startTime in
                    guard let self = self else { return }
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
                        await self.speakerBufferManager?.onAudioBatch(samples, atTime: time)
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
        segmentCount = 0
        lastError = nil
        processedMicTexts = []
        processedSystemTexts = []
        speakerLabelMap = [:]
        nextSpeakerNumber = 1
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
        
        // Stop SpeakerBufferManager (flushes remaining system audio buffers)
        if let manager = speakerBufferManager {
            await manager.stop()
            Logger.log("SpeakerBufferManager stopped", log: Logger.general)
        }

        // Stop dual capture and retrieve remaining mic audio
        var finalMicAudio: (samples: [Float], startTime: TimeInterval)?
        if let capture = dualCapture {
            finalMicAudio = await capture.stopCapture()
        }
        
        // Wait for any previously queued transcription work to finish
        await transcriptionQueue.drain()
        
        // Process final mic chunk directly (system audio already handled by SpeakerBufferManager)
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
        transcriptCallback = nil
        errorCallback = nil
        processedMicTexts = []
        processedSystemTexts = []
        asrManager = nil
        diarizerManager = nil
        dualCapture = nil
        speakerBufferManager = nil
        speakerLabelMap = [:]
        nextSpeakerNumber = 1
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
    
    private func processAudioChunk(source: AudioSource, samples: [Float], startTime: TimeInterval, isFinal: Bool = false) async {
        guard let asrManager = asrManager else {
            Logger.log("processAudioChunk: asrManager not available", log: Logger.general, type: .error)
            return
        }

        guard isFinal || samples.count >= sampleRate * 2 else {
            Logger.log("processAudioChunk: not enough samples (\(samples.count))", log: Logger.general)
            return
        }

        let sourceName = source == .microphone ? "mic" : "system"

        Logger.log("processAudioChunk: processing \(sourceName) chunk with \(samples.count) samples", log: Logger.general)

        // Create temp WAV file for transcription
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting_\(sourceName)_\(UUID().uuidString).wav")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            // Write samples to WAV file
            try writeWAVFile(samples: samples, to: tempURL)

            // Transcribe
            let transcriptionResult = try await asrManager.transcribe(tempURL)

            guard !transcriptionResult.text.isEmpty else {
                Logger.log("processAudioChunk: empty transcription from \(sourceName)", log: Logger.general)
                return
            }

            // Clean and deduplicate based on source
            let normalizedText = transcriptionResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let newText = extractNewText(normalizedText, for: source)

            guard !newText.isEmpty else {
                Logger.log("processAudioChunk: no new text after deduplication from \(sourceName)", log: Logger.general)
                return
            }

            // Determine speaker via diarization (if available) or fall back to channel attribution
            let chunkDuration = Double(samples.count) / Double(sampleRate)
            let endTime = startTime + chunkDuration
            let speaker = resolveSpeaker(source: source, samples: samples, chunkStartTime: startTime)

            // Create segment
            let segment = MeetingSegment(
                speaker: speaker,
                text: newText,
                startTime: startTime,
                endTime: endTime,
                confidence: 0.95
            )

            segmentCount += 1

            // Store for deduplication
            if source == .microphone {
                processedMicTexts.insert(newText)
            } else {
                processedSystemTexts.insert(newText)
            }

            Logger.log("processAudioChunk: created \(speaker.displayName) segment #\(segmentCount): '\(newText.prefix(50))'", log: Logger.general)

            transcriptCallback?(segment)

        } catch {
            Logger.log("processAudioChunk: error processing \(sourceName): \(error)", log: Logger.general, type: .error)
            lastError = error.localizedDescription
        }
    }

    /// Determines the `Speaker` for a chunk of audio.
    ///
    /// Microphone audio always returns `.me` — the local user's identity is known
    /// from the capture channel and must not be overridden by diarization labels.
    ///
    /// For system audio, when `DiarizerManager` is available it runs diarization on
    /// the raw samples and picks the speaker with the most speech time in the chunk,
    /// mapping each unique speakerId to a stable human-readable label ("Speaker 1",
    /// "Speaker 2", …) that persists for the entire recording session.
    ///
    /// Falls back to channel-based attribution if the diarizer is unavailable or
    /// returns no segments.
    private func resolveSpeaker(source: AudioSource, samples: [Float], chunkStartTime: TimeInterval) -> Speaker {
        // Microphone is always "Me" — never override with a diarization label.
        if source == .microphone {
            return .me
        }

        Logger.log("resolveSpeaker: called for system audio chunk, \(samples.count) samples at t=\(String(format: "%.2f", chunkStartTime))s, diarizerManager=\(diarizerManager != nil ? "available" : "nil")", log: Logger.general)

        guard let diarizer = diarizerManager else {
            Logger.log("resolveSpeaker: no diarizerManager, falling back to channel attribution", log: Logger.general)
            return source.speaker
        }

        do {
            let result = try diarizer.performCompleteDiarization(samples, sampleRate: sampleRate, atTime: chunkStartTime)

            Logger.log("resolveSpeaker: diarization returned \(result.segments.count) segments", log: Logger.general)

            guard !result.segments.isEmpty else {
                Logger.log("resolveSpeaker: diarization returned no segments for system audio, falling back to channel attribution", log: Logger.general)
                return source.speaker
            }

            // Log all segments for diagnosis
            for seg in result.segments {
                Logger.log("resolveSpeaker: segment speakerId='\(seg.speakerId)' duration=\(String(format: "%.2f", seg.durationSeconds))s [\(String(format: "%.2f", seg.startTimeSeconds))s–\(String(format: "%.2f", seg.endTimeSeconds))s]", log: Logger.general)
            }

            // Pick the speakerId with the most total speech time in this chunk.
            // Note: speakerIds (e.g. "SPEAKER_00") are stable within a single
            // performCompleteDiarization call but not guaranteed across calls.
            // We accumulate the map so that if the same raw ID recurs across chunks
            // it receives a consistent label. In practice this works because
            // FluidAudio's SpeakerManager tracks embeddings across calls when using
            // the same DiarizerManager instance.
            var durationBySpeaker: [String: Float] = [:]
            for seg in result.segments {
                durationBySpeaker[seg.speakerId, default: 0] += seg.durationSeconds
            }

            Logger.log("resolveSpeaker: duration by speakerId: \(durationBySpeaker.map { "\($0.key)=\(String(format: "%.2f", $0.value))s" }.sorted().joined(separator: ", "))", log: Logger.general)

            guard let dominantId = durationBySpeaker.max(by: { $0.value < $1.value })?.key,
                  !dominantId.isEmpty else {
                Logger.log("resolveSpeaker: no dominant speaker found, falling back to channel attribution", log: Logger.general)
                return source.speaker
            }

            // Map to stable display label
            if let label = speakerLabelMap[dominantId] {
                Logger.log("resolveSpeaker: dominantId='\(dominantId)' → existing label '\(label)' (labelMap=\(speakerLabelMap))", log: Logger.general)
                return .labeled(label)
            } else {
                let label = "Speaker \(nextSpeakerNumber)"
                speakerLabelMap[dominantId] = label
                nextSpeakerNumber += 1
                Logger.log("resolveSpeaker: new system-audio speaker '\(dominantId)' assigned label '\(label)' (labelMap now: \(speakerLabelMap))", log: Logger.general)
                return .labeled(label)
            }
        } catch {
            Logger.log("resolveSpeaker: diarization failed (\(error)), falling back to channel attribution", log: Logger.general, type: .error)
            return source.speaker
        }
    }
    
    /// Extract text that hasn't been seen before for this source
    private func extractNewText(_ fullText: String, for source: AudioSource) -> String {
        let processedTexts = source == .microphone ? processedMicTexts : processedSystemTexts
        
        // If this exact text was already processed, skip
        if processedTexts.contains(fullText) {
            return ""
        }
        
        // Check if fullText contains any previously processed text as prefix
        for processed in processedTexts {
            if fullText.hasPrefix(processed) {
                // Return only the new part
                let newPart = String(fullText.dropFirst(processed.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !newPart.isEmpty && !processedTexts.contains(newPart) {
                    return newPart
                }
            }
        }
        
        return fullText
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
