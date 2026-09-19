import SwiftUI
import AppKit
import UserNotifications

/// Entry point: `Kleio --transcribe <file> [model]` runs a headless
/// transcription (used by make-app.sh to pre-warm the CoreML cache and by
/// automated tests); anything else launches the app.
@main
enum Main {
    /// `--test-tap <logfile>`: start the system tap, capture for 5 s, then
    /// write diagnostics (callback count, format, bytes captured) and exit.
    /// Launch via `open -n -a Kleio --args --test-tap /path/log` so TCC
    /// attributes the audio-capture permission to Kleio itself.
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
        if args.dropFirst().first == "--package-self-check" {
            do {
                guard Bundle.main.bundleIdentifier == "app.talix.scribe",
                      let resources = Bundle.main.resourceURL else {
                    throw NSError(domain: "Kleio.Package", code: 1, userInfo: [NSLocalizedDescriptionKey: "The app bundle could not be located."])
                }
                // Resolved through Bundle, as Hub does, so flat and Contents/Resources layouts both pass.
                guard let hub = Bundle(url: resources.appendingPathComponent("swift-transformers_Hub.bundle")) else {
                    throw NSError(domain: "Kleio.Package", code: 2, userInfo: [NSLocalizedDescriptionKey: "The Hub resource bundle could not be opened."])
                }
                for name in ["gpt2_tokenizer_config", "t5_tokenizer_config"] {
                    guard let url = hub.url(forResource: name, withExtension: "json") else {
                        throw NSError(domain: "Kleio.Package", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(name).json is missing from the Hub bundle."])
                    }
                    _ = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
                }
                print("Packaged resources are readable from the running app.")
                return
            } catch {
                FileHandle.standardError.write(Data("Package check failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        if args.dropFirst().first == "--benchmark-speakers" {
            Task.detached {
                do {
                    try await SpeakerBenchmark.run(arguments: Array(args.dropFirst(2)))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }
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
        do {
            try LibraryBackup.restoreOnLaunch(support: LibraryBackup.supportURL, defaults: .standard, domain: "app.talix.scribe")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Library restore couldn't finish"
            alert.informativeText = error.localizedDescription + " Quit and reopen Kleio after checking the backup location and available disk space."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            return
        }
        ScribeApp.main()
    }
}

/// Cross-scene UI state (sidebar selection, importer visibility) shared by
/// the main window and the menu bar extra.
enum MainSelection: Hashable {
    case home
    case document(UUID)
    case meeting(String)
}

@MainActor
final class AppState: ObservableObject {
    enum ImportMode { case files, podcast }

    @Published var selection: MainSelection = .home
    @Published var showImporter = false
    @Published var importMode: ImportMode = .files

    var selectedDocumentID: UUID? {
        guard case .document(let id) = selection else { return nil }
        return id
    }

    func select(document id: UUID) {
        selection = .document(id)
    }

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
    @StateObject private var summaries = SummaryJobs()
    @StateObject private var backups = LibraryBackupJobs()
    @StateObject private var recording = RecordingSession()
    @StateObject private var appState = AppState()
    @StateObject private var replacementStore = ReplacementStore()
    @StateObject private var watchFolders = WatchFolderManager()
    @StateObject private var dictation = DictationController()
    @StateObject private var calendarSync = CalendarSync()
    @StateObject private var autoRecordArbiter = AutoRecordArbiter()

    var body: some Scene {
        WindowGroup("Kleio", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(modelManager)
                .environmentObject(queue)
                .environmentObject(summaries)
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
                        replacementStore: replacementStore,
                        attendeeNamesProvider: calendarSync.attendeeNames(forEventID:)
                    )
                    summaries.configure(library: library)
                    watchFolders.configure(library: library, queue: queue)
                    dictation.configure(
                        modelManager: modelManager,
                        replacements: replacementStore,
                        recordingSession: recording
                    )
                    appDelegate.onOpenFiles = { urls in
                        let ids = Importer.importFiles(urls, library: library, queue: queue)
                        if let first = ids.first { appState.select(document: first) }
                    }
                    appDelegate.onCommandURL = { command in
                        KleioURLCommandHandler(recording: recording, library: library, queue: queue,
                                               dictation: dictation, appState: appState).handle(command)
                    }
                    appDelegate.hasBackgroundWork = { queue.isBusy || summaries.isBusy || backups.isWorking }
                    appDelegate.recording = recording
                    appDelegate.finishRecording = {
                        await recording.prepareToQuit(library: library, queue: queue)
                        let transcriptSaved = await queue.prepareToQuit()
                        let summariesSaved = await summaries.prepareToQuit()
                        let backupFinished = await backups.prepareToQuit()
                        return !recording.isBusy && !queue.isBusy && !summaries.isBusy && !backups.isWorking
                            && transcriptSaved && summariesSaved && backupFinished
                    }
                    appDelegate.calendarSync = calendarSync
                    appDelegate.autoRecordArbiter = autoRecordArbiter
                    calendarSync.start()
                    autoRecordArbiter.configure(
                        calendarSync: calendarSync,
                        recording: recording,
                        library: library,
                        queue: queue
                    )
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
                .environmentObject(summaries)
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
                .environmentObject(backups)
                .environmentObject(library)
                .environmentObject(recording)
                .environmentObject(queue)
                .environmentObject(summaries)
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
    var onCommandURL: ((KleioURLCommand) -> Void)?
    weak var calendarSync: CalendarSync?
    weak var autoRecordArbiter: AutoRecordArbiter?
    weak var recording: RecordingSession?
    var finishRecording: (() async -> Bool)?
    var hasBackgroundWork: (() -> Bool)?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recording?.isBusy == true || hasBackgroundWork?() == true else {
            return .terminateNow
        }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            let saved = await finishRecording?() ?? false
            if !saved {
                terminating = false
                let alert = NSAlert()
                alert.messageText = "Kleio still has work to save"
                alert.informativeText = "Quit was cancelled because recording, processing, or a backup still needs attention. Resolve the error, then quit again."
                alert.addButton(withTitle: "Keep Open")
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Bundle.main.bundleURL.pathExtension == "app" {
            let center = UNUserNotificationCenter.current()
            let join = UNNotificationAction(identifier: "MEETING_JOIN", title: "Join", options: [.foreground])
            let openScribe = UNNotificationAction(identifier: "MEETING_OPEN_SCRIBE", title: "Open Kleio", options: [.foreground])
            let cancelAutoRecord = UNNotificationAction(
                identifier: AutoRecordArbiter.cancelActionIdentifier,
                title: "Cancel",
                options: []
            )
            let startAutoRecord = UNNotificationAction(
                identifier: AutoRecordArbiter.startNowActionIdentifier,
                title: "Start Now",
                options: [.foreground]
            )
            let stopAndSwitch = UNNotificationAction(
                identifier: AutoRecordArbiter.stopAndSwitchActionIdentifier,
                title: "Stop and Switch",
                options: [.foreground]
            )
            let keepCurrent = UNNotificationAction(
                identifier: AutoRecordArbiter.keepCurrentActionIdentifier,
                title: "Keep Current",
                options: []
            )
            center.setNotificationCategories([UNNotificationCategory(
                identifier: "MEETING_START",
                actions: [join, openScribe],
                intentIdentifiers: []
            ), UNNotificationCategory(
                identifier: AutoRecordArbiter.countdownCategoryIdentifier,
                actions: [cancelAutoRecord, startAutoRecord],
                intentIdentifiers: []
            ), UNNotificationCategory(
                identifier: AutoRecordArbiter.overlapCategoryIdentifier,
                actions: [stopAndSwitch, keepCurrent],
                intentIdentifiers: []
            )])
            center.delegate = self
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            if let command = KleioURLCommand.parse(url) {
                onCommandURL?(command)
            } else if url.isFileURL {
                files.append(url)
            }
        }
        if !files.isEmpty { onOpenFiles?(files) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running for the menu bar quick-recorder.
        false
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == AutoRecordArbiter.cancelActionIdentifier ||
            response.actionIdentifier == AutoRecordArbiter.startNowActionIdentifier ||
            response.actionIdentifier == AutoRecordArbiter.stopAndSwitchActionIdentifier ||
            response.actionIdentifier == AutoRecordArbiter.keepCurrentActionIdentifier {
            await MainActor.run {
                autoRecordArbiter?.handleNotificationAction(
                    identifier: response.actionIdentifier,
                    userInfo: response.notification.request.content.userInfo
                )
            }
        } else if response.actionIdentifier == "MEETING_JOIN" {
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
