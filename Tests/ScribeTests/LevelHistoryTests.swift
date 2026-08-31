import XCTest
@testable import Scribe

final class LevelHistoryTests: XCTestCase {
    func testKeepsOnlyItsMostRecentCapacityOfSamples() {
        var history = LevelHistory(capacity: 3, minimumInterval: 0)

        for value in 1...5 {
            XCTAssertTrue(history.append(Float(value) / 10, at: TimeInterval(value)))
        }

        XCTAssertEqual(history.samples, [0.3, 0.4, 0.5])
    }

    func testIgnoresCallbacksInsideTheSamplingInterval() {
        var history = LevelHistory(capacity: 4, minimumInterval: 0.05)

        XCTAssertTrue(history.append(0.2, at: 10))
        XCTAssertFalse(history.append(0.8, at: 10.049))
        XCTAssertTrue(history.append(0.6, at: 10.05))

        XCTAssertEqual(history.samples, [0.2, 0.6])
    }

    func testResetClearsSamplesAndAllowsTheNextRecordingToSampleImmediately() {
        var history = LevelHistory(capacity: 3, minimumInterval: 0.05)
        XCTAssertTrue(history.append(0.4, at: 20))
        history.reset()

        XCTAssertEqual(history.samples, [])
        XCTAssertTrue(history.append(0.7, at: 20))
        XCTAssertEqual(history.samples, [0.7])
    }
}
