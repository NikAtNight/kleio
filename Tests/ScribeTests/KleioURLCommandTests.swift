import XCTest
@testable import Scribe

final class KleioURLCommandTests: XCTestCase {
    private func parse(_ string: String) -> KleioURLCommand? {
        KleioURLCommand.parse(URL(string: string)!)
    }

    func testRecordingCommandsParseWithModes() {
        XCTAssertEqual(parse("kleio://record/start?mode=meeting"), .startRecording(.meeting))
        XCTAssertEqual(parse("kleio://record/start?mode=mic"), .startRecording(.microphoneOnly))
        XCTAssertEqual(parse("kleio://record/start?mode=system"), .startRecording(.systemOnly))
        XCTAssertEqual(parse("kleio://record/start"), .startRecording(.meeting))
        XCTAssertEqual(parse("kleio://record/stop"), .stopRecording)
        XCTAssertEqual(parse("kleio://record/toggle?mode=mic"), .toggleRecording(.microphoneOnly))
        XCTAssertEqual(parse("KLEIO://Record/Toggle"), .toggleRecording(.meeting))
    }

    func testDictationAndOpenParse() {
        XCTAssertEqual(parse("kleio://dictation/toggle"), .toggleDictation)
        XCTAssertEqual(parse("kleio://open"), .open)
    }

    func testForeignAndMalformedURLsAreRejected() {
        XCTAssertNil(parse("https://record/start"))
        XCTAssertNil(parse("kleio://record/pause"))
        XCTAssertNil(parse("kleio://record"))
        XCTAssertNil(parse("kleio://record/start?mode=video"))
        XCTAssertNil(parse("file:///tmp/audio.m4a"))
    }
}
