import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dictation: DictationController
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
                    DocumentJobStatusView()
                    if recording.isRecording || recording.isFinalizing || recording.hasPendingSave {
                        RecordingStatusBar()
                    }
                }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search transcripts")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if dictation.enabled {
                    Button {
                        dictation.toggle()
                    } label: {
                        Label(
                            dictation.phase == .recording ? "Finish Dictation" : "Dictate",
                            systemImage: dictation.phase == .recording ? "stop.circle.fill" : "mic.badge.plus"
                        )
                        .foregroundStyle(dictation.phase == .recording ? Color.red : Color.primary)
                    }
                    .disabled(dictation.phase == .preparing || dictation.phase == .transcribing)
                    .help("System-wide dictation (⌥Space)")
                }
                RecordMenu()
                    .disabled(dictation.phase != .idle)
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
                switch appState.importMode {
                case .files:
                    let ids = Importer.importFiles(urls, library: library, queue: queue)
                    if let first = ids.first { appState.select(document: first) }
                case .podcast:
                    if let id = Importer.importPodcast(urls, library: library, queue: queue) {
                        appState.select(document: id)
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
        var found = false
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            found = true
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ids = Importer.importFiles(urls, library: library, queue: queue)
            if let first = ids.first { appState.select(document: first) }
        }
        return found
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
        .safeAreaInset(edge: .bottom) {
            HStack {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
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
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var calendarSync: CalendarSync
    @StateObject private var shortcuts = AppShortcutStore()
    @Environment(\.openSettings) private var openSettings
    @AppStorage("recordingVideoEnabled") private var videoEnabled = false
    @AppStorage("recordingVideoMode") private var videoMode = "window"
    @AppStorage("expectedRemoteSpeakerCount") private var speakerCount = 0
    @AppStorage("microphoneSpeakerName") private var microphoneName = "Me"
    @AppStorage("preferredInputDeviceUID") private var inputUID = ""
    @AppStorage("meetingMuteSyncEnabled") private var meetingMuteSyncEnabled = false
    @AppStorage("speakerDetectionModel") private var speakerModel = "community1"
    @State private var devices = AudioDevices.inputDevices()
    @State private var showCaptureSettings = false

    private var canStart: Bool {
        !recording.isBusy && dictation.phase == .idle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                VStack(alignment: .leading, spacing: 16) {
                    captureOptions
                    shortcutsSection
                }

                if calendarSync.isEnabled && calendarSync.upcomingMeetings.contains(where: {
                    Calendar.current.isDateInToday($0.start)
                }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Up next").font(.title3.bold())
                        UpNextStrip()
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Recent recordings").font(.title3.bold())
                    if recentDocuments.isEmpty {
                        ContentUnavailableView("Your recordings live here", systemImage: "waveform",
                            description: Text("Choose an app above, record a voice memo, or open a file."))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(recentDocuments.enumerated()), id: \.element.id) { index, document in
                                if index > 0 { Divider().padding(.leading, 74) }
                                RecentDocumentCard(document: document)
                            }
                        }
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            devices = AudioDevices.inputDevices()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Home").font(Theme.displayTitle())
                Label("Record and transcribe on this Mac", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(ModelManager.catalog.filter { modelManager.isDownloaded($0.variant) }) { model in
                    Button {
                        modelManager.selectedVariant = model.variant
                    } label: {
                        if model.variant == modelManager.selectedVariant {
                            Label(model.displayName, systemImage: "checkmark")
                        } else { Text(model.displayName) }
                    }
                }
                Divider()
                Button("Manage models…") { openSettings() }
            } label: {
                Label(ModelManager.catalog.first { $0.variant == modelManager.selectedVariant }?.displayName ?? "Choose model",
                      systemImage: "cpu")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
    }

    private var captureOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    microphoneOptions
                    Spacer(minLength: 16)
                    videoOptions
                }
                VStack(alignment: .leading, spacing: 18) {
                    microphoneOptions
                    videoOptions
                }
            }
            .padding(18)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
            if speakerModel == "sortformer", speakerCount != 1, !(2...4).contains(speakerCount) {
                Label("Choose 2 to 4 other people for Sortformer, or change the model in Settings.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if speakerCount != 1, !SpeakerDiarizer.modelsReady(for: SpeakerDetectionModel(rawValue: speakerModel) ?? .community1) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                    Text("Set up speaker detection")
                    Spacer(minLength: 8)
                    Button("Open Settings") { openSettings() }.buttonStyle(.link)
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
        }
        .disabled(!canStart)
    }

    private var microphoneOptions: some View {
        Button { showCaptureSettings.toggle() } label: {
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 18)).foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Microphone · \(microphoneName.isEmpty ? "Me" : microphoneName)")
                        .font(.system(size: 14, weight: .semibold))
                    Text(speakerCount == 1 ? "One other person" : speakerCount > 1 ? "\(speakerCount) other people" : "Detect other speakers automatically")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose your microphone and number of other participants")
        .popover(isPresented: $showCaptureSettings, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Recording options").font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Microphone").font(.callout.weight(.medium))
                    Picker("Microphone", selection: $inputUID) {
                        Text("System default").tag("")
                        ForEach(devices) { Text($0.name).tag($0.uid) }
                    }.labelsHidden()
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
                Text("Your microphone is always you. Choose one other person to keep all remote speech under one name.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .controlSize(.large)
            .padding(22)
            .frame(width: 340)
        }
    }

    private var videoOptions: some View {
        HStack(spacing: 12) {
            if videoEnabled {
                Picker("Video source", selection: $videoMode) {
                    Text("Window").tag("window")
                    Text("Display").tag("display")
                }
                .labelsHidden().fixedSize()
            }
            Toggle(isOn: $videoEnabled) {
                Label("Video", systemImage: videoEnabled ? "video.fill" : "video")
                    .font(.system(size: 14, weight: .medium))
            }
            .toggleStyle(.switch).fixedSize()
            .help("Also record a window or display chosen with the macOS picker")
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an app to record").font(.system(size: 14, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 92), spacing: 12), count: min(5, shortcuts.shortcuts.count + 1)), spacing: 12) {
                ForEach(shortcuts.shortcuts) { shortcut in
                    Button { start(.meeting, shortcut: shortcut) } label: {
                        shortcutLabel(title: shortcut.name) {
                            Image(nsImage: shortcut.icon).resizable().frame(width: 42, height: 42)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStart)
                    .help("Record \(shortcut.name) audio and your microphone")
                    .contextMenu {
                        if let url = shortcut.applicationURL {
                            Button("Open \(shortcut.name)") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
                        }
                        Button("Remove shortcut", role: .destructive) { shortcuts.remove(shortcut) }
                    }
                }
                Button(action: addShortcut) {
                    shortcutLabel(title: "Add app") {
                        Image(systemName: "plus").font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, height: 42)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.buttonStyle(.plain)
            }
            Text("App audio + your microphone. Browsers include all audible tabs.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.vertical, 2)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                Button { start(.microphoneOnly) } label: { Label("Voice memo", systemImage: "mic") }
                    .disabled(!canStart)
                Button { start(.meeting) } label: { Label("All Mac audio", systemImage: "desktopcomputer") }
                    .disabled(!canStart)
                    .help("Record all Mac audio and your microphone")
                Button { appState.presentImporter(.files) } label: { Label("Open files", systemImage: "folder") }
                Menu("More") {
                    Button("Podcast speaker tracks…") { appState.presentImporter(.podcast) }
                    Button("All Mac audio only") { start(.systemOnly) }.disabled(!canStart)
                    Button(dictation.enabled ? "Start dictation" : "Enable dictation") {
                        if dictation.enabled { dictation.toggle() }
                        else { dictation.setEnabled(true, promptForAccessibility: true) }
                    }.disabled(!canStart)
                }
            }
            .controlSize(.large)
        }
    }

    private func shortcutLabel<Icon: View>(title: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 12) {
            icon().frame(height: 42)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 108)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
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
