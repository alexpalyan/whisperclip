import Foundation
import Accelerate

enum VADEvent: Equatable {
    case startSpeech
    case endSpeech
}

/// Pure-logic voice activity detector driven by RMS level updates.
actor VADStateMachine {
    let thresholdDB: Float
    let onsetDuration: Duration
    let offsetDuration: Duration

    private var isActive = false
    private var onsetStart: ContinuousClock.Instant?
    private var offsetStart: ContinuousClock.Instant?

    init(
        thresholdDB: Float = -45,
        onsetDuration: Duration = .milliseconds(200),
        offsetDuration: Duration = .milliseconds(500)
    ) {
        self.thresholdDB = thresholdDB
        self.onsetDuration = onsetDuration
        self.offsetDuration = offsetDuration
    }

    func update(levelDB: Float) -> VADEvent? {
        let now = ContinuousClock.now

        if levelDB > thresholdDB {
            offsetStart = nil

            guard !isActive else {
                return nil
            }

            if let start = onsetStart {
                if now - start >= onsetDuration {
                    isActive = true
                    onsetStart = nil
                    Logger.log(
                        "VADStateMachine: speech started (level \(String(format: "%.1f", levelDB))dB)",
                        log: Logger.general
                    )
                    return .startSpeech
                }
            } else {
                onsetStart = now
            }

            return nil
        }

        onsetStart = nil

        guard isActive else {
            return nil
        }

        if let start = offsetStart {
            if now - start >= offsetDuration {
                isActive = false
                offsetStart = nil
                Logger.log(
                    "VADStateMachine: speech ended (level \(String(format: "%.1f", levelDB))dB)",
                    log: Logger.general
                )
                return .endSpeech
            }
        } else {
            offsetStart = now
        }

        return nil
    }

    nonisolated static func rmsDB(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -160 }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return 20 * log10(max(rms, 1e-7))
    }
}
