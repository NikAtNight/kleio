import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Core Audio HAL queries for microphones and the output that anchors app-audio capture.
enum AudioDevices {
    static let preferredOutputDeviceUIDKey = "preferredOutputDeviceUID"

    static func inputDevices() -> [AudioDevice] {
        devices(withStreamsIn: kAudioDevicePropertyScopeInput)
    }

    /// Outputs with no input streams. A device that mixes microphone and
    /// app-audio streams cannot anchor app capture safely.
    static func outputDevices() -> [AudioDevice] {
        devices(withStreamsIn: kAudioDevicePropertyScopeOutput).filter { !hasStreams($0.id, scope: kAudioDevicePropertyScopeInput) }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    /// The output chosen in Kleio when it is connected, otherwise the macOS default output.
    static func recordingOutputDeviceID() -> AudioDeviceID? {
        let preferredUID = UserDefaults.standard.string(forKey: preferredOutputDeviceUIDKey) ?? ""
        if !preferredUID.isEmpty, let device = outputDevices().first(where: { $0.uid == preferredUID }) {
            return device.id
        }
        return defaultOutputDeviceID()
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return result == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return result == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func defaultInputDeviceUID() -> String? {
        defaultInputDeviceID().flatMap { stringProperty($0, kAudioDevicePropertyDeviceUID) }
    }

    struct OutputRoute: Equatable {
        let id: AudioDeviceID
        let sampleRate: Float64
        let isBluetooth: Bool
    }

    static func recordingOutputRoute() -> OutputRoute? {
        guard let id = recordingOutputDeviceID() else { return nil }
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return nil }
        let transport = transportType(id)
        return OutputRoute(id: id, sampleRate: rate,
            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
    }

    /// A Bluetooth headset switches its output to a lower call rate a moment
    /// after its microphone opens. Waits until the recording output has stopped
    /// changing so app capture does not start on the rate that is about to go away.
    static func waitForOutputRouteToSettle(
        quiet: Duration = .milliseconds(1500),
        limit: Duration = .seconds(4),
        poll: Duration = .milliseconds(100),
        read: () -> OutputRoute? = recordingOutputRoute
    ) async {
        guard var route = read(), route.isBluetooth else { return }
        let clock = ContinuousClock()
        let start = clock.now
        var lastChange = start
        while clock.now - lastChange < quiet, clock.now - start < limit {
            try? await Task.sleep(for: poll)
            if Task.isCancelled { return }
            let current = read()
            if current != route {
                guard let current else { return }
                route = current
                lastChange = clock.now
            }
        }
    }

    nonisolated(unsafe) private static var changeCoalescer: DispatchWorkItem?
    nonisolated(unsafe) private static var deviceChangeHandler: (() -> Void)?
    nonisolated(unsafe) private static var isObservingDeviceChanges = false

    /// Calls `handler` on the main queue when a default device or the device list changes.
    /// The Core Audio notifications arrive in bursts, so they are coalesced briefly.
    static func observeDeviceChanges(_ handler: @escaping () -> Void) {
        deviceChangeHandler = handler
        guard !isObservingDeviceChanges else { return }
        isObservingDeviceChanges = true

        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
        ]
        for selector in selectors {
            var address = address(selector)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
            ) { _, _ in
                changeCoalescer?.cancel()
                let work = DispatchWorkItem { deviceChangeHandler?() }
                changeCoalescer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func devices(withStreamsIn scope: AudioObjectPropertyScope) -> [AudioDevice] {
        allDeviceIDs().compactMap { id in
            guard hasStreams(id, scope: scope),
                  transportType(id) != kAudioDeviceTransportTypeAggregate,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    private static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let result = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard result == noErr, let value else { return nil }
        return value as String
    }
}
