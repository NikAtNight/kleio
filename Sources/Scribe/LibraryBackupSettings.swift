import SwiftUI
import AppKit

struct LibraryBackupSettings: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var summaries: SummaryJobs
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var backups: LibraryBackupJobs
    private var busy: Bool { recording.isBusy || library.hasPendingRecordingSaves || queue.isBusy || summaries.isBusy || dictation.phase != .idle }

    var body: some View {
        Section("Backup and restore") {
            HStack {
                Button("Back Up Library…", action: chooseBackupDestination)
                Button("Restore Backup…", action: chooseRestore)
                if backups.isWorking { ProgressView().controlSize(.small) }
            }
            .disabled(backups.isWorking || busy)
            Text(busy ? "Finish recording, processing, and pending saves before backing up or restoring."
                 : "Includes recordings, video, transcripts, notes, saved people, and local preferences. Models and credentials stay separate.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = backups.message { Text(message).font(.caption).textSelection(.enabled) }
        }
        .alert("Backup or restore couldn't finish", isPresented: Binding(get: { backups.error != nil }, set: { if !$0 { backups.dismissError() } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(backups.error ?? "") }
    }

    private func chooseBackupDestination() {
        guard !busy, !backups.isWorking else { return }
        let panel = NSSavePanel()
        panel.title = "Back up your library"
        panel.nameFieldStringValue = "Kleio \(Date().formatted(.iso8601.year().month().day())).kleiobackup"
        panel.prompt = "Back Up"
        guard panel.runModal() == .OK, let destination = panel.url, !busy else { return }
        let preferences = LibraryBackup.selectedPreferences(UserDefaults.standard.persistentDomain(forName: "app.talix.scribe") ?? [:])
        backups.backUp(support: LibraryBackup.supportURL, preferences: preferences, to: destination) { saved in
            NSWorkspace.shared.activateFileViewerSelecting([saved])
        }
    }

    private func chooseRestore() {
        guard !busy, !backups.isWorking else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Kleio backup folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Review Backup"
        guard panel.runModal() == .OK, let backup = panel.url else { return }
        backups.restoreNextLaunch(from: backup, support: LibraryBackup.supportURL, canRestore: { !busy }) { manifest in
            let alert = NSAlert()
            alert.messageText = "Restore \(manifest.recordingCount) recordings on next launch?"
            alert.informativeText = "This replaces the current library and local preferences when you reopen Kleio. Your current library will be kept in Kleio's Backups folder. Models and credentials stay unchanged. Keep the backup folder in its current location until restore finishes."
            alert.addButton(withTitle: "Restore on Next Launch")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}
