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
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            detail
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
                    if let first = ids.first { appState.selection = first }
                case .podcast:
                    if let id = Importer.importPodcast(urls, library: library, queue: queue) {
                        appState.selection = id
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
        .alert("Recording Problem", isPresented: recordingErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recording.lastError ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if recording.isRecording {
            ActiveRecordingView()
        } else if let id = appState.selection, let doc = library.document(id: id) {
            DocumentDetailView(document: doc)
                .id(doc.id)
        } else {
            HomeView()
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
            if let first = ids.first { appState.selection = first }
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
                appState.selection = id
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .foregroundStyle(.red)
            }
            .help("Stop recording and transcribe")
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
                    .foregroundStyle(.red)
            }
            .help("Start a new recording")
        }
    }

    private func start(_ mode: RecordingMode) {
        Task {
            await recording.start(mode: mode, library: library)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var appState: AppState
    @Binding var searchText: String

    private var filtered: [ScribeDocument] {
        guard !searchText.isEmpty else { return library.documents }
        let query = searchText.lowercased()
        return library.documents.filter {
            $0.title.lowercased().contains(query) || $0.fullText.lowercased().contains(query)
        }
    }

    var body: some View {
        List(selection: $appState.selection) {
            if !filtered.isEmpty {
                Section("Library") {
                    ForEach(filtered) { doc in
                        SidebarRow(document: doc)
                            .tag(doc.id)
                    }
                }
            }
        }
        .overlay {
            if library.documents.isEmpty {
                ContentUnavailableView(
                    "No transcripts yet",
                    systemImage: "waveform",
                    description: Text("Record a call or drop in an audio file.")
                )
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }
}

struct SidebarRow: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var appState: AppState
    let document: ScribeDocument
    @State private var waveformSamples: [Float] = []

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusIcon
                .frame(width: 20, height: 20)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center]
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.body.weight(.regular))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if document.status == .ready, !document.tracks.isEmpty {
                    waveformThumbnail
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 14)
                        .task(id: document.id) {
                            let urls = document.tracks.map {
                                LibraryStore.folder(for: document.id).appendingPathComponent($0.fileName)
                            }
                            let samples = await WaveformSampler.samples(for: urls, bucketCount: 1_000)
                            guard !Task.isCancelled else { return }
                            waveformSamples = downsample(samples, to: 48)
                        }
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Re-transcribe") { queue.enqueue(document.id) }
                .disabled(document.status == .transcribing || document.status == .recording)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([LibraryStore.folder(for: document.id)])
            }
            Divider()
            Button("Delete", role: .destructive) {
                if appState.selection == document.id { appState.selection = nil }
                library.delete(document)
            }
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

    private var waveformThumbnail: some View {
        Canvas { context, size in
            guard !waveformSamples.isEmpty else { return }

            let barWidth: CGFloat = 1.5
            let barCount = waveformSamples.count
            let gap = barCount > 1
                ? max(1, (size.width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1))
                : 0
            let center = size.height / 2

            for (index, sample) in waveformSamples.enumerated() {
                let height = max(2, CGFloat(sample) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + gap),
                    y: center - height / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 0.75),
                    with: .color(Color(nsColor: .tertiaryLabelColor))
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func downsample(_ samples: [Float], to bucketCount: Int) -> [Float] {
        guard samples.count > bucketCount else { return samples }

        return (0..<bucketCount).map { index in
            let start = index * samples.count / bucketCount
            let end = max(start + 1, (index + 1) * samples.count / bucketCount)
            return samples[start..<min(end, samples.count)].max() ?? 0
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
            Image(systemName: document.kind == .recording ? "waveform.circle.fill" : "doc.circle.fill")
                .foregroundStyle(.tint)
        }
    }
}

/// Empty-selection home.
struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var calendarSync: CalendarSync
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if showsUpNext {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Up Next")
                            .font(.title3.bold())
                        UpNextStrip()
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Recent")
                        .font(.title3.bold())

                    if recentDocuments.isEmpty {
                        emptyLibrary
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 14)],
                            spacing: 14
                        ) {
                            ForEach(recentDocuments) { document in
                                RecentDocumentCard(document: document)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        appState.presentImporter(.podcast)
                    } label: {
                        Label("Podcast Tracks…", systemImage: "person.2.wave.2")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if dictation.enabled {
                            dictation.toggle()
                        } else {
                            dictation.setEnabled(true, promptForAccessibility: true)
                        }
                    } label: {
                        Label(
                            dictation.enabled ? "Dictation On" : "Enable Dictation",
                            systemImage: "text.cursor"
                        )
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 0)

                    Button {
                        openSettings()
                    } label: {
                        Text("Model: \(modelDisplayName) · change in Settings")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Scribe")
                .font(.largeTitle.bold())

            Spacer(minLength: 24)

            Button {
                Task { await recording.start(mode: .meeting, library: library) }
            } label: {
                Label("Record Meeting", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(dictation.phase != .idle)

            Menu {
                ForEach([RecordingMode.systemOnly, .microphoneOnly]) { mode in
                    Button {
                        Task { await recording.start(mode: mode, library: library) }
                    } label: {
                        Label(mode.title, systemImage: mode.icon)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .disabled(dictation.phase != .idle)

            Button {
                appState.presentImporter(.files)
            } label: {
                Label("Open File…", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
    }

    private var recentDocuments: [ScribeDocument] {
        Array(
            library.documents
                .filter { $0.status == .ready }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(9)
        )
    }

    private var showsUpNext: Bool {
        calendarSync.isEnabled && calendarSync.upcomingMeetings.contains {
            Calendar.current.isDateInToday($0.start)
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("No recordings yet")
                .font(.headline)
            Text("Record a call or drop in an audio file to get started.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var modelDisplayName: String {
        ModelManager.catalog.first { $0.variant == modelManager.selectedVariant }?.displayName
            ?? modelManager.selectedVariant
    }
}

struct RecentDocumentCard: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var appState: AppState
    let document: ScribeDocument
    @State private var hovering = false
    @State private var waveformSamples: [Float] = []

    var body: some View {
        Button {
            appState.selection = document.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                waveformThumbnail
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(document.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(document.duration.clockString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background { cardSurface }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(RecentDocumentCardButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .task(id: document.id) {
            let urls = document.tracks.map {
                LibraryStore.folder(for: document.id).appendingPathComponent($0.fileName)
            }
            let samples = await WaveformSampler.samples(for: urls, bucketCount: 1_000)
            guard !Task.isCancelled else { return }
            waveformSamples = downsample(samples, to: 96)
        }
        .contextMenu {
            Button("Re-transcribe") { queue.enqueue(document.id) }
                .disabled(document.status == .transcribing || document.status == .recording)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([LibraryStore.folder(for: document.id)])
            }
            Divider()
            Button("Delete", role: .destructive) {
                if appState.selection == document.id { appState.selection = nil }
                library.delete(document)
            }
        }
    }

    @ViewBuilder
    private var cardSurface: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(in: RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(hovering ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        }
    }

    private var waveformThumbnail: some View {
        Canvas { context, size in
            guard !waveformSamples.isEmpty else { return }

            let barWidth: CGFloat = 1.5
            let barCount = waveformSamples.count
            let gap = barCount > 1
                ? max(1, (size.width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1))
                : 0
            let center = size.height / 2

            for (index, sample) in waveformSamples.enumerated() {
                let height = max(2, CGFloat(sample) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + gap),
                    y: center - height / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 0.75),
                    with: .color(Color(nsColor: .tertiaryLabelColor))
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func downsample(_ samples: [Float], to bucketCount: Int) -> [Float] {
        guard samples.count > bucketCount else { return samples }

        return (0..<bucketCount).map { index in
            let start = index * samples.count / bucketCount
            let end = max(start + 1, (index + 1) * samples.count / bucketCount)
            return samples[start..<min(end, samples.count)].max() ?? 0
        }
    }
}

private struct RecentDocumentCardButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .shadow(
                color: hovering && !configuration.isPressed ? .black.opacity(0.12) : .clear,
                radius: hovering && !configuration.isPressed ? 6 : 0,
                y: hovering && !configuration.isPressed ? 2 : 0
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    let document: ScribeDocument

    var body: some View {
        switch document.status {
        case .ready:
            TranscriptView(document: document)
        case .queued, .transcribing:
            TranscribingView(document: document)
        case .failed:
            VStack(spacing: 12) {
                ContentUnavailableView {
                    Label("Transcription failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(document.failureReason ?? "Unknown error")
                }
                Button("Try Again") { queue.enqueue(document.id) }
                    .buttonStyle(.borderedProminent)
            }
        case .recovered:
            VStack(spacing: 12) {
                ContentUnavailableView {
                    Label("Recording recovered", systemImage: "bandage")
                } description: {
                    Text("Scribe quit unexpectedly during this recording, but \(document.duration.clockString) of audio was saved safely and is ready to transcribe.")
                }
                Button("Transcribe Now") { queue.enqueue(document.id) }
                    .buttonStyle(.borderedProminent)
            }
        case .recording:
            ActiveRecordingView()
        }
    }
}

struct TranscribingView: View {
    @EnvironmentObject private var queue: TranscriptionQueue
    let document: ScribeDocument

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: queue.progress[document.id] ?? 0)
                .progressViewStyle(.linear)
                .frame(maxWidth: 420)
            Text(document.status == .queued ? "Waiting to transcribe…" : "Transcribing \(document.title)…")
                .font(.headline)
            if let preview = queue.livePreview[document.id], !preview.isEmpty {
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .frame(maxWidth: 520)
                    .multilineTextAlignment(.center)
            }
            Button("Cancel") { queue.cancelCurrent() }
                .disabled(document.status == .queued)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
