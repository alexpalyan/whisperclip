# Codebase Concerns

**Analysis Date:** 2025-01-24

## Tech Debt

**Settings View Complexity:**
- Issue: Large file size (now over 1,400 lines) with multiple responsibilities.
- Files: `Sources/SettingsView.swift`
- Impact: Increased difficulty in maintenance and UI testing.
- Fix approach: Decompose into smaller, focused sub-views and view models (SettingsStore, ModelDownloader, and prompt editing).

**Meeting Recorder Logic:**
- Issue: Logic duplication and high complexity in recording management.
- Files: `Sources/MeetingRecorder.swift`
- Impact: Increased risk of bugs during recording state transitions.
- Fix approach: Extract shared recording logic and simplify state management.

**Swift Strict Concurrency Warnings:**
- Issue: Significant number of concurrency warnings (SWIFT_STRICT_CONCURRENCY=complete), particularly around `MeetingRecorder` and `TranscriptionQueue` closure handoffs.
- Files: `Sources/MeetingRecorder.swift`, `Sources/TranscriptionQueue.swift`
- Impact: Potential for hard-to-debug race conditions or crashes, especially as async complexity grows in Phase 13 (Reconciler).
- Fix approach: Systematic cleanup of non-isolated closures, proper actor isolation, and Sendable conformance audits.

## Performance Bottlenecks

**CoreML Inference:**
- Problem: High CPU/GPU and memory usage during transcription and LLM inference.
- Files: `Sources/LocalWhisperKit.swift`, `Sources/LocalParakeet.swift`, `Sources/LocalLLM.swift`
- Cause: Local execution of resource-intensive voice-to-text and text models (up to 30B parameters like Qwen3-30B-A3B).
- Improvement path: Optimize model loading strategies and explore quantized models.

## Fragile Areas

**System Audio Capture:**
- Files: `Sources/DualChannelAudioCapture.swift`
- Why fragile: Tight coupling with `ScreenCaptureKit` and sensitive system permissions.
- Safe modification: Test across multiple macOS versions (14.0+).
- Test coverage: None.

**Apple Events Permission:**
- Files: `Sources/SecurityChecker.swift`
- Status: IMPROVED. Now uses `AEDeterminePermissionToAutomateTarget` for more robust permission handling instead of fragile `NSAppleScript` checks.

## Scaling Limits

**UserDefaults Storage:**
- Current capacity: Unlimited but performance degrades with size.
- Limit: Storing large datasets or extensive history in `UserDefaults` impacts app launch and responsiveness.
- Files: `Sources/SettingsStore.swift`
- Scaling path: Migrate large data structures (like transcription history) to SQLite or CoreData.

## Test Coverage Gaps

**Core Business Logic:**
- What's not tested: Transcription engines, meeting detection logic, and state persistence.
- Files: `Sources/VoiceToTextFactory.swift`, `Sources/MeetingDetector.swift`, `Sources/MeetingStorage.swift`
- Risk: Functional regressions in core app features go undetected.
- Priority: High

---

*Concerns audit: 2025-01-24*
