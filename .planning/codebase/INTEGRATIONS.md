# External Integrations

**Analysis Date:** 2025-02-13

## APIs & External Services

**Machine Learning Hubs:**
- Hugging Face - Used for downloading and updating machine learning models (Whisper, Gemma, Mistral, Llama, Qwen, DeepSeek, etc.).
  - SDK/Client: `swift-transformers` (HubApi)
  - Repo IDs: 
    - `argmaxinc/whisperkit-coreml` (STT)
    - `mlx-community` (LLM: DeepSeek-R1, Qwen2.5/3, Llama-3/3.2, Gemma-2, Mistral-7B, Phi-3.5)
    - `FluidInference` (STT: Parakeet)

**Update Checker:**
- GitHub - Checking for newer app versions.
  - Implementation: `WhisperClip.swift` (checkUpdate)

## Data Storage

**Databases:**
- `UserDefaults` - Persists user settings and meeting data (JSON-encoded).
  - Client: `SettingsStore.swift`, `MeetingStorage.swift`

**File Storage:**
- Local Filesystem:
  - Audio recordings: `~/Library/Application Support/WhisperClip/recordings/` (`AudioRecorder.swift`)
  - ML Models: `~/Library/Application Support/WhisperClip/models/` (`ModelStorage.swift`)

**Caching:**
- GPU Cache: Managed via `MLX.GPU.set(cacheLimit:)` in `LocalLLM.swift`.

## Authentication & Identity

**Auth Provider:**
- None - Fully local application. No user account management or cloud authentication.

## Monitoring & Observability

**Error Tracking:**
- Local only - Logs errors to system log and `Logger.swift`.

**Logs:**
- Unified Logging System (`os_log`)
  - Implementation: `Logger.swift`
  - Subsystem: `com.whisperclip`

## CI/CD & Deployment

**Hosting:**
- Apple Notarization Service - Used during build process (`notarize.sh`).

**CI Pipeline:**
- GitHub Actions - Automated builds for macOS (`macos-build.yaml`).

## Environment Configuration

**Required env vars:**
- None for runtime (local app).
- Build-time secrets (e.g., `APP_PASSWORD`, `DEVELOPER_ID`) for notarization (refer to `notarize.sh`).

## Webhooks & Callbacks

**Incoming:**
- None.

**Outgoing:**
- None.

---

*Integration audit: 2025-02-13*
