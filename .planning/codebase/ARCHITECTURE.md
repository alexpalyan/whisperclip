# Architecture

**Analysis Date:** 2025-01-24

## Pattern Overview

**Overall:** Model-View-Controller/Manager (MVC/M) with Service Orientation

**Key Characteristics:**
- **Protocol-Oriented Services:** Core functionalities like transcription and LLM processing are defined by protocols, allowing for multiple implementations (e.g., WhisperKit vs. Parakeet).
- **Centralized State Management:** Singleton Managers (ObservableObjects) handle the app's state and orchestration, which SwiftUI views observe.
- **Actor-based Concurrency:** Uses Swift Actors (e.g., `TranscriptionQueue` in `MeetingRecorder.swift`) to serialize heavy AI workloads and prevent race conditions or resource exhaustion.

## Layers

**View Layer:**
- Purpose: Handles UI rendering and user interaction.
- Location: `Sources/` (files ending in `View.swift`)
- Contains: SwiftUI Views, ViewBuilders, and Styles.
- Depends on: Manager Layer (`MeetingStorage`, `SettingsStore`, `AudioRecorder`).
- Used by: App entry point (`WhisperClip.swift`).

**Manager/Controller Layer:**
- Purpose: Orchestrates business logic and maintains application state.
- Location: `Sources/` (files ending in `Manager.swift`, `Recorder.swift`, `Store.swift`, `Storage.swift`, `History.swift`)
- Contains: `ObservableObject` classes, logic for recording sessions, hotkey handling, and persistence management.
- Depends on: Service Layer, Model Layer.
- Used by: View Layer.

**Service Layer:**
- Purpose: Provides specialized technical capabilities (AI, Audio Capture).
- Location: `Sources/` (files like `LocalWhisperKit.swift`, `LocalParakeet.swift`, `LocalLLM.swift`, `DualChannelAudioCapture.swift`)
- Contains: Implementations of `VoiceToTextProtocol`, `LLMProtocol`, and low-level audio capture logic.
- Depends on: External frameworks (WhisperKit, MLX, FluidAudio).
- Used by: Manager Layer.

**Model Layer:**
- Purpose: Defines data structures and business entities.
- Location: `Sources/MeetingModels.swift`, `Sources/Mode.swift`
- Contains: Codable structs and enums representing meetings, segments, speakers, and app states.
- Depends on: Foundation.
- Used by: All layers.

## Data Flow

**Meeting Recording Flow:**

1. `MeetingRecorder.startRecording()` is triggered by UI or Hotkey.
2. `DualChannelAudioCapture` starts streaming audio buffers from microphone and system audio.
3. Audio buffers are enqueued in `TranscriptionQueue` (Actor).
4. `LocalParakeet` (Service) transcribes audio chunks into `MeetingSegment` objects.
5. `MeetingRecorder` notifies `MeetingStorage` of new segments.
6. SwiftUI Views (`MeetingNotesView`, `MeetingWaveformView`) observe `MeetingStorage` or `MeetingRecorder` and update in real-time.

**State Management:**
- **Global Settings:** Handled by `SettingsStore.shared` using `UserDefaults`.
- **Meeting Data:** Managed by `MeetingStorage.shared` with in-memory array and `UserDefaults` persistence.
- **Transcription History:** Managed by `TranscriptionHistory.shared`.
- **UI State:** SwiftUI `@State`, `@StateObject`, and `@ObservedObject`.

## Key Abstractions

**VoiceToTextProtocol:**
- Purpose: Abstracts audio transcription engines.
- Examples: `Sources/VoiceToTextProtocol.swift`
- Pattern: Strategy Pattern implemented via `VoiceToTextFactory`.

**LLMProtocol:**
- Purpose: Abstracts Large Language Model processing for summaries and Q&A.
- Examples: `Sources/LLMProtocol.swift`
- Pattern: Strategy Pattern implemented via `LLMFactory`.

**DualChannelAudioCapture:**
- Purpose: Abstracts the complexity of capturing both local microphone and system output (using FluidAudio/ScreenCaptureKit).
- Examples: `Sources/DualChannelAudioCapture.swift`

## Entry Points

**Main App Entry:**
- Location: `Sources/WhisperClip.swift`
- Triggers: User launching the app.
- Responsibilities: Initializes the SwiftUI app lifecycle, sets up `AppDelegate`, and manages top-level navigation (Onboarding, Main View).

**App Delegate:**
- Location: `Sources/AppDelegate.swift`
- Triggers: App lifecycle events.
- Responsibilities: Manages the status bar menu, global signal handlers (SIGINT/SIGTERM), and window visibility.

## Error Handling

**Strategy:** Result-based error handling combined with `do-catch` blocks and `NotificationCenter` for UI-facing errors.

**Patterns:**
- **Custom Enums:** `MeetingRecorderError` in `Sources/MeetingRecorder.swift` for domain-specific errors.
- **Notification-based reporting:** `AudioRecorder` posts `.recordingError` notifications.
- **Published Errors:** Managers like `MeetingRecorder` publish `lastError` strings for UI display.

## Cross-Cutting Concerns

**Logging:** Custom `Logger` class in `Sources/Logger.swift` with OSLog integration and categories (audio, general, etc.).
**Validation:** `SecurityChecker.swift` handles permission validation for Mic, Accessibility, and Screen Recording.
**Authentication:** Not applicable (local-first app).
**Hotkeys:** `HotkeyManager.swift` manages global keyboard shortcuts.

---

*Architecture analysis: 2025-01-24*
