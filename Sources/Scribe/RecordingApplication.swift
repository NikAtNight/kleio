import AppKit
import CoreAudio

struct RecordingApplication: Identifiable, Hashable, Codable {
    var bundleID: String
    var name: String
    var id: String { bundleID }

    @MainActor
    static func runningApplications() -> [Self] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier else { return nil }
            return Self(bundleID: id, name: app.localizedName ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct AudioCaptureProcess: Equatable {
    var objectID: AudioObjectID
    var bundleID: String
    var bundlePath: String?
}

enum ApplicationAudioResolver {
    enum ResolutionError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let name):
                return "No audio source is available for \(name). Open the app and join the call, then try again."
            }
        }
    }

    /// Match the application and its bundled helpers without including another browser.
    static func resolve(_ app: RecordingApplication, bundlePath: String?, processes: [AudioCaptureProcess]) throws -> [AudioObjectID] {
        let matches = processes.filter { process in
            let bundledHelper = bundlePath.map { path in process.bundlePath?.hasPrefix(path + "/Contents/") == true } ?? false
            let helperID = app.bundleID + ".helper"
            let pathlessHelper = process.bundlePath == nil &&
                (process.bundleID.caseInsensitiveCompare(helperID) == .orderedSame ||
                    process.bundleID.lowercased().hasPrefix(helperID.lowercased() + "."))
            return process.bundleID == app.bundleID || bundledHelper || pathlessHelper
        }.map(\.objectID)
        guard !matches.isEmpty else { throw ResolutionError.unavailable(app.name) }
        return Array(Set(matches)).sorted()
    }

    @MainActor
    static func resolve(_ app: RecordingApplication) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            throw ResolutionError.unavailable(app.name)
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            throw ResolutionError.unavailable(app.name)
        }
        let processes = ids.map { id -> AudioCaptureProcess in
            address.mSelector = kAudioProcessPropertyBundleID
            var bundle: CFString = "" as CFString
            size = UInt32(MemoryLayout<CFString>.size)
            _ = withUnsafeMutablePointer(to: &bundle) {
                AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
            }
            address.mSelector = kAudioProcessPropertyPID
            var pid: pid_t = 0
            size = UInt32(MemoryLayout<pid_t>.size)
            _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pid)
            return AudioCaptureProcess(objectID: id, bundleID: bundle as String,
                bundlePath: NSRunningApplication(processIdentifier: pid)?.bundleURL?.path)
        }
        let bundlePath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)?.path
        return try resolve(app, bundlePath: bundlePath, processes: processes)
    }
}
