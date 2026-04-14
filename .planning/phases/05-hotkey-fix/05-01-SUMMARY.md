---
phase: 05-hotkey-fix
plan: 01
subsystem: hotkey
tags: [KeyboardShortcuts, CGEventTap, SPM, Carbon, NSEvent, ObservableObject]

# Dependency graph
requires: []
provides:
  - KeyboardShortcuts 2.4.0 SPM dependency in Package.swift
  - HotkeyManager backed by KeyboardShortcuts instead of CGEventTap
  - Two named shortcuts: .recording and .meetingRecording
  - HotkeyManaging protocol unchanged
affects:
  - 05-02 (AppDelegate wiring — depends on HotkeyManager.shared, HotkeyManager.meetingShared)

# Tech tracking
tech-stack:
  added:
    - KeyboardShortcuts 2.4.0 (sindresorhus/KeyboardShortcuts)
  patterns:
    - Named shortcuts via extension KeyboardShortcuts.Name
    - Singleton HotkeyManager instances carry their KeyboardShortcuts.Name as a stored property
    - onKeyDown/onKeyUp registered once in init; enable/disable used per updateSystemHotkey call
    - Carbon modifier flags computed inline (import Carbon.HIToolbox) since .carbon is library-internal

key-files:
  created: []
  modified:
    - Package.swift
    - Package.resolved
    - Sources/HotkeyManager.swift

key-decisions:
  - "Used import Carbon.HIToolbox to convert NSEvent.ModifierFlags to carbon Int manually — KeyboardShortcuts.Shortcut.carbon is internal"
  - "Kept HotkeyManaging protocol signature unchanged; NullHotkeyManager in tests remains valid"
  - "Registered onKeyDown/onKeyUp in init (not updateSystemHotkey) to avoid handler accumulation"
  - "Added isEnabled stored property for idempotent guard in updateSystemHotkey"

patterns-established:
  - "KeyboardShortcuts name-based hotkey pattern: define names in extension, register handlers in init, set/enable/disable in updateSystemHotkey"

requirements-completed:
  - HF-01
  - HF-02

# Metrics
duration: 2min
completed: 2026-03-22
---

# Phase 05 Plan 01: Add KeyboardShortcuts SPM Dependency and Rewrite HotkeyManager Internals Summary

**KeyboardShortcuts 2.4.0 added as SPM dependency; HotkeyManager rewritten to use named shortcut registration (onKeyDown/onKeyUp) with enable/disable API, fully removing CGEventTap, runLoopSource, and hotkeyCallback**

## Performance

- **Duration:** 2 min
- **Started:** 2026-03-22T07:33:35Z
- **Completed:** 2026-03-22T07:35:52Z
- **Tasks:** 2
- **Files modified:** 3 (Package.swift, Package.resolved, Sources/HotkeyManager.swift)

## Accomplishments
- Added KeyboardShortcuts 2.4.0 SPM package; `swift package resolve` exits 0
- Removed all CGEventTap infrastructure (event tap, runloop source, hotkeyCallback free function)
- Rewrote HotkeyManager internals to use KeyboardShortcuts name-based API with onKeyDown/onKeyUp handlers registered once in init
- Preserved HotkeyManaging protocol signature; all 18 existing tests remain green

## Task Commits

Each task was committed atomically:

1. **Task 1: Add KeyboardShortcuts SPM dependency to Package.swift** - `dea994a` (chore)
2. **Task 2: Rewrite HotkeyManager internals with KeyboardShortcuts** - `ec11f74` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified
- `Package.swift` - Added KeyboardShortcuts dependency and target product
- `Package.resolved` - Resolved KeyboardShortcuts 2.4.0
- `Sources/HotkeyManager.swift` - Full rewrite: CGEventTap removed, KeyboardShortcuts API, named shortcuts, parameterized singleton init

## Decisions Made
- Imported `Carbon.HIToolbox` directly to compute carbon modifier Int values, because `NSEvent.ModifierFlags.carbon` is declared `internal` in the KeyboardShortcuts library and not accessible from user code. This avoids duplicating the library's logic while still constructing a valid `KeyboardShortcuts.Shortcut`.
- Registered `onKeyDown`/`onKeyUp` handlers exactly once in `init` (not in `updateSystemHotkey`) to prevent handler accumulation on repeated calls.
- Added `private var isEnabled: Bool` to the idempotency guard so same-state calls (including the harmless double-registration from Combine's immediate emission at subscription time) are absorbed cheaply.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] NSEvent.ModifierFlags.carbon is inaccessible (internal protection level)**
- **Found during:** Task 2 (Rewrite HotkeyManager internals)
- **Issue:** The plan prescribed `modifier.carbon` to build a `KeyboardShortcuts.Shortcut`. The `.carbon` computed property is declared `internal` in the library; calling it from outside the module produces a compile error.
- **Fix:** Added `import Carbon.HIToolbox` and computed the carbon modifier Int inline using the Carbon framework constants (`controlKey`, `optionKey`, `shiftKey`, `cmdKey`) — matching the library's internal logic exactly.
- **Files modified:** Sources/HotkeyManager.swift
- **Verification:** `swift build` exits 0; all 18 tests pass
- **Committed in:** ec11f74 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 — bug: inaccessible API)
**Impact on plan:** Auto-fix necessary for compilation. The resulting code is functionally identical to what the plan intended; Carbon constants are stable and the same values used internally by KeyboardShortcuts.

## Issues Encountered
- None beyond the auto-fixed modifier access issue.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- HotkeyManager is fully backed by KeyboardShortcuts; singletons `.shared` and `.meetingShared` are ready
- AppDelegate wiring (plan 05-02) can now call `HotkeyManager.shared.updateSystemHotkey(...)` and `HotkeyManager.meetingShared.updateSystemHotkey(...)` at launch and via Combine subscriptions
- No blockers

---
*Phase: 05-hotkey-fix*
*Completed: 2026-03-22*
