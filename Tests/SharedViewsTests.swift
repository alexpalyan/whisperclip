import XCTest
@testable import WhisperClip

final class SharedViewsTests: XCTestCase {

    // MARK: - RT-02: Hex palette colors

    func testSpeakerPaletteColorReturnsHexBasedColor() {
        // Will be expanded in 09-01 to verify each palette index returns the correct hex color
        // Placeholder: verify function is callable
        let color = speakerPaletteColor(.me)
        XCTAssertNotNil(color)
    }
}
