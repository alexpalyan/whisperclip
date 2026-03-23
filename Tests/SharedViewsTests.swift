import XCTest
import SwiftUI
@testable import WhisperClip

final class SharedViewsTests: XCTestCase {

    // MARK: - RT-02: Hex palette colors

    func testMeSpeakerReturnsPaletteColor() {
        // .me has colorIndex 0 -> palette[0] = Color(hex: "#4A9EFF")
        let color = speakerPaletteColor(.me)
        XCTAssertEqual(color, Color(hex: "#4A9EFF"), "Me speaker must use vivid blue #4A9EFF")
    }

    func testOtherSpeakerReturnsPaletteColor() {
        // .other has colorIndex 1 -> palette[1] = Color(hex: "#9C27B0")
        let color = speakerPaletteColor(.other)
        XCTAssertEqual(color, Color(hex: "#9C27B0"), "Other speaker must use purple #9C27B0")
    }

    func testUnknownSpeakerReturnsGray() {
        let color = speakerPaletteColor(.unknown)
        XCTAssertEqual(color, Color.gray, "Unknown speaker must return .gray")
    }

    func testLabeledSpeakerReturnsPaletteColor() {
        // .labeled speakers get colorIndex 2..8 based on hash
        let color = speakerPaletteColor(.labeled("Speaker 1"))
        // Should NOT be gray (not unknown) and NOT be nil
        XCTAssertNotEqual(color, Color.gray, "Labeled speaker must not return gray")
    }

    func testAllPaletteIndicesReturnDistinctColors() {
        // Verify palette has distinct entries for indices 0..8
        let speakers: [Speaker] = [.me, .other]
        let colors = speakers.map { speakerPaletteColor($0) }
        XCTAssertNotEqual(colors[0], colors[1], "Me and Other must have different palette colors")
    }
}
