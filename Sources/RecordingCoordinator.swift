import Foundation

/// Tracks which recording mode is currently active.
/// Used to enforce mutual exclusion between mic and meeting hotkeys:
/// pressing a hotkey while the *other* mode is active stops it and does NOT start the new mode.
enum ActiveRecording {
    case none
    case microphone
    case meeting
}

@MainActor
final class RecordingCoordinator {
    static let shared = RecordingCoordinator()
    private(set) var active: ActiveRecording = .none

    private init() {}

    func didStartMicrophone() { active = .microphone }
    func didStartMeeting()    { active = .meeting }
    func didStop()            { active = .none }
}
