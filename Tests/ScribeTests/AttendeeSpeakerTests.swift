import XCTest
@testable import Scribe

final class AttendeeSpeakerTests: XCTestCase {
    func testFormatsLongNamesAndFiltersResourcesCurrentUserAndDuplicates() {
        let attendees = [
            CalendarAttendee(displayName: "Alexandra Katherine Montgomery", isResource: false, isCurrentUser: false),
            CalendarAttendee(displayName: "Alexandra Katherine Montgomery", isResource: false, isCurrentUser: false),
            CalendarAttendee(displayName: "Boardroom 4A", isResource: true, isCurrentUser: false),
            CalendarAttendee(displayName: "Nikhil Kapadia", isResource: false, isCurrentUser: true),
            CalendarAttendee(displayName: "Sam Lee", isResource: false, isCurrentUser: false),
        ]

        XCTAssertEqual(AttendeeNameFormatter.names(from: attendees), ["Alexandra M", "Sam Lee"])
    }

    func testAttendeeNamesAreCappedAtEight() {
        let attendees = (1...10).map {
            CalendarAttendee(displayName: "Person \($0)", isResource: false, isCurrentUser: false)
        }

        XCTAssertEqual(AttendeeNameFormatter.names(from: attendees), [
            "Person 1", "Person 2", "Person 3", "Person 4",
            "Person 5", "Person 6", "Person 7", "Person 8",
        ])
    }

    func testMergeKnownSpeakersPreservesExistingNamesDeduplicatesAndCaps() {
        let merged = TranscriptionQueue.mergedKnownSpeakers(
            ["Existing", "Sam Lee", "existing"],
            adding: ["Sam Lee", "Alexandra M", "Priya Shah", "Jordan Kim", "Riley Chen", "Morgan Yu", "Taylor Wu", "Casey Park"]
        )

        XCTAssertEqual(merged, [
            "Existing", "Sam Lee", "Alexandra M", "Priya Shah",
            "Jordan Kim", "Riley Chen", "Morgan Yu", "Taylor Wu",
        ])
    }
}
