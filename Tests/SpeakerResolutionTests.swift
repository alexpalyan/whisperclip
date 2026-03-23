import XCTest
@testable import WhisperClip

final class SpeakerResolutionTests: XCTestCase {

    // MARK: - RT-03: Speaker display name resolution

    func testMeDisplayName() {
        let speaker = Speaker(displayName: "Me")
        XCTAssertEqual(speaker, .me, "'Me' must map to .me")
    }

    func testOtherDisplayName() {
        let speaker = Speaker(displayName: "Other")
        XCTAssertEqual(speaker, .other, "'Other' must map to .other")
    }

    func testEmptyStringMapsToUnknown() {
        let speaker = Speaker(displayName: "")
        XCTAssertEqual(speaker, .unknown, "Empty string must map to .unknown")
    }

    func testUnknownStringMapsToUnknown() {
        let speaker = Speaker(displayName: "Unknown")
        XCTAssertEqual(speaker, .unknown, "'Unknown' must map to .unknown")
    }

    func testLabeledSpeakerPreservesName() {
        let speaker = Speaker(displayName: "Speaker 1")
        XCTAssertEqual(speaker, .labeled("Speaker 1"), "'Speaker 1' must map to .labeled(\"Speaker 1\")")
    }

    func testArbitrarySpeakerLabelPreserved() {
        let speaker = Speaker(displayName: "Alice")
        XCTAssertEqual(speaker, .labeled("Alice"), "Arbitrary name must map to .labeled")
    }

    func testDisplayNameRoundTrip() {
        // Verify displayName -> Speaker -> displayName is stable
        let names = ["Me", "Other", "Unknown", "Speaker 1", "Speaker 2"]
        for name in names {
            let speaker = Speaker(displayName: name)
            XCTAssertEqual(speaker.displayName, name, "Round-trip failed for '\(name)'")
        }
    }
}
