import Foundation

/// File-based diagnostic sink for user reports. Messages must not contain
/// transcript text, file contents, or other privacy-sensitive data.
enum DiagLog {
    private static let queue = DispatchQueue(label: "app.talix.scribe.diaglog", qos: .utility)
    private static let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Scribe/diagnostics.log")
    private static let privacyLogVersionKey = "scribeDiagLogPrivacyVersion"
    private static let currentPrivacyLogVersion = 1
    private static let sessionStarted: Void = {
        startSession()
    }()
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Trim on launch so the log cannot grow without bound.
    static func startSession() {
        queue.async {
            let defaults = UserDefaults.standard
            if defaults.integer(forKey: privacyLogVersionKey) < currentPrivacyLogVersion {
                if FileManager.default.fileExists(atPath: path.path) {
                    try? FileManager.default.removeItem(at: path)
                }
                if !FileManager.default.fileExists(atPath: path.path) {
                    defaults.set(currentPrivacyLogVersion, forKey: privacyLogVersionKey)
                }
            }

            let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
            if let size = attributes?[.size] as? Int, size > 5_000_000 {
                try? FileManager.default.removeItem(at: path)
            }
            write("=== Scribe session start (pid \(ProcessInfo.processInfo.processIdentifier)) ===")
        }
    }

    static func log(_ format: String, _ args: CVarArg...) {
        _ = sessionStarted
        let message = String(format: format, arguments: args)
        queue.async {
            NSLog("Scribe: %@", message)
            write(message)
        }
    }

    private static func write(_ message: String) {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(stamp.string(from: Date())) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: path, atomically: true, encoding: .utf8)
        }
    }
}
