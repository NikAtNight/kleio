import XCTest
@testable import Scribe

final class OutputRouteSettleTests: XCTestCase {
    func testWaitsForBluetoothRateSwitchAfterMicrophoneOpens() async {
        let a2dp = AudioDevices.OutputRoute(id: 7, sampleRate: 48_000, isBluetooth: true)
        let handsFree = AudioDevices.OutputRoute(id: 7, sampleRate: 24_000, isBluetooth: true)
        var reads = 0
        var readsAfterSwitch = 0
        await AudioDevices.waitForOutputRouteToSettle(
            quiet: .milliseconds(50), limit: .seconds(2), poll: .milliseconds(5)
        ) {
            reads += 1
            if reads <= 4 { return a2dp }
            readsAfterSwitch += 1
            return handsFree
        }
        // The rate switch arrived after startup and the wait kept going past it.
        XCTAssertGreaterThan(readsAfterSwitch, 1)
    }

    func testDoesNotWaitForWiredOutput() async {
        var reads = 0
        await AudioDevices.waitForOutputRouteToSettle(quiet: .seconds(10), limit: .seconds(10)) {
            reads += 1
            return AudioDevices.OutputRoute(id: 3, sampleRate: 48_000, isBluetooth: false)
        }
        XCTAssertEqual(reads, 1)
    }

    func testStopsAtLimitWhenRouteKeepsChanging() async {
        var rate: Float64 = 16_000
        let clock = ContinuousClock()
        let start = clock.now
        await AudioDevices.waitForOutputRouteToSettle(
            quiet: .seconds(10), limit: .milliseconds(100), poll: .milliseconds(5)
        ) {
            rate += 1
            return AudioDevices.OutputRoute(id: 7, sampleRate: rate, isBluetooth: true)
        }
        XCTAssertLessThan(clock.now - start, .seconds(2))
    }
}
