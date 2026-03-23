import SwiftUI

/// High-performance waveform using TimelineView to guarantee redraws
/// even when the main thread is heavily loaded by AI models.
struct MeetingWaveformView: View {
    @ObservedObject var recorder: MeetingRecorder

    private struct WaveformPoint {
        let level: Float
        let label: String
    }

    private let maxSamples = 120
    @State private var points: [WaveformPoint] = Array(repeating: WaveformPoint(level: 0, label: ""), count: 120)

    var body: some View {
        // TimelineView forces updates at a consistent frequency (10Hz)
        TimelineView(.animation(minimumInterval: 0.1)) { timeline in
            Canvas { context, size in
                let spacing: CGFloat = 2
                let barWidth = (size.width - CGFloat(maxSamples - 1) * spacing) / CGFloat(maxSamples)

                for i in 0..<maxSamples {
                    let point = points[i]
                    let x = CGFloat(i) * (barWidth + spacing)
                    
                    let normalized = CGFloat(sqrt(point.level))
                    let height = max(4, min(size.height, normalized * size.height * 1.5))
                    
                    let color: Color
                    if point.level > 0.005 {
                        if point.label == "Me" {
                            color = .blue
                        } else if point.label.isEmpty {
                            color = .blue.opacity(0.6)
                        } else {
                            color = speakerPaletteColor(Speaker(displayName: point.label))
                        }
                    } else {
                        color = Color.gray.opacity(0.2)
                    }

                    let y = (size.height - height) / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                    context.fill(RoundedRectangle(cornerRadius: 1).path(in: rect), with: .color(color))
                }
            }
            .onChange(of: timeline.date) { _, _ in
                // We update the buffer every time the timeline "ticks"
                if recorder.isRecording {
                    updateBuffer()
                }
            }
        }
        .onChange(of: recorder.isRecording) { _, isRecording in
            if isRecording {
                points = Array(repeating: WaveformPoint(level: 0, label: ""), count: maxSamples)
            }
        }
    }

    private func updateBuffer() {
        let newPoint = WaveformPoint(
            level: recorder.normalizedLevel,
            label: recorder.activeSpeakerLabel
        )
        
        var nextPoints = points
        nextPoints.append(newPoint)
        if nextPoints.count > maxSamples {
            nextPoints.removeFirst()
        }
        points = nextPoints
    }
}

/// Simple circular audio level indicator
struct AudioLevelIndicator: View {
    let level: Float
    let isActive: Bool

    @State private var pulseAnimation = false

    var body: some View {
        ZStack {
            if isActive {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(Color.teal.opacity(0.3 - Double(i) * 0.1), lineWidth: 2)
                        .frame(width: 80 + CGFloat(i) * 20, height: 80 + CGFloat(i) * 20)
                        .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                        .opacity(pulseAnimation ? 0.0 : 0.6)
                        .animation(
                            .easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.3),
                            value: pulseAnimation
                        )
                }
            }

            Circle()
                .fill(Color.teal.opacity(0.1))
                .frame(width: 70, height: 70)

            Circle()
                .fill(
                    LinearGradient(
                        colors: levelColors,
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .frame(width: 60 * CGFloat(max(0.2, level)), height: 60 * CGFloat(max(0.2, level)))
                .animation(.easeOut(duration: 0.1), value: level)

            Image(systemName: isActive ? "waveform" : "mic.fill")
                .font(.system(size: isActive ? 24 : 20, weight: .semibold))
                .foregroundColor(.white)
                .animation(.easeInOut, value: isActive)
        }
        .onAppear {
            if isActive {
                pulseAnimation = true
            }
        }
        .onChange(of: isActive) { _, newValue in
            pulseAnimation = newValue
        }
    }

    private var levelColors: [Color] {
        if level > 0.7 {
            return [.red, .orange]
        } else if level > 0.4 {
            return [.orange, .yellow]
        } else {
            return [.teal, .cyan]
        }
    }
}

/// Meeting status indicator badge
struct MeetingStatusBadge: View {
    let status: MeetingSession.SessionStatus

    var body: some View {
        HStack(spacing: 6) {
            if status.isActive {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .modifier(PulseModifier(isAnimating: status == .recording))
            }

            Text(status.rawValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.15))
        .cornerRadius(8)
    }

    private var statusColor: Color {
        switch status {
        case .idle: return .gray
        case .starting: return .blue
        case .recording: return .red
        case .stopping: return .orange
        case .processing: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

/// Pulse animation modifier
struct PulseModifier: ViewModifier {
    let isAnimating: Bool
    @State private var scale: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: isAnimating) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        scale = 1.3
                    }
                } else {
                    withAnimation {
                        scale = 1.0
                    }
                }
            }
            .onAppear {
                if isAnimating {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        scale = 1.3
                    }
                }
            }
    }
}

/// Speaker indicator for live transcript
struct SpeakerBadge: View {
    let speaker: Speaker

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: speaker.icon)
                .font(.system(size: 10))
            Text(speaker.displayName)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(speakerColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(speakerColor.opacity(0.15))
        .cornerRadius(6)
    }

    private var speakerColor: Color {
        speakerPaletteColor(speaker)
    }
}

/// Meeting duration timer view
struct MeetingTimerView: View {
    let startTime: Date

    @State private var elapsedTime: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 12))
            Text(formattedTime)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
        }
        .foregroundColor(.white)
        .onReceive(timer) { _ in
            elapsedTime = Date().timeIntervalSince(startTime)
        }
        .onAppear {
            elapsedTime = Date().timeIntervalSince(startTime)
        }
    }

    private var formattedTime: String {
        let totalSeconds = Int(elapsedTime)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
