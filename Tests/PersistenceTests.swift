import XCTest
@testable import WhisperClip

final class PersistenceTests: XCTestCase {
    // MUT-03: manual Codable preserves JSON structure; _$observationRegistrar
    // is NOT present in encoded output.
    func testMeetingSegmentRoundTrips() throws {
        let original = MeetingSegment(
            speaker: .labeled("Speaker 1"),
            text: "Hello world",
            startTime: 0.0,
            endTime: 5.0,
            confidence: 0.95,
            isPending: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeetingSegment.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.text, "Hello world")
        XCTAssertEqual(decoded.startTime, 0.0)
        XCTAssertFalse(decoded.isPending)
    }

    func testEncodedJSONHasNoObservationRegistrar() throws {
        let segment = MeetingSegment(speaker: .me, text: "test", startTime: 0, endTime: 1)
        let data = try JSONEncoder().encode(segment)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["_$observationRegistrar"], "Registrar must NOT appear in JSON")
        XCTAssertNil(json["__storage"], "Macro storage must NOT appear in JSON")
        XCTAssertNotNil(json["id"])
        XCTAssertNotNil(json["text"])
        XCTAssertNotNil(json["isPending"])
    }

    func testDecodesOldStructFormatWithoutError() throws {
        let oldJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "speaker": "Me",
            "text": "legacy segment",
            "startTime": 10.0,
            "endTime": 15.0,
            "confidence": 1.0
        }
        """.data(using: .utf8)!

        let segment = try JSONDecoder().decode(MeetingSegment.self, from: oldJSON)
        XCTAssertEqual(segment.text, "legacy segment")
        XCTAssertFalse(segment.isPending, "Old JSON without isPending must decode as not pending")
        XCTAssertEqual(segment.speaker, .me)
    }
}
