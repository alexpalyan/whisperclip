import XCTest
@testable import WhisperClip

final class SpeakerResolutionTests: XCTestCase {

    // MARK: - RT-03: Speaker display name resolution

    func testSpeakerDisplayNameResolution() {
        // Will be expanded in 09-01 to verify:
        // - "Me" -> .me
        // - "" -> .unknown
        // - "Speaker 1" -> .labeled("Speaker 1")
        // Placeholder: verify enum case construction
        let speaker = Speaker.me
        XCTAssertEqual(speaker.displayName, "Me")
    }
}
