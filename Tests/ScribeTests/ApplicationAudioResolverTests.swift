import XCTest
@testable import Scribe

final class ApplicationAudioResolverTests: XCTestCase {
    func testIncludesBrowserHelpersAndExcludesOtherApplications() throws {
        let browser = RecordingApplication(bundleID: "com.browser", name: "Browser")
        let processes = [
            AudioCaptureProcess(objectID: 10, bundleID: "com.browser", bundlePath: nil),
            AudioCaptureProcess(objectID: 11, bundleID: "com.browser.helper", bundlePath: nil),
            AudioCaptureProcess(objectID: 12, bundleID: "audio.helper", bundlePath: "/Apps/Browser.app/Contents/Frameworks/Audio.app"),
            AudioCaptureProcess(objectID: 13, bundleID: "com.browserOther", bundlePath: nil),
            AudioCaptureProcess(objectID: 14, bundleID: "com.other", bundlePath: "/Apps/Browser.app.copy/Contents/App.app"),
            AudioCaptureProcess(objectID: 15, bundleID: "com.browser.beta", bundlePath: "/Apps/Browser Beta.app"),
            AudioCaptureProcess(objectID: 16, bundleID: "com.browser.helper", bundlePath: "/Apps/Other.app/Contents/Helper.app")
        ]
        XCTAssertEqual(try ApplicationAudioResolver.resolve(browser, bundlePath: "/Apps/Browser.app", processes: processes), [10, 11, 12])
        XCTAssertThrowsError(try ApplicationAudioResolver.resolve(browser, bundlePath: nil, processes: [processes[3]]))
        XCTAssertEqual(try ApplicationAudioResolver.resolve(browser, bundlePath: nil, processes: [
            AudioCaptureProcess(objectID: 99, bundleID: "com.browser", bundlePath: nil)
        ]), [99])
    }
}
