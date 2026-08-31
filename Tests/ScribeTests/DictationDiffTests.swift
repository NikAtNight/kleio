import XCTest
@testable import Scribe

final class DictationDiffTests: XCTestCase {
    func testLearnsASingleMisheardWord() {
        let proposals = DictationDiff.proposedCorrections(
            original: "I pushed the change to talex today",
            edited: "I pushed the change to Talix today"
        )

        XCTAssertEqual(proposals.map(\.wrong), ["talex"])
        XCTAssertEqual(proposals.map(\.right), ["Talix"])
    }

    func testLearnsSeveralFixesInOnePass() {
        let proposals = DictationDiff.proposedCorrections(
            original: "deploy kubernets from get hub actions",
            edited: "deploy kubernetes from github actions"
        )

        XCTAssertEqual(proposals.map(\.wrong), ["kubernets", "get"])
        XCTAssertEqual(proposals.map(\.right), ["kubernetes", "github"])
    }

    func testIgnoresCommonWordsAndFormattingOnlyEdits() {
        XCTAssertTrue(DictationDiff.proposedCorrections(
            original: "send the report to finance",
            edited: "send a report to finance"
        ).isEmpty)
        XCTAssertTrue(DictationDiff.proposedCorrections(
            original: "shipped the release",
            edited: "Shipped the release."
        ).isEmpty)
    }

    func testIgnoresInsertionsAndEmptyInput() {
        XCTAssertTrue(DictationDiff.proposedCorrections(
            original: "ship the feature",
            edited: "ship the whole feature"
        ).isEmpty)
        XCTAssertTrue(DictationDiff.proposedCorrections(original: "", edited: "anything").isEmpty)
    }

    func testDeduplicatesRepeatedMishearings() {
        let proposals = DictationDiff.proposedCorrections(
            original: "talex and talex again",
            edited: "Talix and Talix again"
        )

        XCTAssertEqual(proposals.count, 1)
    }
}
