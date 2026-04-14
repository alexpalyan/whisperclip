# Codebase Structure

**Analysis Date:** 2025-01-24

## Directory Layout

```
whisperclip/
├── Sources/                # All Swift source code (Flat structure)
├── Tests/                  # Unit tests
├── icons/                  # App icon assets and generation scripts
├── .github/workflows/      # CI/CD pipelines
├── Package.swift           # Swift Package Manager manifest
└── README.md               # Project documentation
```

## Directory Purposes

**Sources/:**
- Purpose: Contains all application logic, UI, and services.
- Contains: Swift files (.swift).
- Key files: `WhisperClip.swift`, `AppDelegate.swift`, `MeetingRecorder.swift`.

**Tests/:**
- Purpose: Contains unit tests for application logic.
- Contains: Swift test files (`*Tests.swift`).
- Key files: `GenericHelperTests.swift`.

**icons/:**
- Purpose: Stores source images for icons and scripts to generate .icns files.
- Contains: PNG images, `create_icons.sh`.

**.github/workflows/:**
- Purpose: GitHub Actions configuration for automated builds and releases.
- Contains: `macos-build.yaml`.

## Key File Locations

**Entry Points:**
- `Sources/WhisperClip.swift`: Main SwiftUI App entry point.
- `Sources/AppDelegate.swift`: Legacy Cocoa app delegate for lifecycle and status bar management.

**Configuration:**
- `Package.swift`: Dependency management and build configuration.
- `Sources/Const.swift`: Global constants (App name, links, bundle IDs).
- `Sources/SettingsStore.swift`: User preferences persistence.

**Core Logic (Managers):**
- `Sources/MeetingRecorder.swift`: Orchestrates meeting sessions.
- `Sources/AudioRecorder.swift`: Handles simple clip recordings.
- `Sources/HotkeyManager.swift`: Manages global system hotkeys.
- `Sources/MeetingStorage.swift`: Manages persistence of meeting notes.

**AI Services:**
- `Sources/LocalWhisperKit.swift`: OpenAI Whisper implementation via WhisperKit.
- `Sources/LocalParakeet.swift`: Apple Parakeet implementation.
- `Sources/LocalLLM.swift`: MLX-based LLM implementation.

**Testing:**
- `Tests/GenericHelperTests.swift`: Tests for utility functions.

## Naming Conventions

**Files:**
- [PascalCase]: Most source files (e.g., `MeetingRecorder.swift`, `ContentView.swift`).
- [Suffixes]:
    - `*View.swift`: SwiftUI Views.
    - `*Protocol.swift`: Interface definitions.
    - `*Factory.swift`: Service instantiation logic.
    - `*Manager.swift` / `*Recorder.swift` / `*Storage.swift`: Orchestration and logic classes.

**Directories:**
- [PascalCase]: Standard for Swift projects (e.g., `Sources`, `Tests`).
- [lowercase]: Resource directories (e.g., `icons`).

## Where to Add New Code

**New Feature (UI):**
- Implementation: Add a new `*View.swift` in `Sources/`.
- Integration: Reference it in `ContentView.swift` or `WhisperClip.swift`.

**New Business Logic:**
- Implementation: Create a new `*Manager.swift` or `*Service.swift` in `Sources/`.
- Patterns: Use the singleton pattern (`static let shared`) if it needs to be globally accessible.

**New AI Model Support:**
- Implementation: Create a new class in `Sources/` implementing `VoiceToTextProtocol` or `LLMProtocol`.
- Integration: Update `VoiceToTextFactory.swift` or `LLMFactory.swift`.

**Utilities:**
- Shared helpers: Add to `Sources/GenericHelper.swift` or create a new specific helper file.

## Special Directories

**.planning/:**
- Purpose: Contains codebase mapping and planning documentation.
- Generated: Yes (by GSD tools).
- Committed: Yes.

**.build/:**
- Purpose: SPM build artifacts.
- Generated: Yes.
- Committed: No.

---

*Structure analysis: 2025-01-24*
