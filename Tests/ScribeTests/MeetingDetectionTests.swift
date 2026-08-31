import XCTest
@testable import Scribe

final class MeetingDetectionTests: XCTestCase {
    func testExtractsConferenceURLsFromEachEventField() {
        XCTAssertEqual(
            MeetingDetector.firstConferenceURL(url: "https://zoom.us/j/12345", location: nil, notes: nil)?.host,
            "zoom.us"
        )
        XCTAssertEqual(
            MeetingDetector.firstConferenceURL(url: nil, location: "meet.google.com/abc-defg-hij", notes: nil)?.host,
            "meet.google.com"
        )
        XCTAssertEqual(
            MeetingDetector.firstConferenceURL(url: nil, location: nil, notes: "Join https://teams.microsoft.com/l/meetup-join/abc")?.host,
            "teams.microsoft.com"
        )
    }

    func testExtractsOtherSupportedProviders() {
        XCTAssertEqual(MeetingDetector.firstConferenceURL(in: ["https://teams.live.com/meet/123"])?.host, "teams.live.com")
        XCTAssertEqual(MeetingDetector.firstConferenceURL(in: ["https://acme.webex.com/meet/team"])?.host, "acme.webex.com")
        XCTAssertEqual(MeetingDetector.firstConferenceURL(in: ["facetime://person@example.com"])?.scheme, "facetime")
    }

    func testRejectsGarbageAndUsesFirstURL() {
        XCTAssertNil(MeetingDetector.firstConferenceURL(in: ["Call me at 555-0100", "https://example.com/call"]))
        XCTAssertEqual(
            MeetingDetector.firstConferenceURL(in: ["https://zoom.us/j/first https://meet.google.com/second"])?.host,
            "zoom.us"
        )
    }

    func testQualificationRules() {
        let link = URL(string: "https://zoom.us/j/123")
        XCTAssertTrue(MeetingDetector.qualifies(joinURL: link, attendeeCount: 0, onlyWithLinks: true))
        XCTAssertTrue(MeetingDetector.qualifies(joinURL: nil, attendeeCount: 2, onlyWithLinks: false))
        XCTAssertFalse(MeetingDetector.qualifies(joinURL: nil, attendeeCount: 1, onlyWithLinks: false))
        XCTAssertFalse(MeetingDetector.qualifies(joinURL: nil, attendeeCount: 4, onlyWithLinks: true))
    }
}
