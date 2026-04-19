# AGENTS.md — WhisperClip

macOS 14+ SwiftUI menubar app (Apple Silicon / arm64) built with SwiftPM.  
Records audio, transcribes via on-device Whisper/Parakeet, enriches with local/cloud LLMs.

---

## Hard Rules (read first)

- **Never** mix `.planning/**` files and code changes in the same commit.
- `.planning/**` updates are allowed, but they **must** be committed separately from code.
- `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` may be committed, but keep instruction-file changes separate from code when practical.
- **Never** commit secrets; `.env*` is gitignored.
- **Never** add Intel (x86_64) assumptions — arm64 only.
- **Never** log transcripts, audio paths, prompts, or model paths unless `LOG_SENSITIVE_DATA=1` is set.
- If a workflow asks to update planning/state docs, keep them in a dedicated planning commit separate from code.

---

## Architecture

### Entry points
| File | Role |
|------|------|
| `WhisperClip.swift` | App entry, lifecycle, onboarding/permissions flow |
| `AppDelegate.swift` | NSApplicationDelegate, global notification wiring |
| `Const.swift` | All app-wide constants (`UpperCamel_With_Underscores` naming) |

### Recording pipeline
| File | Role |
|------|------|
| `RecordingCoordinator.swift` | Orchestrates the full capture→transcribe→enrich cycle |
| `AudioRecorder.swift` | Microphone capture (AVFoundation) |
| `DualChannelAudioCapture.swift` | Stereo/system-audio capture |
| `MeetingRecorder.swift` | Long-form meeting recording session |
| `SpeakerBufferManager.swift` | Per-speaker audio buffering |
| `DiarizationProvider.swift` | Speaker diarization interface (currently disabled; Phase 11) |
| `TranscriptionQueue.swift` | Queues audio chunks for transcription |

### Voice-to-text (STT)
| File | Role |
|------|------|
| `VoiceToTextProtocol.swift` | Protocol all STT models conform to |
| `VoiceToTextFactory.swift` | Selects active STT backend |
| `LocalWhisperKit.swift` | WhisperKit backend |
| `LocalParakeet.swift` | Parakeet (MLX) backend |
| `ParakeetVoiceToTextModel.swift` | Parakeet model wrapper |

### LLM / enrichment
| File | Role |
|------|------|
| `LLMProtocol.swift` | Protocol all LLM backends conform to |
| `LLMFactory.swift` | Selects active LLM backend |
| `LLM.swift` | Cloud LLM client |
| `LocalLLM.swift` | On-device MLX LLM |
| `MeetingAI.swift` | Meeting summarisation / Q&A logic |
| `MeetingDetector.swift` | Heuristic: is this audio a meeting? |

### Data / storage
| File | Role |
|------|------|
| `MeetingStorage.swift` | `@MainActor` store for meeting sessions (SwiftData) |
| `MeetingModels.swift` | SwiftData model types |
| `MeetingSession.swift` | Single meeting session value type |
| `ModelDownloader.swift` | Downloads Whisper/LLM model weights |
| `ModelStorage.swift` | Manages on-disk model files |
| `TranscriptionHistory.swift` | Persists transcription records |
| `Prompt+SwiftData.swift` | Prompt persistence |

### Settings
| File | Role |
|------|------|
| `SettingsStore.swift` | Source of truth for all user preferences |
| `SettingsDataContainer.swift` | SwiftData container for settings |
| `SettingsViewData.swift` | View-model bridge for settings UI |

### UI
| File | Role |
|------|------|
| `ContentView.swift` | Main popover view |
| `SettingsView.swift` + `*SettingsView.swift` | Settings tabs |
| `HistoryView.swift` | Transcription history list |
| `MeetingDetailView.swift` / `MeetingNotesView.swift` | Meeting detail/notes |
| `MicrophoneView.swift` | Live waveform + mic controls |
| `RecordingOverlayManager.swift` | Floating recording-status overlay |
| `WaveformView.swift` / `MeetingWaveformView.swift` | Waveform components |
| `OnboardingView.swift` | First-launch permissions flow |
| `SharedViews.swift` | Reusable view components |
| `FileTranscriptionView.swift` | Drag-and-drop file transcription |

### Infrastructure
| File | Role |
|------|------|
| `HotkeyManager.swift` | Global hotkey registration (KeyboardShortcuts) |
| `Logger.swift` | Centralised logging (`Logger.log(...)`) |
| `GenericHelper.swift` | Crypto / utility helpers |
| `SecurityChecker.swift` | Entitlement / sandbox checks |
| `Mode.swift` | App operating mode enum |
| `TimeSpenter.swift` | Elapsed-time utility |
| `Color+Hex.swift` | SwiftUI Color hex initialiser |

### Key dependencies (Package.swift)
| Package | Purpose |
|---------|---------|
| `WhisperKit` | On-device Whisper transcription |
| `mlx-swift` / `mlx-swift-examples` | MLX runtime + MLXLLM / MLXLMCommon |
| `FluidAudio` | Speaker diarization (FluidInference) |
| `KeyboardShortcuts` | Global hotkey management |

---

## Build / Run / Test

### Local builds
```sh
./local_build.sh Debug      # debug build
./local_build.sh Release    # release build

./local_run.sh Debug        # build + launch (debug)
./local_run.sh Release      # build + launch (release)
```

### Tests
```sh
swift test --parallel --verbose                                      # all tests
swift test --filter GenericHelperTests                               # by class
swift test --filter GenericHelperTests.testAES256EncryptionDecryption  # by method
```
`--filter` is substring-based — use a distinctive prefix.

### Dependency resolution
```sh
swift package resolve
# or Xcode-style (CI-like):
xcodebuild -scheme WhisperClip \
  -destination 'generic/platform=macOS' \
  -derivedDataPath ./.derivedData \
  -resolvePackageDependencies
```

### Release packaging
```sh
DEV_ID_APPLICATION="..." ./build.sh   # codesign + DMG → release/WhisperClip-<version>.dmg
```

### Notarization
```sh
APPLE_ID=... TEAM_ID=... APP_PASSWORD=... ./notarize.sh
./notarization_check.sh <submission-id>
./staple.sh
./check_bundle.sh
```

---

## Code Style

### Formatting
- 4-space indentation.
- Prefer early-exit `guard` for validation and failure paths.
- Align long argument lists with existing surrounding style.

### Imports
Order: Foundation → Apple frameworks → third-party packages. One import per line; no unused imports.

### Naming
| Kind | Convention | Example |
|------|-----------|---------|
| Types | `UpperCamelCase` | `MeetingStorage` |
| Methods / vars | `lowerCamelCase` | `generateSummary` |
| Singletons | `static let shared = ...` | — |
| Notification names | `extension Notification.Name { static let ... }` | see `AppDelegate.swift` |
| Constants (`Const.swift`) | `UpperCamel_With_Underscores` | — |

Do **not** rename existing constants for style alone.

### Types & state
- Avoid `Any` unless bridging Cocoa APIs.
- SwiftUI state: `@State`, `@StateObject`, `@Environment` as appropriate.
- Shared observable state: `ObservableObject` + `@Published`.
- Anything touching UI or `@Published` must run on the main actor; prefer `@MainActor` on UI-facing controllers.

### Error handling
- Use `throws` / `do-catch` for recoverable failures.
- User-facing errors: conform to `LocalizedError`, provide `errorDescription`.
- Never swallow errors silently unless truly non-actionable.

### Logging
```swift
Logger.log("message", category: .audio)  // categories: .general .audio .hotkey .settings .updater
```
Sensitive data (transcripts, paths, prompts) requires `LOG_SENSITIVE_DATA=1`. Local console output: `LOG_TO_CONSOLE=1`.

### Concurrency
- `async/await` for model/LLM operations.
- Heavy work off the main thread; return to `@MainActor` only for UI/state updates.
- Strict concurrency is enabled (`-strict-concurrency=complete`); all warnings must stay clean.

### Testing
- Tests in `Tests/`, extend `XCTestCase`, `@testable import WhisperClip`.
- Keep tests deterministic; no network calls or model downloads.

---

## CI

GitHub Actions: `.github/workflows/macos-build.yaml`  
- Builds Release via `xcodebuild` (arm64, code signing disabled).  
- Runs `swift test --parallel --verbose`.
