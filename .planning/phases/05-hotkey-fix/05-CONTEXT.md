# Phase 5: Hotkey Fix - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Stabilize global hotkey registration and ensure full customizability. Two problems to fix:
1. Hotkeys are never registered on app launch (`updateHotkeyMonitor()` is dead code in WhisperClip.swift)
2. Meeting hotkey (`HotkeyManager.meetingShared`) has no registration path anywhere

Scope: `HotkeyManager`, `AppDelegate`, `SettingsStore` wiring only. No UI changes. No SettingsStore public API changes.

</domain>

<decisions>
## Implementation Decisions

### Library
- Adopt **KeyboardShortcuts** (Sindre Sorhus) package for OS-level event registration — replaces the CGEventTap internals inside `HotkeyManager`
- Two named shortcuts: `.recording` (main hotkey) and `.meetingRecording` (meeting hotkey), defined as `extension KeyboardShortcuts.Name`
- **SettingsStore remains the source of truth** — `hotkeyModifier`, `hotkeyKey`, `meetingHotkeyModifier`, `meetingHotkeyKey` properties stay unchanged. KeyboardShortcuts is initialized from SettingsStore values at launch; its own UserDefaults persistence is bypassed / not used
- `HotkeyManaging` protocol is unchanged — still `updateSystemHotkey(hotkeyEnabled:modifier:keyCode:)`. `HotkeyManager` internals swap CGEventTap for `KeyboardShortcuts` behind the same protocol

### Launch registration
- Register both hotkeys in **`AppDelegate.applicationDidFinishLaunching`** — earliest reliable point, before SwiftUI scene renders
- Access via singletons: `SettingsStore.shared`, `HotkeyManager.shared`, `HotkeyManager.meetingShared`
- Call `HotkeyManager.shared.updateSystemHotkey(hotkeyEnabled: store.hotkeyEnabled, modifier: store.hotkeyModifier, keyCode: store.hotkeyKey)` and the equivalent for meeting hotkey
- Remove or replace the dead `updateHotkeyMonitor()` method in `WhisperClip.swift`

### Change propagation
- **SettingsStore stays clean** — no HotkeyManager references inside SettingsStore
- **AppDelegate owns the Combine subscriptions** — in `applicationDidFinishLaunching`, subscribe to `SettingsStore.shared.$hotkeyKey`, `.$hotkeyModifier`, `.$hotkeyEnabled`, `.$meetingHotkeyKey`, `.$meetingHotkeyModifier`, `.$meetingHotkeyEnabled`
- Each sink calls `updateSystemHotkey(...)` on the appropriate manager
- AppDelegate stores `Set<AnyCancellable>` to keep subscriptions alive for the app lifetime
- The existing VM path (`vm.onKeyCodeChanged → updateHotkey()`) can remain as-is — it becomes redundant but harmless (double-registration is guarded by the existing `if currentModifier == modifier && currentKeyCode == keyCode { return }` check in HotkeyManager)

### Protocol evolution
- `HotkeyManaging` protocol **unchanged** — `updateSystemHotkey(hotkeyEnabled:modifier:keyCode:)` signature stays
- VMs continue to call `hotkeyManager.updateSystemHotkey(...)` — no NSEvent or Carbon API exposure
- `NullHotkeyManager` test double from Phase 4 remains valid

### Claude's Discretion
- Exact Combine operator choice (receive(on:), debounce, etc.)
- Whether to debounce rapid picker changes before re-registering
- KeyboardShortcuts SPM version to pin
- Whether to keep or delete the dead `updateHotkeyMonitor()` method in WhisperClip.swift

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Hotkey layer
- `Sources/HotkeyManager.swift` — Current CGEventTap implementation + HotkeyManaging protocol definition
- `Sources/HotkeySettingsViewModel.swift` — VM that calls HotkeyManaging; must stay decoupled from NSEvent
- `Sources/AppDelegate.swift` — Launch point; applicationDidFinishLaunching is the target for registration + subscriptions

### Settings persistence
- `Sources/SettingsStore.swift` — Source of truth for all hotkey values (hotkeyEnabled, hotkeyModifier, hotkeyKey, meetingHotkey*); public API must not change

### Entry point
- `Sources/WhisperClip.swift` — Contains dead `updateHotkeyMonitor()` method; scene/app lifecycle

### Tests
- `Tests/HotkeySettingsViewModelTests.swift` — Existing tests use NullHotkeyManager; must remain green after changes

No external specs — requirements fully captured in decisions above and user description.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `HotkeyManaging` protocol — already defined in HotkeyManager.swift; KeyboardShortcuts implementation goes behind it
- `NullHotkeyManager` — test double in HotkeySettingsViewModelTests.swift; stays valid (protocol unchanged)
- `HotkeyManager.shared` + `HotkeyManager.meetingShared` — two singleton instances; both need registration wiring

### Established Patterns
- Singletons: `SettingsStore.shared`, `HotkeyManager.shared` — consistent usage across app
- Combine `@Published` properties on SettingsStore — already used by SwiftUI; AppDelegate subscriptions follow the same pattern
- `applicationDidFinishLaunching` currently sets up signal handlers + status bar item — adding hotkey registration here is consistent

### Integration Points
- `AppDelegate.applicationDidFinishLaunching` — add registration calls and Combine subscriptions here
- `HotkeyManager` internals only — swap CGEventTap for KeyboardShortcuts; public protocol surface unchanged
- `WhisperClip.swift` — remove/replace dead `updateHotkeyMonitor()` to avoid confusion

</code_context>

<specifics>
## Specific Ideas

- "Use KeyboardShortcuts (or the existing native implementation)" — user explicitly named the KeyboardShortcuts package as the preferred option
- "ViewModels should not know about NSEvent or low-level Carbon APIs" — already achieved in Phase 2/4; preserve this
- "When the app restarts, HotkeyManager correctly reads the stored values and registers them immediately" — the AppDelegate.applicationDidFinishLaunching approach directly addresses this
- "Protocol-First: HotkeyManager and MeetingHotkeyManager must be injectable" — already done in Phase 4; confirmed as a hard requirement

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 05-hotkey-fix*
*Context gathered: 2026-03-22*
