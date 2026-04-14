# Technology Stack

**Analysis Date:** 2025-02-13

## Languages

**Primary:**
- Swift 5.10 - Core application logic, UI (SwiftUI), and ML integration.

## Runtime

**Environment:**
- macOS 14.0+ (Sonoma)

**Package Manager:**
- Swift Package Manager (SPM)
- Lockfile: `Package.resolved` present.

## Frameworks

**Core:**
- SwiftUI - User interface.
- AppKit - macOS system integration (e.g., `AppDelegate`, menu bar).
- AVFoundation - Audio recording and playback.
- OSLog - System logging.

**Testing:**
- XCTest - Unit tests in `Tests/`.

**Build/Dev:**
- Swift Package Manager - Build system.
- GitHub Actions - CI/CD pipeline (`.github/workflows/macos-build.yaml`).

## Key Dependencies

**Critical:**
- `WhisperKit` (argmaxinc) - Local OpenAI Whisper models for speech-to-text.
- `mlx-swift` (ml-explore) - Apple Silicon optimized ML inference.
- `mlx-swift-examples` (ml-explore) - LLM implementation (Gemma, Llama, Mistral) for MLX.
- `FluidAudio` (FluidInference) - Local Parakeet ASR support.
- `swift-transformers` (huggingface) - Hugging Face Hub access for model management.

**Infrastructure:**
- `GzipSwift` - Gzip compression support.
- `Jinja` - Template engine for prompt engineering.
- `swift-argument-parser` - CLI argument parsing.

## Configuration

**Environment:**
- Configured via `SettingsStore.swift` and `UserDefaults`.
- `Const.swift` - Compile-time constants and default values.

**Build:**
- `Package.swift` - SPM configuration.
- `local_build.sh` - Local build script with notarization support.

## Platform Requirements

**Development:**
- Xcode 15+
- macOS 14+

**Production:**
- macOS 14.0+ (Apple Silicon highly recommended for MLX).

---

*Stack analysis: 2025-02-13*
