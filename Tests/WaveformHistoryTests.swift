import XCTest
import SwiftUI
@testable import WhisperClip

final class WaveformHistoryTests: XCTestCase {

    // MARK: - RT-01: Waveform color pipeline (label -> Speaker -> Color)

    func testMeLabelProducesVividBlue() {
        // Waveform stores "Me" label, converts via Speaker(displayName:), looks up color
        let speaker = Speaker(displayName: "Me")
        let color = speakerPaletteColor(speaker)
        XCTAssertEqual(color, Color(hex: "#4A9EFF"), "Me label must produce vivid blue through palette pipeline")
    }

    func testEmptyLabelProducesGray() {
        // Empty activeSpeakerLabel (idle state) -> .unknown -> .gray
        let speaker = Speaker(displayName: "")
        let color = speakerPaletteColor(speaker)
        XCTAssertEqual(color, Color.gray, "Empty label (idle) must produce gray through palette pipeline")
    }

    func testLabeledSpeakerProducesNonGrayColor() {
        // Diarized speaker label -> .labeled -> palette color (not gray)
        let speaker = Speaker(displayName: "Speaker 1")
        let color = speakerPaletteColor(speaker)
        XCTAssertNotEqual(color, Color.gray, "Labeled speaker must not produce gray")
    }

    func testColorHexParsingProducesExpectedValue() {
        // Verify the hex parser that backs the entire palette
        let blue = Color(hex: "#4A9EFF")
        let emerald = Color(hex: "#00C896")
        XCTAssertNotEqual(blue, emerald, "Different hex values must produce different colors")
    }

    func testDifferentSpeakersProduceDifferentColors() {
        // Two distinct speaker labels should not map to the same color
        let meColor = speakerPaletteColor(Speaker(displayName: "Me"))
        let sp1Color = speakerPaletteColor(Speaker(displayName: "Speaker 1"))
        XCTAssertNotEqual(meColor, sp1Color, "Me and Speaker 1 must have different waveform colors")
    }
}
