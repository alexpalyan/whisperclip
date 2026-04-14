# Coding Conventions

**Analysis Date:** 2025-02-14

## Naming Patterns

**Files:**
- PascalCase for Swift source files matching the main type defined within.
- Example: `Sources/AudioRecorder.swift`, `Sources/AppDelegate.swift`.

**Functions:**
- camelCase for function names.
- Descriptive names following Swift's "API Design Guidelines".
- Example: `func start() throws`, `func setupSignalHandlers()`.

**Variables:**
- camelCase for variables and properties.
- Private properties often lack specific prefixes (no leading underscores observed).
- Example: `private var signalSources: [DispatchSourceSignal] = []`, `var isRecording = false`.

**Types:**
- PascalCase for Classes, Structs, Enums, and Protocols.
- Example: `class AppDelegate`, `struct ContentView`, `enum SidebarItem`, `protocol VoiceToTextProtocol`.

## Code Style

**Formatting:**
- Standard Swift formatting (likely default Xcode/Swift configuration).
- Use of 4-space indentation.
- Opening braces on the same line as the declaration.

**Linting:**
- No explicit linting configuration (`.swiftlint.yml`) detected in the root directory.

## Import Organization

**Order:**
1. System frameworks (e.g., `Foundation`, `SwiftUI`, `AppKit`).
2. Internal modules (if any, though most appear to be in the same module).
3. Third-party dependencies (not explicitly separated but typically follow system imports).

**Path Aliases:**
- Not applicable (standard Swift package structure).

## Error Handling

**Patterns:**
- Extensive use of `do-catch` blocks and `throwing` functions.
- Custom `NSError` objects for domain-specific errors.
- Example from `Sources/AudioRecorder.swift`:
```swift
func start() throws {
    if isRecording {
        throw NSError(domain: "AudioRecorder", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Recording already in progress"])
    }
    // ...
}
```

## Logging

**Framework:** Custom `Logger` wrapper around `os.log`.

**Patterns:**
- Use of `Logger.log(_:log:type:)` with categorized `OSLog` instances.
- Categories include: `hotkey`, `audio`, `settings`, `general`, `updater`.
- Automatically captures file, function, and line information.
- Example from `Sources/AppDelegate.swift`:
```swift
Logger.log("Application did finish launching", log: Logger.general)
```

## Comments

**When to Comment:**
- Use of documentation comments for public/complex methods and classes.
- Use of `MARK:` to organize code sections.

**JSDoc/TSDoc:**
- Swift-style documentation comments (`///`) are used.
- Example from `Sources/Logger.swift`:
```swift
/// Log a message with the specified log type
/// - Parameters:
///   - message: The message to log
///   - log: The OSLog instance to use (defaults to general)
```

## Function Design

**Size:** Functions are generally concise and focused on a single responsibility.

**Parameters:** Use of named parameters and default values.

**Return Values:** Use of explicit return types or `Void` (implicit).

## Module Design

**Exports:** Types are generally internal or public within the module.

**Barrel Files:** Not applicable in Swift; the compiler handles module-wide visibility.

---

*Convention analysis: 2025-02-14*
