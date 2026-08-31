import Foundation
import AVFoundation
import AudioToolbox

/// Records the default input device (microphone) to a CAF file, writing
/// progressively so a crash mid-recording loses nothing.
final class MicRecorder {
    enum MicError: LocalizedError {
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone."
            }
        }
    }

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private let paused = AtomicBool()

    private(set) var fileURL: URL?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(writingTo url: URL, onLevel: @escaping @Sendable (Float) -> Void) throws {
        fileURL = url
        let input = engine.inputNode
        configurePreferredInputDevice(for: input)
        let format = input.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        audioFile = file

        let pausedFlag = paused
        var levelCounter = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard !pausedFlag.value else { return }
            do {
                try file.write(from: buffer)
            } catch {
                NSLog("Scribe: mic write failed: %@", error.localizedDescription)
            }
            levelCounter += 1
            if levelCounter % 2 == 0 {
                onLevel(buffer.rmsLevel)
            }
        }

        engine.prepare()
        try engine.start()
    }

    private func configurePreferredInputDevice(for input: AVAudioInputNode) {
        let uid = UserDefaults.standard.string(forKey: "preferredInputDeviceUID") ?? ""
        let preferredDeviceID = uid.isEmpty ? nil : AudioDevices.deviceID(forUID: uid)
        guard let audioUnit = input.audioUnit,
              let deviceID = preferredDeviceID ?? AudioDevices.defaultInputDeviceID() else { return }

        guard setInputDevice(deviceID, on: audioUnit) != noErr,
              preferredDeviceID != nil,
              let defaultDeviceID = AudioDevices.defaultInputDeviceID() else { return }
        _ = setInputDevice(defaultDeviceID, on: audioUnit)
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on audioUnit: AudioUnit) -> OSStatus {
        var deviceID = deviceID
        return AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    var isPaused: Bool { paused.value }

    func setPaused(_ value: Bool) {
        paused.value = value
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
    }
}
