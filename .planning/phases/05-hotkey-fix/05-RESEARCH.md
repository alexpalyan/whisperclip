# Phase 5: Hotkey Fix - Research

**Researched:** 2026-03-22
**Domain:** macOS global hotkey registration — KeyboardShortcuts (SPM), Combine, AppDelegate lifecycle
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Adopt **KeyboardShortcuts** (Sindre Sorhus) package — replaces CGEventTap internals inside `HotkeyManager`
- Two named shortcuts: `.recording` and `.meetingRecording`, defined as `extension KeyboardShortcuts.Name`
- **SettingsStore remains source of truth** — `hotkeyModifier`, `hotkeyKey`, `meetingHotkeyModifier`, `meetingHotkeyKey` stay unchanged; KeyboardShortcuts own UserDefaults persistence is bypassed / not used as the primary store
- `HotkeyManaging` protocol unchanged — `updateSystemHotkey(hotkeyEnabled:modifier:keyCode:)` signature stays
- `HotkeyManager` internals swap CGEventTap for `KeyboardShortcuts` behind the same protocol
- Register both hotkeys in **`AppDelegate.applicationDidFinishLaunching`** — earliest reliable point
- Access via singletons: `SettingsStore.shared`, `HotkeyManager.shared`, `HotkeyManager.meetingShared`
- **AppDelegate owns the Combine subscriptions** — subscribe to 6 `@Published` properties in `applicationDidFinishLaunching`
- AppDelegate stores `Set<AnyCancellable>` for app-lifetime subscriptions
- `SettingsStore` stays clean — no HotkeyManager references inside it
- `NullHotkeyManager` test double remains valid (protocol unchanged)
- No UI changes; no SettingsStore public API changes

### Claude's Discretion
- Exact Combine operator choice (`receive(on:)`, `debounce`, etc.)
- Whether to debounce rapid picker changes before re-registering
- KeyboardShortcuts SPM version to pin
- Whether to keep or delete the dead `updateHotkeyMonitor()` method in WhisperClip.swift

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope.
</user_constraints>

---

## Summary

Phase 5 fixes two bugs: (1) hotkeys are never registered at app launch because `updateHotkeyMonitor()` in `WhisperClip.swift` is dead code — it is defined but never called; (2) `HotkeyManager.meetingShared` has no registration path at all, so meeting hotkeys never activate.

The fix has three coordinated parts: (a) add the **KeyboardShortcuts** SPM package (v2.4.0) and rewire `HotkeyManager` internals to use it instead of `CGEventTap`; (b) add launch-time registration in `AppDelegate.applicationDidFinishLaunching` that reads from `SettingsStore.shared` and calls `updateSystemHotkey` on both singletons; (c) add Combine subscriptions in AppDelegate to propagate future changes from SettingsStore to both managers.

**Primary recommendation:** The implementation is surgical — three files change meaningfully (`HotkeyManager.swift`, `AppDelegate.swift`, `Package.swift`), one file gets dead code removed (`WhisperClip.swift`). All existing tests must stay green with no protocol changes. The `NullHotkeyManager` mock in tests is unaffected.

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| KeyboardShortcuts | 2.4.0 | OS-level global hotkey registration | Mac App Store compatible, sandboxed, eliminates CGEventTap accessibility-permission complexity |
| Combine | (built-in, macOS 10.15+) | Reactive subscriptions: SettingsStore → AppDelegate → HotkeyManagers | Already used across the codebase; @Published properties make it a natural fit |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Foundation (AnyCancellable) | built-in | Subscription lifetime management | AppDelegate holds `Set<AnyCancellable>` |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| KeyboardShortcuts | Continue with CGEventTap | CGEventTap requires accessibility permissions and a heavy callback function; already failing on launch |
| Combine subscriptions | NotificationCenter observers | Combine is already in the codebase; type-safe and cleaner for @Published properties |

**Adding KeyboardShortcuts to Package.swift:**
```swift
// In Package.swift dependencies array:
.package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),

// In WhisperClip target dependencies:
.product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
```

**Version verified:** 2.4.0 — released 2025-09-18, confirmed via GitHub releases API.

---

## Architecture Patterns

### How KeyboardShortcuts Works (critical for planning)

KeyboardShortcuts is a name-based system:

1. **Define names** — extension on `KeyboardShortcuts.Name` (typically a separate file or top of HotkeyManager):
```swift
// Source: https://github.com/sindresorhus/KeyboardShortcuts
extension KeyboardShortcuts.Name {
    static let recording = Self("recording")
    static let meetingRecording = Self("meetingRecording")
}
```

2. **Set the shortcut programmatically** — `KeyboardShortcuts.setShortcut(_:for:)`:
```swift
// Source: KeyboardShortcuts/KeyboardShortcuts.swift
public static func setShortcut(_ shortcut: Shortcut?, for name: Name)
```
This also writes to KeyboardShortcuts' own UserDefaults key. SettingsStore values must be written to KS at launch and after each SettingsStore change to keep them in sync. This is acceptable — KS's UserDefaults entry is a derived/cache value; SettingsStore remains authoritative.

3. **Create a Shortcut from raw values** — use `carbonKeyCode` init:
```swift
// Shortcut.init(carbonKeyCode:carbonModifiers:)
// NSEvent.ModifierFlags has a .carbon computed property in the library
let shortcut = KeyboardShortcuts.Shortcut(
    carbonKeyCode: Int(keyCode),
    carbonModifiers: modifier.carbon   // extension provided by KeyboardShortcuts
)
```

4. **Register handlers** (called once at app launch, not per-update):
```swift
KeyboardShortcuts.onKeyDown(for: .recording) { [weak manager] in manager?.action() }
KeyboardShortcuts.onKeyUp(for: .recording) { [weak manager] in manager?.keyUpAction() }
```

5. **Enable/disable** without removing the handler:
```swift
KeyboardShortcuts.disable(.recording)   // unregisters OS listener
KeyboardShortcuts.enable(.recording)    // re-registers OS listener
```

### Revised HotkeyManager internals

`updateSystemHotkey(hotkeyEnabled:modifier:keyCode:)` becomes:
```swift
func updateSystemHotkey(hotkeyEnabled: Bool, modifier: NSEvent.ModifierFlags, keyCode: UInt16) {
    // Skip if identical to current registered values
    if currentModifier == modifier && currentKeyCode == keyCode && hotkeyEnabled == isEnabled {
        return
    }
    currentModifier = modifier
    currentKeyCode = keyCode
    isEnabled = hotkeyEnabled

    if hotkeyEnabled {
        let shortcut = KeyboardShortcuts.Shortcut(carbonKeyCode: Int(keyCode),
                                                   carbonModifiers: modifier.carbon)
        KeyboardShortcuts.setShortcut(shortcut, for: name)  // name is a stored property
        KeyboardShortcuts.enable(name)
    } else {
        KeyboardShortcuts.disable(name)
    }
}
```

Each `HotkeyManager` instance must know its `KeyboardShortcuts.Name`. Since `shared` and `meetingShared` are separate instances, they must carry different names:
```swift
class HotkeyManager: ObservableObject, HotkeyManaging {
    static let shared = HotkeyManager(shortcutName: .recording)
    static let meetingShared = HotkeyManager(shortcutName: .meetingRecording)
    private let name: KeyboardShortcuts.Name
    // ...
    private init(shortcutName: KeyboardShortcuts.Name) {
        self.name = shortcutName
        // Register handlers once
        KeyboardShortcuts.onKeyDown(for: shortcutName) { [weak self] in self?.action() }
        KeyboardShortcuts.onKeyUp(for: shortcutName) { [weak self] in self?.keyUpAction() }
    }
}
```

### AppDelegate wiring pattern

```swift
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupSignalHandlers()
        setupStatusBarItem()

        // 1. Register hotkeys at launch from SettingsStore values
        let store = SettingsStore.shared
        HotkeyManager.shared.updateSystemHotkey(
            hotkeyEnabled: store.hotkeyEnabled,
            modifier: store.hotkeyModifier,
            keyCode: store.hotkeyKey
        )
        HotkeyManager.meetingShared.updateSystemHotkey(
            hotkeyEnabled: store.meetingHotkeyEnabled,
            modifier: store.meetingHotkeyModifier,
            keyCode: store.meetingHotkeyKey
        )

        // 2. Subscribe to future changes
        Publishers.CombineLatest3(
            store.$hotkeyEnabled,
            store.$hotkeyModifier,
            store.$hotkeyKey
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] enabled, modifier, keyCode in
            HotkeyManager.shared.updateSystemHotkey(
                hotkeyEnabled: enabled, modifier: modifier, keyCode: keyCode)
        }
        .store(in: &cancellables)

        Publishers.CombineLatest3(
            store.$meetingHotkeyEnabled,
            store.$meetingHotkeyModifier,
            store.$meetingHotkeyKey
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] enabled, modifier, keyCode in
            HotkeyManager.meetingShared.updateSystemHotkey(
                hotkeyEnabled: enabled, modifier: modifier, keyCode: keyCode)
        }
        .store(in: &cancellables)

        Logger.log("Application did finish launching", log: Logger.general)
        // ...
    }
}
```

Note: `CombineLatest3` emits once immediately on subscription with current values. This means the launch registration call and the first publisher emission are a harmless double-registration — the existing guard (`if currentModifier == modifier && currentKeyCode == keyCode { return }`) in HotkeyManager absorbs it.

**Alternative:** Use separate `sink` subscriptions per published property instead of `CombineLatest3`. Simpler but fires three times on launch (once per property). With the idempotency guard this is also fine. Claude's discretion.

### Debounce consideration

If the user rapidly changes the modifier/key picker in Settings, multiple calls to `updateSystemHotkey` fire in quick succession. KeyboardShortcuts re-registers each time, which is low-cost for modern macOS. A `.debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)` before `.sink` prevents unnecessary churn. Claude's discretion.

### Recommended Project Structure (no changes needed)
```
Sources/
├── HotkeyManager.swift        # Changed: swap CGEventTap for KeyboardShortcuts
├── AppDelegate.swift          # Changed: add launch registration + Combine subs
├── WhisperClip.swift          # Changed: remove/neutralize dead updateHotkeyMonitor()
├── Package.swift              # Changed: add KeyboardShortcuts dependency
└── (all other files)          # Unchanged
```

### Anti-Patterns to Avoid
- **Registering handlers inside `updateSystemHotkey`:** `onKeyDown`/`onKeyUp` should be called once in `init`. Calling them on every `updateSystemHotkey` stacks duplicate handlers.
- **Storing KeyboardShortcuts values as the source of truth:** SettingsStore is authoritative. Never read from `KeyboardShortcuts.getShortcut(for:)` to populate the UI or tests.
- **Keeping CGEventTap alongside KeyboardShortcuts:** Remove all `CGEvent.tapCreate`, `runLoopSource`, and `hotkeyCallback` code entirely — they would conflict and require the Accessibility permission that KeyboardShortcuts avoids.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| OS-level hotkey interception | `CGEventTap` + runloop source | `KeyboardShortcuts.onKeyDown/onKeyUp` | CGEventTap requires accessibility permission, complex callback lifecycle, and is already broken in this codebase |
| Modifier flag ↔ Carbon conversion | Manual bitwise math | `NSEvent.ModifierFlags.carbon` (extension from KeyboardShortcuts) | Library provides it; exact equivalence guaranteed |
| Multiple publisher subscription management | Individual var for each cancellable | `Set<AnyCancellable>` | Standard Combine pattern; already used elsewhere in project |

**Key insight:** The existing `CGEventTap` code is the root cause of both bugs — it's the complex infrastructure that was never properly wired to the launch sequence. Replacing it eliminates both bugs simultaneously.

---

## Common Pitfalls

### Pitfall 1: Handler Accumulation
**What goes wrong:** `KeyboardShortcuts.onKeyDown(for:action:)` appends handlers; calling it multiple times stacks them, so each keypress fires N callbacks.
**Why it happens:** Handlers are added, never replaced.
**How to avoid:** Call `onKeyDown`/`onKeyUp` exactly once per name — in `HotkeyManager.init`.
**Warning signs:** Action fires multiple times per keypress.

### Pitfall 2: KeyboardShortcuts UserDefaults conflict with SettingsStore
**What goes wrong:** `setShortcut` writes to its own UserDefaults key (e.g., `"KeyboardShortcuts.recording"`). On next launch, KeyboardShortcuts would read its own stored value if you call `getShortcut(for:)`. But we never do — we always call `setShortcut` from SettingsStore values at launch. So the KS key is overwritten each launch.
**Why it happens:** KS persists shortcuts by default via its own key.
**How to avoid:** Always call `setShortcut` with SettingsStore values in `applicationDidFinishLaunching` before anything else touches KS. Never rely on KS's stored value.
**Warning signs:** After restart, hotkey registered with different key than SettingsStore shows.

### Pitfall 3: Combine subscriptions firing on main thread
**What goes wrong:** SettingsStore `@Published` properties may emit on background threads when changed from background context.
**Why it happens:** `didSet` on @Published fires on the thread that set the property.
**How to avoid:** Add `.receive(on: DispatchQueue.main)` before `.sink` in AppDelegate subscriptions — ensures `updateSystemHotkey` always called on main.

### Pitfall 4: Double-registration on launch
**What goes wrong:** Launch registration + first Combine sink emission both call `updateSystemHotkey` with identical values. CGEventTap would have been expensive to re-create; with KeyboardShortcuts this is cheap.
**Why it happens:** `CombineLatest3` emits immediately on subscription.
**How to avoid:** The existing `if currentModifier == modifier && currentKeyCode == keyCode { return }` guard handles this. It can be extended to also check `hotkeyEnabled`.
**Warning signs:** Not actually a problem with the guard in place.

### Pitfall 5: `private init()` breaking with parameterized init
**What goes wrong:** Changing `private init()` to `private init(shortcutName:)` while static singletons call `HotkeyManager()` — compile error.
**Why it happens:** Singletons initialize with no-arg init, but new init requires a name.
**How to avoid:** Replace `static let shared = HotkeyManager()` with `static let shared = HotkeyManager(shortcutName: .recording)` as part of the same change.

### Pitfall 6: Dead `updateHotkeyMonitor()` leaves confusion
**What goes wrong:** The method in WhisperClip.swift looks like it should work, confusing future developers.
**Why it happens:** It was wired nowhere — `WhisperClip.init()` never calls it, `onAppear` never calls it.
**How to avoid:** Delete the method (or add a deprecation comment if the planner wants conservative approach).

---

## Code Examples

### Defining KeyboardShortcuts Names
```swift
// Source: https://github.com/sindresorhus/KeyboardShortcuts readme
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let recording = Self("recording")
    static let meetingRecording = Self("meetingRecording")
}
```

### Building a Shortcut from SettingsStore values
```swift
// NSEvent.ModifierFlags.carbon is an extension provided by KeyboardShortcuts
import KeyboardShortcuts

let shortcut = KeyboardShortcuts.Shortcut(
    carbonKeyCode: Int(store.hotkeyKey),          // UInt16 → Int
    carbonModifiers: store.hotkeyModifier.carbon  // NSEvent.ModifierFlags → Carbon Int
)
KeyboardShortcuts.setShortcut(shortcut, for: .recording)
```

### Enabling / disabling without touching the shortcut value
```swift
// Source: KeyboardShortcuts/KeyboardShortcuts.swift
KeyboardShortcuts.enable(.recording)
KeyboardShortcuts.disable(.recording)
```

### Combine: subscribing to three properties together
```swift
import Combine

Publishers.CombineLatest3(
    store.$hotkeyEnabled,
    store.$hotkeyModifier,
    store.$hotkeyKey
)
.debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)  // optional
.sink { enabled, modifier, keyCode in
    HotkeyManager.shared.updateSystemHotkey(
        hotkeyEnabled: enabled, modifier: modifier, keyCode: keyCode)
}
.store(in: &cancellables)
```

### AppDelegate cancellables property
```swift
// AppDelegate does not currently import Combine — must be added
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()
    // ...
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| CGEventTap + runloop | KeyboardShortcuts (SPM) | Phase 5 | Eliminates accessibility permission requirement; simpler handler registration |
| Dead `updateHotkeyMonitor()` in App struct | Live `applicationDidFinishLaunching` wiring in AppDelegate | Phase 5 | Hotkeys actually register at launch |
| No meeting hotkey registration path | AppDelegate subscribes to meetingHotkey properties | Phase 5 | Meeting hotkey works for first time |

**Deprecated/outdated by this phase:**
- `CGEvent.tapCreate` call in `HotkeyManager.setupSystemHotkey`: removed
- `runLoopSource` / `CFRunLoopAddSource` / `CGEvent.tapEnable`: removed
- `hotkeyCallback` static function at bottom of HotkeyManager.swift: removed
- `updateHotkeyMonitor()` in WhisperClip.swift: removed (dead code)

---

## Open Questions

1. **Does `NSEvent.ModifierFlags.carbon` require importing Carbon framework?**
   - What we know: KeyboardShortcuts defines this extension internally. When using KeyboardShortcuts as a dependency, the `.carbon` property is available on `NSEvent.ModifierFlags` in files that `import KeyboardShortcuts`.
   - What's unclear: Whether a bare `import Carbon` in HotkeyManager.swift conflicts.
   - Recommendation: Remove `import Quartz` (currently there for CGEventTap) and add `import KeyboardShortcuts`. Do not add `import Carbon` — KeyboardShortcuts wraps it.

2. **Will the planner keep or delete `updateHotkeyMonitor()` in WhisperClip.swift?**
   - What we know: It is definitively dead code — defined but never called.
   - What's unclear: Conservative "keep with comment" vs delete entirely.
   - Recommendation: Delete it. It references `HotkeyManager.shared` which remains, but calling it is never needed now that AppDelegate handles registration.

3. **Should `CombineLatest3` or separate `sink` subscriptions be used?**
   - What we know: `CombineLatest3` groups the three properties into one emission; separate sinks are simpler but fire individually.
   - Recommendation: Use `CombineLatest3` for each hotkey group (recording vs meeting). This ensures a single `updateSystemHotkey` call when e.g. both modifier and keyCode change together in the picker.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (built-in, Swift Package Manager) |
| Config file | Package.swift testTarget `WhisperClipTests` |
| Quick run command | `swift test --filter HotkeySettingsViewModelTests` |
| Full suite command | `swift test` |

### Phase Requirements → Test Map

This phase has no new named requirement IDs from REQUIREMENTS.md (Phase 5 is not listed in the traceability matrix). The functional requirements from CONTEXT.md decisions map as follows:

| Behavior | Test Type | Automated Command | Notes |
|----------|-----------|-------------------|-------|
| `HotkeySettingsViewModelTests` remain green after HotkeyManager rewrite | regression | `swift test --filter HotkeySettingsViewModelTests` | Existing 5 tests; NullHotkeyManager is protocol-compatible |
| `updateSystemHotkey` is called on launch (both managers) | integration / manual | Manual test: launch app, verify hotkey works | Cannot unit-test AppDelegate.applicationDidFinishLaunching easily |
| Combine subscription propagates SettingsStore changes | unit | New test in HotkeySettingsViewModelTests or new AppDelegateHotkeyTests | Inject mock store, verify updateSystemHotkey called |

### Sampling Rate
- **Per task commit:** `swift test --filter HotkeySettingsViewModelTests`
- **Per wave merge:** `swift test`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

The existing test infrastructure covers the ViewModel layer. No new test files are strictly required for the protocol-unchanged path, but an integration smoke test for the AppDelegate wiring would be valuable:

- [ ] Optional: `Tests/HotkeyAppDelegateSmokeTests.swift` — covers: (1) after calling `applicationDidFinishLaunching`, both shared managers have been given `updateSystemHotkey` calls. This requires either a spy/mock HotkeyManager or verifying `currentModifier`/`currentKeyCode` values on the singletons after a test-version `applicationDidFinishLaunching`.

Existing tests require zero changes if:
- `HotkeyManaging` protocol signature is unchanged (confirmed)
- `NullHotkeyManager` struct remains valid (confirmed — it's in the test file itself)

---

## Sources

### Primary (HIGH confidence)
- `https://github.com/sindresorhus/KeyboardShortcuts` — README, Shortcut.swift, KeyboardShortcuts.swift, Utilities.swift — version 2.4.0 confirmed via GitHub releases API (2025-09-18)
- Project source files read directly: `HotkeyManager.swift`, `AppDelegate.swift`, `WhisperClip.swift`, `SettingsStore.swift`, `HotkeySettingsViewModel.swift`, `Tests/HotkeySettingsViewModelTests.swift`, `Package.swift`, `Package.resolved`

### Secondary (MEDIUM confidence)
- GitHub releases API: `api.github.com/repos/sindresorhus/KeyboardShortcuts/releases/latest` — confirmed 2.4.0 current

### Tertiary (LOW confidence)
- None

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — KeyboardShortcuts 2.4.0 confirmed from GitHub releases API; Combine is Apple built-in
- Architecture: HIGH — all source files read directly; KeyboardShortcuts API verified from source
- Pitfalls: HIGH — derived directly from reading KeyboardShortcuts source (setShortcut writes to UserDefaults, onKeyDown appends) and the existing broken code

**Research date:** 2026-03-22
**Valid until:** 2026-04-22 (KeyboardShortcuts is stable; Combine API is Apple-stable)
