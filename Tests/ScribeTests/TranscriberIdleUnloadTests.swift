import XCTest
@testable import Scribe

/// Uses the real Parakeet v3 model when this Mac has it, since unloading only
/// means something for a loaded model. Skips elsewhere.
final class TranscriberIdleUnloadTests: XCTestCase {
    private let model = "parakeet-tdt-0.6b-v3"

    func testIdleModelIsReleasedAndReloadsOnNextUse() async throws {
        try XCTSkipUnless(ParakeetTranscriber.isDownloaded(model), "Parakeet v3 isn't downloaded on this Mac")
        let transcriber = Transcriber(idleDelay: { 0.3 })
        try await transcriber.load(model: model)
        let loaded = await transcriber.isLoaded
        XCTAssertTrue(loaded)

        try await Task.sleep(for: .seconds(1.5))
        let unloaded = await transcriber.isLoaded
        let loadedModel = await transcriber.loadedModel
        XCTAssertFalse(unloaded)
        XCTAssertNil(loadedModel)

        try await transcriber.load(model: model)
        let reloaded = await transcriber.isLoaded
        XCTAssertTrue(reloaded)
    }

    func testNeverSettingKeepsTheModelLoaded() async throws {
        try XCTSkipUnless(ParakeetTranscriber.isDownloaded(model), "Parakeet v3 isn't downloaded on this Mac")
        let transcriber = Transcriber(idleDelay: { nil })
        try await transcriber.load(model: model)
        try await Task.sleep(for: .seconds(1))
        let loaded = await transcriber.isLoaded
        XCTAssertTrue(loaded)
    }
}
