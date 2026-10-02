import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var importer: Importer
    @StateObject private var playback = PlaybackController()

    @State private var searchText = ""
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView(searchText: $searchText)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    if importer.isBusy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Importing files, \(importer.completedFiles) of \(importer.totalFiles) finished")
                            Spacer()
                        }
                        .font(.callout).padding(12).background(.bar)
                    }
                    DocumentJobStatusView()
                    if recording.isRecording || recording.isFinalizing || recording.hasPendingSave {
                        RecordingStatusBar()
                    }
                }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search transcripts")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                RecordMenu()
                Menu {
                    Button {
                        appState.presentImporter(.files)
                    } label: {
                        Label("Audio or Video Files…", systemImage: "waveform")
                    }
                    Button {
                        appState.presentImporter(.podcast)
                    } label: {
                        Label("Podcast Speaker Tracks…", systemImage: "person.2.wave.2")
                    }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Transcribe an audio or video file (⌘O)")
            }
        }
        .fileImporter(
            isPresented: $appState.showImporter,
            allowedContentTypes: Importer.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                let mode = appState.importMode
                Task {
                    switch mode {
                    case .files:
                        let ids = await importer.importFiles(urls, library: library, queue: queue)
                        if let first = ids.first { appState.select(document: first) }
                    case .podcast:
                        if let id = await importer.importPodcast(urls, library: library, queue: queue) {
                            appState.select(document: id)
                        }
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if dropTargeted {
                DropOverlay()
            }
        }
        .environmentObject(playback)
        .alert("Library Problem", isPresented: Binding(
            get: { library.lastError != nil },
            set: { if !$0 { library.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.lastError ?? "")
        }
        .alert("Recording Problem", isPresented: recordingErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recording.lastError ?? "")
        }
        .alert("Import Problem", isPresented: Binding(
            get: { !importer.errors.isEmpty },
            set: { if !$0 { importer.dismissErrors() } }
        )) {
            Button("OK", role: .cancel) { importer.dismissErrors() }
        } message: {
            Text(importer.errors.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection {
            case .home:
                HomeView()
                    .background(Theme.paperBackground)
            case .document(let id):
                if let document = library.document(id: id) {
                    DocumentDetailView(document: document)
                        .id(document.id)
                        .background(Theme.paperBackground)
                } else {
                    HomeView()
                        .background(Theme.paperBackground)
                }
            case .meeting(let id):
                MeetingDetailView(meetingID: id)
        }
    }

    private var recordingErrorBinding: Binding<Bool> {
        Binding(
            get: { recording.lastError != nil },
            set: { if !$0 { recording.lastError = nil } }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in files {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url { urls.append(url) }
            }
            let ids = await importer.importFiles(urls, library: library, queue: queue)
            if let first = ids.first { appState.select(document: first) }
        }
        return true
    }
}

/// The red Record button + mode menu in the toolbar.
struct RecordMenu: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if recording.isRecording {
            Button {
                let id = recording.activeDocumentID
                recording.stop(library: library, queue: queue)
                if let id { appState.select(document: id) }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Stop recording and transcribe")
            .disabled(recording.isFinalizing)
        } else {
            Menu {
                ForEach(RecordingMode.allCases) { mode in
                    Button {
                        start(mode)
                    } label: {
                        Label(mode.title, systemImage: mode.icon)
                    }
                }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Start a new recording")
            .disabled(recording.isBusy)
        }
    }

    private func start(_ mode: RecordingMode) {
        Task {
            await recording.startUsingPreferences(mode: mode, library: library)
            if let id = recording.activeDocumentID { appState.select(document: id) }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var calendarSync: CalendarSync
    @Binding var searchText: String

    private var filtered: [ScribeDocument] {
        guard !searchText.isEmpty else { return library.documents }
        let query = searchText.lowercased()
        return library.documents.filter {
            $0.title.lowercased().contains(query) || $0.fullText.lowercased().contains(query)
        }
    }

    private var documentGroups: [DocumentGroup] {
        let calendar = Calendar.current
        let now = Date()
        let previousWeekStart = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) ?? now
        let documents = filtered.sorted { $0.createdAt > $1.createdAt }

        return [
            DocumentGroup(title: "Today", documents: documents.filter { calendar.isDateInToday($0.createdAt) }),
            DocumentGroup(title: "Yesterday", documents: documents.filter { calendar.isDateInYesterday($0.createdAt) }),
            DocumentGroup(
                title: "Previous 7 Days",
                documents: documents.filter {
                    !calendar.isDateInToday($0.createdAt) &&
                    !calendar.isDateInYesterday($0.createdAt) &&
                    $0.createdAt >= previousWeekStart
                }
            ),
            DocumentGroup(title: "Older", documents: documents.filter { $0.createdAt < previousWeekStart })
        ].filter { !$0.documents.isEmpty }
    }

    private var upcomingMeetings: [Meeting] {
        let now = Date()
        let cutoff = now.addingTimeInterval(7 * 24 * 60 * 60)
        return calendarSync.upcomingMeetings.filter { $0.start >= now && $0.start <= cutoff }
    }

    var body: some View {
        List(selection: $appState.selection) {
            Section {
                Label("Home", systemImage: "house")
                    .tag(MainSelection.home)
            }

            ForEach(documentGroups) { group in
                Section(group.title) {
                    ForEach(group.documents) { document in
                        SidebarRow(document: document)
                            .tag(MainSelection.document(document.id))
                    }
                }
            }

            // The section stays visible whenever sync is on, so an empty list
            // explains itself instead of silently vanishing.
            if calendarSync.isEnabled {
                Section("Upcoming") {
                    if calendarSync.authorizationStatus != .fullAccess {
                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Grant calendar access…", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Kleio needs Calendar access to show your upcoming events")
                    } else if upcomingMeetings.isEmpty {
                        Text("No events in the next 7 days")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(upcomingMeetings) { meeting in
                            UpcomingMeetingRow(meeting: meeting)
                                .tag(MainSelection.meeting(meeting.id))
                        }
                    }
                }
            }
            if library.documents.isEmpty {
                Section("Recordings") {
                    Text("Your recordings will appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !searchText.isEmpty && filtered.isEmpty {
                Text("No matching recordings")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarSettingsButton()
        }
    }
}

/// Pinned below the sidebar list, aligned with the rows above it.
private struct SidebarSettingsButton: View {
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            SettingsLink {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .frame(width: 20)
                    Text("Settings")
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .help("Open Settings (⌘,)")
        }
    }
}

private struct DocumentGroup: Identifiable {
    let title: String
    let documents: [ScribeDocument]

    var id: String { title }
}

private struct UpcomingMeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: meeting.calendarColor))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .lineLimit(1)
                Text(MeetingPresentation.relativeStart(for: meeting.start))
                    .font(Theme.metaValue)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if let provider = MeetingPresentation.providerName(for: meeting.joinURL) {
                Text(provider)
                    .font(Theme.metaLabel)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct SidebarRow: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recording: RecordingSession
    let document: ScribeDocument

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusIcon
                .frame(width: 20, height: 20)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center]
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(document.title)
                    .font(.body.weight(.regular))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .contextMenu {
            Button("Re-transcribe") { queue.enqueue(document.id) }
                .disabled(document.status == .transcribing || document.status == .recording || (recording.activeDocumentID == document.id || recording.pendingSaveDocumentID == document.id))
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: document.id)])
            }
            Divider()
            Button("Delete", role: .destructive) {
                if appState.selectedDocumentID == document.id { appState.selection = .home }
                library.delete(document)
            }
            .disabled(document.status == .recording || (recording.activeDocumentID == document.id || recording.pendingSaveDocumentID == document.id))
        }
    }

    private var subtitle: String {
        let date = document.createdAt.formatted(date: .abbreviated, time: .shortened)
        switch document.status {
        case .recording: return "Recording…"
        case .queued: return "Waiting to transcribe…"
        case .transcribing:
            let pct = Int(((queue.progress[document.id] ?? 0) * 100).rounded())
            return "Transcribing… \(pct)%"
        case .failed: return "Failed, \(date)"
        case .recovered: return "Recovered, needs transcription"
        case .ready: return "\(date) · \(document.duration.clockString)"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch document.status {
        case .recording:
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .transcribing:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .recovered:
            Image(systemName: "bandage.fill").foregroundStyle(.orange)
        case .ready:
            Image(systemName: document.videoTracks?.isEmpty == false ? "video" : document.kind == .recording ? "waveform" : "doc.text")
                .foregroundStyle(.secondary)
        }
    }
}

/// App shortcuts and capture options stay together so the target is visible before starting.
struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var calendarSync: CalendarSync
    @StateObject private var shortcuts = AppShortcutStore()
    @Environment(\.openSettings) private var openSettings
    @AppStorage("recordingVideoEnabled") private var videoEnabled = false
    @AppStorage("recordingVideoMode") private var videoMode = "window"
    @AppStorage("expectedRemoteSpeakerCount") private var speakerCount = 0
    @AppStorage("microphoneSpeakerName") private var microphoneName = "Me"
    @AppStorage("preferredInputDeviceUID") private var inputUID = ""
    @AppStorage(AudioDevices.preferredOutputDeviceUIDKey) private var outputUID = ""
    @AppStorage("meetingMuteSyncEnabled") private var meetingMuteSyncEnabled = false
    @AppStorage("speakerDetectionModel") private var speakerModel = "community1"
    @State private var devices = AudioDevices.inputDevices()
    @State private var outputDevices = AudioDevices.outputDevices()
    @State private var showCaptureSettings = false

    private var canStart: Bool { !recording.isBusy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    recordCard
                    speakerSetupNotices
                }
                quickActions

                if calendarSync.isEnabled && calendarSync.upcomingMeetings.contains(where: {
                    Calendar.current.isDateInToday($0.start)
                }) {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Up next")
                        UpNextStrip()
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Recent recordings")
                    if recentDocuments.isEmpty {
                        ContentUnavailableView("Your recordings live here", systemImage: "waveform",
                            description: Text("Choose an app above, record a voice memo, or import a file."))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(recentDocuments.enumerated()), id: \.element.id) { index, document in
                                if index > 0 { Divider().padding(.leading, 74) }
                                RecentDocumentCard(document: document)
                            }
                        }
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            devices = AudioDevices.inputDevices()
            outputDevices = AudioDevices.outputDevices()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title3.weight(.semibold))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Home").font(Theme.displayTitle(size: 28))
                Label("Record and transcribe on this Mac", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            modelMenu
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(TranscriptionModelEngine.allCases, id: \.self) { engine in
                let models = ModelManager.catalog.filter { $0.engine == engine && modelManager.isDownloaded($0.variant) }
                if !models.isEmpty {
                    Section(engine.title) {
                        ForEach(models) { model in
                            Button {
                                modelManager.selectedVariant = model.variant
                            } label: {
                                if model.variant == modelManager.selectedVariant {
                                    Label(model.displayName, systemImage: "checkmark")
                                } else { Text(model.displayName) }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Manage Models…") { SettingsPane.select(.models); openSettings() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text(ModelManager.info(for: modelManager.selectedVariant)?.displayName ?? "Choose model")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.cardBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Transcription model")
    }

    // MARK: Record card

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                deviceSummary
                Spacer(minLength: 12)
                videoOptions
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Record an app").font(.headline)
                    Spacer()
                    Text("App audio + your microphone. Browsers include all audible tabs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    ForEach(shortcuts.shortcuts) { shortcut in
                        Button { start(.meeting, shortcut: shortcut) } label: {
                            AppTile(title: shortcut.name) {
                                Image(nsImage: shortcut.icon).resizable().frame(width: 38, height: 38)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canStart)
                        .help("Record \(shortcut.name) audio and your microphone")
                        .contextMenu {
                            if let url = shortcut.applicationURL {
                                Button("Open \(shortcut.name)") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
                            }
                            Button("Remove Shortcut", role: .destructive) { shortcuts.remove(shortcut) }
                        }
                    }
                    Button(action: addShortcut) {
                        AppTile(title: "Add app", dashed: true) {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 38, height: 38)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Add an app you record often")
                }
            }
            .padding(18)
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    /// A disconnected choice falls back to the system default when recording starts.
    private func deviceName(_ uid: String, in devices: [AudioDevice]) -> String {
        devices.first { $0.uid == uid }?.name ?? "System default"
    }

    private var participantsLabel: String {
        speakerCount == 1 ? "1 other person" : speakerCount > 1 ? "\(speakerCount) other people" : "Auto-detect speakers"
    }

    private var deviceSummary: some View {
        Button { showCaptureSettings.toggle() } label: {
            HStack(spacing: 14) {
                deviceChip("mic.fill", deviceName(inputUID, in: devices))
                deviceChip("headphones", deviceName(outputUID, in: outputDevices))
                deviceChip("person.2.fill", participantsLabel)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
        .help("Choose your microphone, headset, and number of other participants")
        .popover(isPresented: $showCaptureSettings, arrowEdge: .bottom) { captureSettings }
    }

    private func deviceChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 16)
            Text(text).lineLimit(1)
        }
        .font(.callout)
    }

    private var captureSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Recording options").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("Microphone").font(.callout.weight(.medium))
                Picker("Microphone", selection: $inputUID) {
                    Text("System default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }.labelsHidden()
                Text("Labelled as \(microphoneName.isEmpty ? "Me" : microphoneName) in transcripts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Headset or speakers").font(.callout.weight(.medium))
                Picker("Headset or speakers", selection: $outputUID) {
                    Text("System default").tag("")
                    ForEach(outputDevices) { Text($0.name).tag($0.uid) }
                }.labelsHidden()
                Text("Choose the device your call plays on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Other participants").font(.callout.weight(.medium))
                RemoteSpeakerCountPicker(selection: $speakerCount).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Follow meeting mute", isOn: $meetingMuteSyncEnabled)
                Text("Native test mode. Requires Accessibility access and a meeting app shortcut. When the control cannot be read, microphone saving pauses. Background browser tabs may be unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Not yet verified in live calls. Leave off until testing.")
                    .font(.caption).foregroundStyle(.secondary)
                if meetingMuteSyncEnabled {
                    Button("Open Accessibility Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }.controlSize(.regular)
                }
            }
        }
        .controlSize(.large)
        .padding(22)
        .frame(width: 340)
    }

    private var videoOptions: some View {
        HStack(spacing: 10) {
            if videoEnabled {
                Picker("Video source", selection: $videoMode) {
                    Text("Window").tag("window")
                    Text("Display").tag("display")
                }
                .labelsHidden().fixedSize()
            }
            Toggle(isOn: $videoEnabled) {
                Label("Video", systemImage: videoEnabled ? "video.fill" : "video")
                    .font(.callout.weight(.medium))
            }
            .toggleStyle(.switch).controlSize(.small).fixedSize()
            .help("Also record a window or display chosen with the macOS picker")
        }
        .disabled(!canStart)
    }

    @ViewBuilder
    private var speakerSetupNotices: some View {
        if speakerModel == "sortformer", speakerCount != 1, !(2...4).contains(speakerCount) {
            Label("Choose 2 to 4 other people for Sortformer, or change the model in Settings → Speakers.", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
                .padding(.horizontal, 4)
        }
        if speakerCount != 1, !SpeakerDiarizer.modelsReady(for: SpeakerDetectionModel(rawValue: speakerModel) ?? .community1) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                Text("Download a speaker model to tell remote voices apart.")
                Spacer(minLength: 8)
                Button("Open Settings") { SettingsPane.select(.speakers); openSettings() }.buttonStyle(.link)
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                QuickActionTile(title: "Voice memo", subtitle: "Microphone only", icon: "mic.fill", tint: .orange) {
                    start(.microphoneOnly)
                }
                .disabled(!canStart)
                QuickActionTile(title: "All Mac audio", subtitle: "Every app + mic", icon: "desktopcomputer", tint: .blue) {
                    start(.meeting)
                }
                .disabled(!canStart)
                QuickActionTile(title: "Import files", subtitle: "Audio or video", icon: "square.and.arrow.down", tint: .green) {
                    appState.presentImporter(.files)
                }
                QuickActionTile(title: "Podcast tracks", subtitle: "One file per speaker", icon: "person.2.wave.2.fill", tint: .purple) {
                    appState.presentImporter(.podcast)
                }
            }
        }
    }

    private func start(_ mode: RecordingMode, shortcut: RecordingApplication? = nil) {
        guard canStart else { return }
        Task {
            await recording.startUsingPreferences(mode: mode, library: library, shortcut: shortcut)
            if let id = recording.activeDocumentID { appState.select(document: id) }
        }
    }

    private func addShortcut() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add shortcut"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        shortcuts.add(RecordingApplication(bundleID: bundleID, name: name))
    }

    private var recentDocuments: [ScribeDocument] {
        Array(library.documents.sorted { $0.createdAt > $1.createdAt }.prefix(12))
    }
}

/// One app shortcut inside the record card.
private struct AppTile<Icon: View>: View {
    let title: String
    var dashed = false
    @ViewBuilder let icon: Icon
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            icon.frame(height: 38)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(dashed ? .secondary : .primary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(dashed ? Color.clear : Color.primary.opacity(hovering && isEnabled ? 0.08 : 0.04))
        }
        .overlay {
            if dashed {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(hovering ? 0.6 : 0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Equal-size secondary ways to start, below the record card.
private struct QuickActionTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Color.accentColor.opacity(hovering && isEnabled ? 0.35 : 0)))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct RemoteSpeakerCountPicker: View {
    @Binding var selection: Int
    var body: some View {
        Picker("Other participants", selection: $selection) {
            Text("Detect automatically").tag(0)
            Text("One other person").tag(1)
            ForEach(2...12, id: \.self) { count in
                Text("\(count) other people").tag(count)
            }
        }
    }
}

struct RecentDocumentCard: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recording: RecordingSession
    let document: ScribeDocument
    @State private var hovering = false

    var body: some View {
        Button {
            appState.select(document: document.id)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: document.videoTracks?.isEmpty == false ? "video" : "waveform")
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(document.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(document.segments.isEmpty ? "Transcript will appear here when processing finishes." : document.fullText)
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(document.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(document.duration.clockString) · \(statusLabel)")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.accentColor.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            Button("Re-transcribe") { queue.enqueue(document.id) }
                .disabled(document.status == .transcribing || document.status == .recording || (recording.activeDocumentID == document.id || recording.pendingSaveDocumentID == document.id))
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: document.id)])
            }
            Divider()
            Button("Delete", role: .destructive) {
                if appState.selectedDocumentID == document.id { appState.selection = .home }
                library.delete(document)
            }
            .disabled(document.status == .recording || (recording.activeDocumentID == document.id || recording.pendingSaveDocumentID == document.id))
        }
    }

    private var statusLabel: String {
        guard document.status == .ready else { return document.status.rawValue.capitalized }
        if document.speakerAnalysisStatus == .failed { return "Speakers need review" }
        let labels = Set(document.segments.map { document.speakerName(for: $0) })
        let unresolved = labels.contains("Uncertain speaker") || labels.contains("Unanalyzed audio")
        let count = labels.subtracting(["Uncertain speaker", "Unanalyzed audio"]).count
        if count == 0 { return unresolved ? "Speakers need review" : "No speech" }
        let countLabel = count == 1 ? "1 speaker" : "\(count) speakers"
        return unresolved ? countLabel + " · review needed" : countLabel
    }
}

struct DropOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 36))
                Text("Drop to transcribe")
                    .font(.title3.bold())
            }
            .foregroundStyle(Color.accentColor)
        }
        .padding(16)
        .allowsHitTesting(false)
    }
}

/// Routes a selected document to the right state view.
struct DocumentDetailView: View {
    let document: ScribeDocument
    @State private var showSavedTranscript = false

    var body: some View {
        if showSavedTranscript, !document.segments.isEmpty, [.failed, .recovered].contains(document.status) {
            VStack(spacing: 0) {
                HStack {
                    Label("Saved transcript", systemImage: "doc.text")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Review audio issue") { showSavedTranscript = false }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                TranscriptView(document: document)
            }
        } else {
            switch document.status {
            case .ready:
                TranscriptView(document: document)
            case .queued, .transcribing:
                TranscribingView(document: document)
            case .failed, .recovered:
                RecordingProblemView(document: document, onViewTranscript: { showSavedTranscript = true })
            case .recording:
                ActiveRecordingView()
            }
        }
    }
}

struct TranscribingView: View {
    @EnvironmentObject private var queue: TranscriptionQueue
    let document: ScribeDocument

    private var waiting: Bool { document.status == .queued }
    private var needsSave: Bool { queue.pendingSaveIDs.contains(document.id) }
    private var fraction: Double { min(1, max(0, queue.progress[document.id] ?? 0)) }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: needsSave ? "externaldrive.badge.exclamationmark" : "waveform")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(needsSave ? Color.orange : Color.accentColor)
                .frame(width: 64, height: 64)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 8) {
                Text(needsSave ? "Waiting to save" : waiting ? "Waiting to transcribe" : "Creating your transcript")
                    .font(.title2.weight(.semibold))
                Text(document.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !needsSave {
                ProgressView(value: waiting || fraction == 0 ? nil : fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 280)
            }

            Text(needsSave ? "Retry saving to continue. Your recording is still available."
                 : waiting ? "This recording will start when the current task finishes."
                 : "Processing audio on this Mac. You can browse your recordings while it finishes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if needsSave {
                Button("Retry Save") { queue.retrySave(document.id) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Cancel") { queue.cancel(document.id) }
                    .buttonStyle(.bordered)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
