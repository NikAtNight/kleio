import SwiftUI
import AppKit
import UserNotifications

/// Entry point: `Scribe --transcribe <file> [model]` runs a headless
/// transcription (used by make-app.sh to pre-warm the CoreML cache and by
/// automated tests); anything else launches the app.
@main
enum Main {
    /// `--test-tap <logfile>`: start the system tap, capture for 5 s, then
    /// write diagnostics (callback count, format, bytes captured) and exit.
    /// Launch via `open -n -a Scribe --args --test-tap /path/log` so TCC
    /// attributes the audio-capture permission to Scribe itself.
    static func runTapTest(logPath: String) {
        var lines: [String] = []
        func logLine(_ s: String) {
            lines.append(s)
            try? lines.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
        let cafPath = logPath + ".caf"
        try? FileManager.default.removeItem(atPath: cafPath)
        let tap = SystemAudioTap()
        do {
            try tap.start(writingTo: URL(fileURLWithPath: cafPath)) { _ in }
            logLine("diag v3; start ok; tap format: \(tap.tapFormatDescription)")
        } catch {
            logLine("start FAILED: \(error.localizedDescription)")
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            tap.stop()
            let bytes = (try? FileManager.default.attributesOfItem(atPath: cafPath)[.size] as? Int) ?? 0
            logLine("callbacks: \(tap.callbackCount.value)")
            logLine("firstBuffer: \(tap.firstBufferDescription)")
            logLine("conversionFailures: \(tap.conversionFailures.value)")
            logLine("writesOK: \(tap.writesOK.value)")
            logLine("firstWriteError: \(tap.firstWriteError)")
            logLine("bytes: \(bytes)")
            logLine("done")
            exit(0)
        }
        RunLoop.main.run()
    }

    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--test-tap"), args.count > i + 1 {
            runTapTest(logPath: args[i + 1])
            return
        }
        if args.count >= 3, args[1] == "--transcribe" {
            let model = args.count > 3 ? args[3]
                : UserDefaults.standard.string(forKey: "selectedModel") ?? "openai_whisper-small.en"
            // Keep the main run loop free — WhisperKit hops to the main
            // actor internally, so blocking main (semaphore) deadlocks.
            Task.detached {
                do {
                    ModelManager.seedFromLocalFlowIfAvailable()
                    let transcriber = Transcriber()
                    try await transcriber.load(model: model)
                    let segments = try await transcriber.transcribe(
                        file: URL(fileURLWithPath: args[2]),
                        source: .imported, language: nil, translate: false
                    )
                    for segment in segments {
                        print("[\(segment.start.clockString) → \(segment.end.clockString)] \(segment.text)")
                    }
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            RunLoop.main.run()
        }
        ScribeApp.main()
    }
}

/// Cross-scene UI state (sidebar selection, importer visibility) shared by
/// the main window and the menu bar extra.
@MainActor
final class AppState: ObservableObject {
    enum ImportMode { case files, podcast }

    @Published var selection: UUID?
    @Published var showImporter = false
    @Published var importMode: ImportMode = .files

    func presentImporter(_ mode: ImportMode = .files) {
        importMode = mode
        showImporter = true
    }
}

struct ScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var library = LibraryStore()
    @StateObject private var modelManager = ModelManager()
    @StateObject private var queue = TranscriptionQueue()
    @StateObject private var recording = RecordingSession()
    @StateObject private var appState = AppState()
    @StateObject private var replacementStore = ReplacementStore()
    @StateObject private var watchFolders = WatchFolderManager()
    @StateObject private var dictation = DictationController()
    @StateObject private var calendarSync = CalendarSync()

    var body: some Scene {
        WindowGroup("Scribe", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(modelManager)
                .environmentObject(queue)
                .environmentObject(recording)
                .environmentObject(appState)
                .environmentObject(replacementStore)
                .environmentObject(watchFolders)
                .environmentObject(dictation)
                .environmentObject(calendarSync)
                .onAppear {
                    queue.configure(
                        library: library,
                        modelManager: modelManager,
                        replacementStore: replacementStore
                    )
                    watchFolders.configure(library: library, queue: queue)
                    dictation.configure(
                        modelManager: modelManager,
                        replacements: replacementStore,
                        recordingSession: recording
                    )
                    appDelegate.onOpenFiles = { urls in
                        let ids = Importer.importFiles(urls, library: library, queue: queue)
                        if let first = ids.first { appState.selection = first }
                    }
                    appDelegate.calendarSync = calendarSync
                    calendarSync.start()
                }
                .frame(minWidth: 940, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 720)
        .defaultLaunchBehavior(.presented)
        // File-open events are handled by the AppDelegate; don't let SwiftUI
        // spawn an extra window per opened file.
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Audio File…") { appState.presentImporter(.files) }
                    .keyboardShortcut("o")
                Button("Open Podcast Speaker Tracks…") { appState.presentImporter(.podcast) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(library)
                .environmentObject(queue)
                .environmentObject(recording)
                .environmentObject(appState)
                .environmentObject(dictation)
                .environmentObject(calendarSync)
        } label: {
            Image(systemName: recording.isRecording
                  ? "record.circle.fill"
                  : (dictation.phase == .recording ? "mic.circle.fill" : "waveform"))
        }

        Settings {
            SettingsView()
                .environmentObject(modelManager)
                .environmentObject(replacementStore)
                .environmentObject(watchFolders)
                .environmentObject(dictation)
                .environmentObject(calendarSync)
        }
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set once by ScribeApp; a direct callback (not a notification) so
    /// files import exactly once no matter how many windows exist.
    var onOpenFiles: (([URL]) -> Void)?
    weak var calendarSync: CalendarSync?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Bundle.main.bundleURL.pathExtension == "app" {
            let center = UNUserNotificationCenter.current()
            let join = UNNotificationAction(identifier: "MEETING_JOIN", title: "Join", options: [.foreground])
            let openScribe = UNNotificationAction(identifier: "MEETING_OPEN_SCRIBE", title: "Open Scribe", options: [.foreground])
            center.setNotificationCategories([UNNotificationCategory(
                identifier: "MEETING_START",
                actions: [join, openScribe],
                intentIdentifiers: []
            )])
            center.delegate = self
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        onOpenFiles?(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running for the menu bar quick-recorder.
        false
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == "MEETING_JOIN" {
            await MainActor.run {
                calendarSync?.handleNotificationAction(identifier: response.actionIdentifier, userInfo: response.notification.request.content.userInfo)
            }
        } else if response.actionIdentifier == "MEETING_OPEN_SCRIBE" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

}
