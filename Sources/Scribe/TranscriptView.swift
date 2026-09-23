import SwiftUI
import AppKit
import AVKit

/// Chooses visible headings without combining or rewriting transcript segments.
func transcriptSpeakerGroupStarts(in rows: [TranscriptTimelineRow]) -> Set<UUID> {
    var starts = Set<UUID>()
    var previous: TranscriptSegment?
    for row in rows {
        guard case .segment(let segment) = row else {
            previous = nil
            continue
        }
        let sameSpeaker: Bool
        if let previous, previous.source == segment.source {
            if previous.speakerID != nil || segment.speakerID != nil {
                sameSpeaker = previous.speakerID == segment.speakerID
            } else {
                sameSpeaker = previous.speaker == segment.speaker
            }
        } else {
            sameSpeaker = false
        }
        if !sameSpeaker { starts.insert(segment.id) }
        previous = segment
    }
    return starts
}

/// The document view: header and tabs for a summary, transcript, and notes,
/// with a player bar at the bottom.
struct TranscriptView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var replacements: ReplacementStore
    @EnvironmentObject private var appState: AppState
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var savedPeople: SavedPeopleStore
    let document: ScribeDocument

    @MainActor
    init(document: ScribeDocument, savedPeople: SavedPeopleStore? = nil) {
        self.document = document
        _savedPeople = ObservedObject(wrappedValue: savedPeople ?? .shared)
    }

    @State private var title: String = ""
    @State private var transcriptSearch = ""
    @State private var replacementText = ""
    @State private var showFindReplace = false
    @State private var matchCase = false
    @State private var replaceResult: String?
    @State private var showPeople = false
    @State private var showSpeakerStatus = false
    @State private var editingSpeaker: DocumentSpeaker?
    @State private var showVideo = true
    @State private var newSpeakerName = ""
    @EnvironmentObject private var summaries: SummaryJobs
    private var summarizing: Bool { summaries.runningIDs.contains(document.id) }
    private var summaryRequestBlocked: Bool { summarizing || summaries.pendingSaveIDs.contains(document.id) }
    private var summaryError: String? { summaries.errors[document.id] }
    @State private var documentEditError: String?
    @State private var correctionSuggestions: [(wrong: String, right: String)] = []
    @State private var selectedTab: DocumentTab = .transcript

    private enum DocumentTab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case notes = "Notes"

        var id: Self { self }
    }

    private var visibleSegments: [TranscriptSegment] {
        guard !transcriptSearch.isEmpty else { return document.segments }
        let query = transcriptSearch.lowercased()
        return document.segments.filter { $0.text.lowercased().contains(query) }
    }

    private var timelineRows: [TranscriptTimelineRow] {
        TranscriptTimelineRow.merged(
            segments: visibleSegments,
            notes: document.notes ?? []
        )
    }

    private var speakerGroupStarts: Set<UUID> {
        // Search hits retain their own headings because omitted turns may
        // belong to someone else.
        if !transcriptSearch.isEmpty { return Set(visibleSegments.map(\.id)) }
        return transcriptSpeakerGroupStarts(in: timelineRows)
    }

    private var activeSegmentID: UUID? {
        guard playback.documentID == document.id else { return nil }
        return TranscriptTiming.activeSegmentID(in: document.segments, at: playback.currentTime)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let warning = document.transcriptionWarning {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Some audio is missing").font(.callout.weight(.semibold))
                        Text(warning).font(.callout).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            Divider()
            tabContent
            Divider()
            if let error = playback.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Retry playback") {
                        Task {
                            playback.unload()
                            await playback.load(document: document, folder: library.folder(for: document.id))
                        }
                    }
                }
                .font(.caption)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            PlayerBar(document: document)
        }
        .background(Theme.paperBackground)
        .toolbar { toolbarContent }
        .task(id: document.id) {
            title = document.title
            selectedTab = hasSummary ? .summary : .transcript
            if var current = library.document(id: document.id) {
                current.normalizeSpeakerIdentities()
                if current != document { library.update(current) }
            }
            await playback.load(document: document, folder: library.folder(for: document.id))
        }
        .sheet(item: $editingSpeaker) { person in
            SpeakerNameSheet(speaker: person, savedPeople: savedPeople.people) { name, savedID, savePerson in
                try saveSpeakerName(person.id, name: name, savedPersonID: savedID, savePerson: savePerson)
            }
        }
        .onChange(of: summaries.completionCounts[document.id]) { _, _ in
            selectedTab = .summary
        }
        .onDisappear {
            if playback.documentID == document.id { playback.unload() }
        }
        .onChange(of: appState.selection) { _, _ in
            correctionSuggestions = []
        }
        .alert("Summary not saved", isPresented: summaryErrorBinding) {
            if summaries.pendingSaveIDs.contains(document.id) {
                Button("Retry Save") { summaries.retrySave(document.id) }
                Button("Show Recording Folder") {
                    NSWorkspace.shared.open(library.folder(for: document.id))
                }
            } else {
                Button("Open AI Settings") { openSettings() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(summaries.pendingSaveIDs.contains(document.id)
                 ? "The generated summary is still available. Check free disk space and access to the recording folder, then retry saving."
                 : summaryError ?? "")
        }
        .alert("Change not saved", isPresented: Binding(
            get: { documentEditError != nil },
            set: { if !$0 { documentEditError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(documentEditError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .onSubmit(commitTitle)

            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text(document.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(document.duration.clockString)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(document.modelUsed.map { variant in
                    "Transcribed with " + (ModelManager.catalog.first { $0.variant == variant }?.displayName ?? variant)
                } ?? "Recording details")
                Spacer(minLength: 0)
                Picker("Document section", selection: $selectedTab) {
                    ForEach(DocumentTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var hasSummary: Bool {
        guard let summary = document.summary else { return false }
        return !summary.isEmpty
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .summary:
            summaryTab
        case .transcript:
            transcriptTab
        case .notes:
            NotesTab(document: document)
        }
    }

    private var summaryTab: some View {
        Group {
            if let summary = document.summary, !summary.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Summary", systemImage: "sparkles")
                                .font(.callout.bold())
                            Spacer()
                            Button("Regenerate", action: summarize)
                                .buttonStyle(.bordered)
                                .disabled(summaryRequestBlocked || document.segments.isEmpty)
                        }
                        if document.summaryIsStale == true {
                            Label("Transcript changed since this summary was generated", systemImage: "exclamationmark.circle")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text("Regenerate the summary to use the latest transcript, notes, and speaker names.")
                                .foregroundStyle(.secondary)
                            DisclosureGroup("Show previous summary") {
                                SummaryMarkdownView(markdown: summary)
                                    .padding(.top, 8)
                            }
                        } else if let problem = SummaryService.outputProblem(summary) {
                            Label("This summary needs to be regenerated", systemImage: "exclamationmark.circle")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text(problem)
                                .foregroundStyle(.secondary)
                            DisclosureGroup("Show previous output") {
                                SummaryMarkdownView(markdown: summary)
                                    .padding(.top, 8)
                            }
                        } else {
                            SummaryMarkdownView(markdown: summary)
                        }
                        if summarizing {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Button("Cancel") { summaries.cancel(document.id) }
                                Text("Summarizing…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
                    .padding(20)
                }
            } else {
                ContentUnavailableView {
                    Label("No summary yet", systemImage: "sparkles")
                } description: {
                    Text("Generate a short overview of this transcript.")
                } actions: {
                    Button("Generate Summary", action: summarize)
                        .buttonStyle(.borderedProminent)
                        .disabled(summaryRequestBlocked || document.segments.isEmpty)
                    if summarizing {
                        Button("Cancel") { summaries.cancel(document.id) }
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcriptTab: some View {
        GeometryReader { geometry in
            let showsInlineInspector = geometry.size.width >= 880
            VStack(spacing: 0) {
                transcriptControls(inlineInspector: showsInlineInspector)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if showVideo, !(document.videoTracks ?? []).isEmpty {
                            RecordingVideoView(player: playback.player)
                                .frame(height: min(220, geometry.size.height * 0.4))
                                .background(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal, 28)
                                .padding(.top, 6)
                                .padding(.bottom, 12)
                        }
                        segmentList
                    }
                    if showPeople && showsInlineInspector {
                        Divider()
                        peopleInspector
                            .frame(width: 244)
                            .padding(.horizontal, 18)
                    }
                }
            }
        }
    }

    private func transcriptControls(inlineInspector: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Find in transcript", text: $transcriptSearch)
                        .textFieldStyle(.plain)
                }
                .font(.callout)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: 220)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                Button {
                    showFindReplace.toggle()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .accessibilityLabel("Find and replace")
                .help("Find and replace")
                Spacer(minLength: 0)
                if document.segments.contains(where: { $0.source != .microphone }) || document.speakerAnalysisStatus == .failed {
                    speakerStatusControl
                }
                Button {
                    undoManager?.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(undoManager?.canUndo != true)
                .accessibilityLabel("Undo")
                .help("Undo")
                Button {
                    withAnimation { showPeople.toggle() }
                } label: {
                    Label("People", systemImage: "person.2")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showPeople ? Color.accentColor : .secondary)
                .help("Name or merge speakers")
                .popover(isPresented: Binding(
                    get: { showPeople && !inlineInspector },
                    set: { if !inlineInspector { showPeople = $0 } }
                ), arrowEdge: .bottom) {
                    peopleInspector
                        .padding(.horizontal, 18)
                        .frame(width: 300, height: 460)
                }
            }
            if showFindReplace { findReplaceBar }
            if let suggestion = correctionSuggestions.first {
                correctionSuggestion(suggestion)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private var segmentList: some View {
        let groupStarts = speakerGroupStarts
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(timelineRows) { row in
                        switch row {
                        case .segment(let segment):
                            SegmentRow(
                                segment: segment,
                                speakerName: document.speakerName(for: segment),
                                person: document.speakers?.first { $0.id == segment.speakerID },
                                availableSpeakers: remoteSpeakers,
                                showSpeaker: document.hasSpeakerLabels,
                                startsSpeakerGroup: groupStarts.contains(segment.id),
                                canEditSpeaker: !isAnalyzingSpeakers,
                                isActive: segment.id == activeSegmentID,
                                highlight: transcriptSearch,
                                onSeek: { playback.seek(to: segment.start) },
                                onEdit: { newText in commitSegmentEdit(segment.id, text: newText) },
                                onSpeakerChange: { speakerID in
                                    _ = applySpeakerEdit("Assign speaker") { $0.assignSpeaker(to: segment.id, speakerID: speakerID) }
                                },
                                onRename: { editingSpeaker = document.speakers?.first { $0.id == segment.speakerID && !$0.isMicrophone } },
                                onMerge: { target in
                                    guard let source = segment.speakerID else { return }
                                    _ = applySpeakerEdit("Merge speakers") { $0.mergeSpeaker(id: source, into: target) }
                                }
                            )
                            .id(segment.id)
                        case .note(let note):
                            MeetingNoteRow(
                                note: note,
                                onSeek: { playback.seek(to: note.time) },
                                onEdit: { newText in commitNoteEdit(note.id, text: newText) },
                                onDelete: { deleteNote(note.id) }
                            )
                            .padding(.vertical, 12)
                            .id(note.id)
                        }
                    }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 32)
                .padding(.top, 6)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
            .overlay {
                if document.segments.isEmpty && (document.notes ?? []).isEmpty {
                    ContentUnavailableView(
                        "No speech detected",
                        systemImage: "waveform.slash",
                        description: Text("The audio didn't contain any recognizable speech.")
                    )
                } else if timelineRows.isEmpty {
                    ContentUnavailableView.search(text: transcriptSearch)
                }
            }
            .onChange(of: activeSegmentID) { _, newValue in
                if let newValue, playback.isPlaying {
                    withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                copyTranscript()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the full transcript")

            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.displayName) {
                        Exporter.exportWithPanel(document, format: format)
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the transcript")

            if !(document.videoTracks ?? []).isEmpty {
                Button {
                    selectedTab = .transcript
                    showVideo.toggle()
                } label: {
                    Label(showVideo ? "Hide video" : "Show video", systemImage: "video")
                }
            }

            Button {
                summarize()
            } label: {
                Label("Summarize", systemImage: "sparkles")
            }
            .help(SummaryService.isConfigured
                  ? "Generate an AI summary"
                  : "Choose a summary provider in Settings → AI")
            .disabled(summaryRequestBlocked || document.segments.isEmpty)
        }
    }

    private var summaryErrorBinding: Binding<Bool> {
        Binding(get: { summaryError != nil }, set: { if !$0 { summaries.dismissError(document.id) } })
    }

    private var findReplaceBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $transcriptSearch)
                .textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
            TextField("Replace with", text: $replacementText)
                .textFieldStyle(.roundedBorder)
            Toggle("Match case", isOn: $matchCase)
                .toggleStyle(.checkbox)
                .fixedSize()
            Button("Replace All", action: replaceAll)
                .disabled(transcriptSearch.isEmpty)
            if let replaceResult {
                Text(replaceResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .font(.callout)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .padding(.top, 4)
    }

    private func correctionSuggestion(_ suggestion: (wrong: String, right: String)) -> some View {
        HStack(spacing: 8) {
            Text("Always replace '\(suggestion.wrong)' with '\(suggestion.right)'?")
                .font(.callout)
            Spacer()
            Button("Add") {
                _ = replacements.addRule(original: suggestion.wrong, replacement: suggestion.right)
                dismissCorrectionSuggestion()
            }
            .buttonStyle(.bordered)
            Button("Dismiss", action: dismissCorrectionSuggestion)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
        .padding(.top, 4)
    }

    private var remoteSpeakers: [DocumentSpeaker] {
        (document.speakers ?? []).filter { !$0.isMicrophone }
    }

    private var isAnalyzingSpeakers: Bool {
        document.speakerAnalysisStatus == .running || document.status == .transcribing
    }

    private var speakerStatusControl: some View {
        Button { showSpeakerStatus.toggle() } label: {
            HStack(spacing: 6) {
                if isAnalyzingSpeakers {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: document.speakerAnalysisStatus == .failed ? "exclamationmark.circle" : "waveform")
                }
                Text(isAnalyzingSpeakers ? "Finding speakers" : document.speakerAnalysisStatus == .failed ? "Speakers need review" : "Speakers")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(document.speakerAnalysisStatus == .failed ? Color.orange : .secondary)
        }
        .buttonStyle(.borderless)
        .help(document.speakerAnalysisError ?? speakerAnalysisTitle)
        .popover(isPresented: $showSpeakerStatus, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(speakerAnalysisTitle).font(.headline)
                if let error = document.speakerAnalysisError, document.speakerAnalysisStatus == .failed {
                    Text(error).textSelection(.enabled)
                }
                if document.speakerEditsApplied == true {
                    Text("Speaker corrections apply to this recording. Retrying keeps your corrections.")
                        .foregroundStyle(.secondary)
                }
                if !isAnalyzingSpeakers {
                    Button(document.speakerAnalysisStatus == .failed ? "Retry speaker analysis" : "Analyze speakers") {
                        queue.retrySpeakerAnalysis(document.id)
                    }
                    .disabled(document.segments.isEmpty)
                    .help("Run local speaker analysis without transcribing the audio again")
                }
            }
            .font(.callout)
            .padding(18)
            .frame(width: 330, alignment: .leading)
        }
    }

    private var speakerAnalysisTitle: String {
        if isAnalyzingSpeakers { return "Finding speakers on this Mac…" }
        switch document.speakerAnalysisStatus {
        case .complete:
            return document.expectedRemoteSpeakerCount == 1 ? "One other person" : "Speaker analysis complete"
        case .failed: return "Speaker analysis needs attention"
        default: return "Review and name the speakers in this recording"
        }
    }

    private var peopleInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("People").font(.headline)
                        Spacer()
                        Button { withAnimation { showPeople = false } } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Close people")
                    }
                    Text("Name a speaker or combine duplicate labels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(document.speakers ?? []) { person in
                        HStack(spacing: 9) {
                            Image(systemName: person.isMicrophone ? "mic.fill" : "person.fill")
                                .font(.caption)
                                .frame(width: 30, height: 30)
                                .foregroundStyle(speakerTint(person.id, isMicrophone: person.isMicrophone))
                                .background(speakerTint(person.id, isMicrophone: person.isMicrophone).opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                if person.isMicrophone {
                                    Text(person.name).font(.callout.weight(.medium))
                                } else {
                                    Button(person.name) { editingSpeaker = person }
                                        .buttonStyle(.plain)
                                        .font(.callout.weight(.medium))
                                        .disabled(isAnalyzingSpeakers)
                                }
                                Text(person.isMicrophone ? "Your microphone" : speakerTurnCount(person.id))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if person.isMicrophone {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .help("Your microphone always belongs to you")
                            } else {
                                Menu { speakerActions(person) } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .frame(width: 22)
                                .disabled(isAnalyzingSpeakers)
                                .help("Edit or merge this speaker")
                            }
                        }
                        .padding(11)
                        .contextMenu {
                            if !person.isMicrophone { speakerActions(person) }
                        }
                        if person.id != document.speakers?.last?.id {
                            Divider().padding(.leading, 50)
                        }
                    }
                }
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))

                if !remoteSpeakers.isEmpty {
                    Menu {
                        ForEach(remoteSpeakers) { target in
                            Button("Keep " + target.name) {
                                _ = applySpeakerEdit("Combine remote speakers") { $0.mergeAllRemoteSpeakers(into: target.id) }
                            }
                        }
                    } label: {
                        Label("Only one other person", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.callout)
                    }
                    .disabled(isAnalyzingSpeakers || (remoteSpeakers.count == 1 && document.expectedRemoteSpeakerCount == 1))
                    .help("Combine all remote labels into the chosen person. You can undo this.")
                }
                HStack(spacing: 6) {
                    TextField("Add a speaker", text: $newSpeakerName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addSpeaker)
                    Button(action: addSpeaker) { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.borderless)
                        .disabled(newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(isAnalyzingSpeakers)
                if let error = savedPeople.lastError {
                    Text("Saved people: " + error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Names are optional. Speaker changes keep the original audio and timing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func speakerActions(_ person: DocumentSpeaker) -> some View {
        Button("Edit name…") { editingSpeaker = person }
            .disabled(isAnalyzingSpeakers)
        if remoteSpeakers.contains(where: { $0.id != person.id }) {
            Menu("Merge into") {
                ForEach(remoteSpeakers.filter { $0.id != person.id }) { target in
                    Button(target.name) {
                        _ = applySpeakerEdit("Merge speakers") { $0.mergeSpeaker(id: person.id, into: target.id) }
                    }
                }
            }
            .disabled(isAnalyzingSpeakers)
        }
    }

    private func speakerTurnCount(_ id: UUID) -> String {
        let count = document.segments.filter { $0.speakerID == id }.count
        return count == 0 ? "Not assigned yet" : count == 1 ? "1 turn" : "\(count) turns"
    }

    private func commitTitle() {
        do {
            _ = try DocumentEditing.updateTitle(title, documentID: document.id, library: library)
        } catch {
            documentEditError = error.localizedDescription
        }
    }

    private func commitSegmentEdit(_ segmentID: UUID, text: String) -> Bool {
        let oldText: String
        do {
            guard let savedOldText = try DocumentEditing.updateSegmentText(
                text, segmentID: segmentID, documentID: document.id, library: library
            ) else { return true }
            oldText = savedOldText
        } catch {
            documentEditError = error.localizedDescription
            return false
        }
        let corrections = DictationDiff.proposedCorrections(original: oldText, edited: text)
        guard (1...3).contains(corrections.count),
              oldText.split(whereSeparator: { $0.isWhitespace }).count
                == text.split(whereSeparator: { $0.isWhitespace }).count else { return true }
        correctionSuggestions = corrections.filter { correction in
            !replacements.rules.contains(where: { rule in
                rule.original.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(correction.wrong) == .orderedSame
                    && rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(correction.right) == .orderedSame
            })
        }
        return true
    }

    private func commitNoteEdit(_ noteID: UUID, text: String) -> Bool {
        do {
            _ = try DocumentEditing.updateNoteText(
                text, noteID: noteID, documentID: document.id, library: library
            )
            return true
        } catch {
            documentEditError = error.localizedDescription
            return false
        }
    }

    private func deleteNote(_ noteID: UUID) {
        do {
            _ = try DocumentEditing.deleteNote(noteID, documentID: document.id, library: library)
        } catch {
            documentEditError = error.localizedDescription
        }
    }

    private func dismissCorrectionSuggestion() {
        guard !correctionSuggestions.isEmpty else { return }
        correctionSuggestions.removeFirst()
    }

    private func addSpeaker() {
        if applySpeakerEdit("Add speaker", change: { $0.addRemoteSpeaker(name: newSpeakerName) != nil }) {
            newSpeakerName = ""
        }
    }

    private func saveSpeakerName(_ id: UUID, name: String, savedPersonID: UUID?, savePerson: Bool) throws {
        guard let current = library.document(id: document.id),
              current.speakers?.contains(where: { $0.id == id && !$0.isMicrophone }) == true,
              current.speakerAnalysisStatus != .running else { throw DocumentEditing.Failure.speakerUnavailable }
        let personID = try savePerson ? savedPeople.add(name: name).id : savedPersonID
        _ = try DocumentEditing.applySpeakerEdit(
            documentID: document.id,
            library: library,
            undoManager: undoManager,
            actionName: "Rename speaker",
            onUndoFailure: { documentEditError = $0 },
            change: { $0.renameSpeaker(id: id, to: name, savedPersonID: personID) }
        )
    }

    private func applySpeakerEdit(_ actionName: String, change: (inout ScribeDocument) -> Bool) -> Bool {
        do {
            _ = try DocumentEditing.applySpeakerEdit(
                documentID: document.id,
                library: library,
                undoManager: undoManager,
                actionName: actionName,
                onUndoFailure: { documentEditError = $0 },
                change: change
            )
            return true
        } catch {
            documentEditError = error.localizedDescription
            return false
        }
    }

    private func replaceAll() {
        guard !transcriptSearch.isEmpty else { return }
        let options: String.CompareOptions = matchCase ? [] : [.caseInsensitive]
        do {
            let changedSegments = try DocumentEditing.replaceAll(
                transcriptSearch,
                with: replacementText,
                options: options,
                documentID: document.id,
                library: library
            )
            replaceResult = changedSegments == 0
                ? "No segments changed"
                : changedSegments == 1 ? "1 segment changed" : "\(changedSegments) segments changed"
        } catch {
            replaceResult = nil
            documentEditError = error.localizedDescription
        }
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Exporter.render(document, as: .txt), forType: .string)
    }

    private func summarize() {
        summaries.start(document.id)
    }

}

private struct SpeakerNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let speaker: DocumentSpeaker
    let savedPeople: [SavedPerson]
    let onSave: (String, UUID?, Bool) throws -> Void
    @State private var name: String
    @State private var selectedPersonID: UUID?
    @State private var savePerson = false
    @State private var error: String?

    init(speaker: DocumentSpeaker, savedPeople: [SavedPerson], onSave: @escaping (String, UUID?, Bool) throws -> Void) {
        self.speaker = speaker
        self.savedPeople = savedPeople
        self.onSave = onSave
        _name = State(initialValue: speaker.name)
        _selectedPersonID = State(initialValue: speaker.savedPersonID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Name this speaker").font(.title2.bold())
                Text("Changes apply to this recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                TextField("Speaker name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, updated in
                        if let person = savedPeople.first(where: { $0.id == selectedPersonID }), person.name != updated {
                            selectedPersonID = nil
                        }
                    }
                Picker("Saved person", selection: $selectedPersonID) {
                    Text("Choose a saved person").tag(UUID?.none)
                    ForEach(savedPeople) { person in
                        Text(person.name).tag(Optional(person.id))
                    }
                }
                .onChange(of: selectedPersonID) { _, id in
                    if let person = savedPeople.first(where: { $0.id == id }) {
                        name = person.name
                        savePerson = false
                    }
                }
                if selectedPersonID == nil {
                    Toggle("Save person for other recordings", isOn: $savePerson)
                        .font(.callout)
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save name") {
                    do {
                        try onSave(name, selectedPersonID, savePerson)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 390)
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let speakerName: String
    let person: DocumentSpeaker?
    let availableSpeakers: [DocumentSpeaker]
    let showSpeaker: Bool
    let startsSpeakerGroup: Bool
    let canEditSpeaker: Bool
    let isActive: Bool
    let highlight: String
    let onSeek: () -> Void
    let onEdit: (String) -> Bool
    let onSpeakerChange: (UUID) -> Void
    let onRename: () -> Void
    let onMerge: (UUID) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    private var isMicrophone: Bool { segment.source == .microphone || person?.isMicrophone == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showSpeaker && startsSpeakerGroup {
                HStack(spacing: 8) {
                    if isMicrophone {
                        Label(speakerName, systemImage: "mic.fill")
                            .foregroundStyle(.blue)
                            .help("Your microphone always belongs to you")
                    } else {
                        Button(action: onRename) {
                            Text(speakerName.isEmpty ? "Speaker" : speakerName)
                                .foregroundStyle(speakerTint(person?.id, isMicrophone: false))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canEditSpeaker || person == nil)
                        .help("Name this speaker")
                        .contextMenu { speakerMenu }
                        Menu { speakerMenu } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 20)
                        .disabled(!canEditSpeaker)
                        .accessibilityLabel("Speaker actions for " + speakerName)
                        .help("Rename or merge this speaker")
                    }
                    Spacer()
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 20)
                .padding(.bottom, 6)
            }
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .lineSpacing(5)
                    .focused($focused)
                    .onSubmit { _ = onEdit(text) }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { _ = onEdit(text) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onSeek) {
                    Text(segment.start.clockString)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 44, alignment: .trailing)
                .help(isMicrophone ? "Jump playback here" : "Jump playback here. Right-click for speaker actions.")
                .contextMenu {
                    if !isMicrophone { speakerMenu }
                }
            }
            .padding(.vertical, 5)
            .overlay(alignment: .leading) {
                if isActive {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(width: 2)
                        .offset(x: -12)
                        .allowsHitTesting(false)
                }
            }
        }
        .contextMenu {
            if !isMicrophone { speakerMenu }
        }
        .onAppear { text = segment.text }
        .onChange(of: segment.text) { _, newValue in
            if !focused { text = newValue }
        }
    }

    @ViewBuilder
    private var speakerMenu: some View {
        Button("Edit speaker name…", action: onRename)
            .disabled(!canEditSpeaker || person == nil)
        if availableSpeakers.contains(where: { $0.id != segment.speakerID }) {
            Menu("Merge this speaker into") {
                ForEach(availableSpeakers.filter { $0.id != segment.speakerID }) { target in
                    Button(target.name) { onMerge(target.id) }
                }
            }
            .disabled(!canEditSpeaker || person == nil)
            Divider()
            Menu("Assign this turn to") {
                ForEach(availableSpeakers) { target in
                    Button {
                        onSpeakerChange(target.id)
                    } label: {
                        if target.id == segment.speakerID {
                            Label(target.name, systemImage: "checkmark")
                        } else {
                            Text(target.name)
                        }
                    }
                }
            }
            .disabled(!canEditSpeaker)
        }
    }
}

private func speakerTint(_ id: UUID?, isMicrophone: Bool) -> Color {
    if isMicrophone { return .blue }
    let light: [NSColor] = [
        .init(srgbRed: 0.48, green: 0.30, blue: 0.66, alpha: 1),
        .init(srgbRed: 0.12, green: 0.43, blue: 0.32, alpha: 1),
        .init(srgbRed: 0.64, green: 0.32, blue: 0.07, alpha: 1),
        .init(srgbRed: 0.62, green: 0.26, blue: 0.42, alpha: 1),
        .init(srgbRed: 0.09, green: 0.43, blue: 0.49, alpha: 1),
        .init(srgbRed: 0.31, green: 0.35, blue: 0.62, alpha: 1)
    ]
    let dark: [NSColor] = [
        .init(srgbRed: 0.75, green: 0.64, blue: 0.92, alpha: 1),
        .init(srgbRed: 0.52, green: 0.77, blue: 0.64, alpha: 1),
        .init(srgbRed: 0.89, green: 0.69, blue: 0.43, alpha: 1),
        .init(srgbRed: 0.88, green: 0.59, blue: 0.71, alpha: 1),
        .init(srgbRed: 0.46, green: 0.76, blue: 0.81, alpha: 1),
        .init(srgbRed: 0.63, green: 0.67, blue: 0.93, alpha: 1)
    ]
    let value = (id?.uuidString ?? "").unicodeScalars.reduce(UInt64(5_381)) { ($0 &* 33) &+ UInt64($1.value) }
    let index = Int(value % UInt64(light.count))
    return Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark[index] : light[index]
    })
}

private struct RecordingVideoView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}

struct MeetingNoteRow: View {
    let note: MeetingNote
    let onSeek: () -> Void
    let onEdit: (String) -> Bool
    let onDelete: () -> Void

    @State private var text = ""
    @State private var isEditing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onSeek) {
                Text(note.time.clockString)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Jump playback here")
            .frame(width: 56, alignment: .trailing)

            Image(systemName: "pencil.line")
                .foregroundStyle(Color.accentColor)

            if isEditing {
                TextField("Note", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commitEdit)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commitEdit() }
                    }
            } else {
                Text(LocalizedStringKey(note.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.10)))
        .contextMenu {
            Button("Edit") {
                isEditing = true
                DispatchQueue.main.async { focused = true }
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
        .onAppear { text = note.text }
        .onChange(of: note.text) { _, newValue in
            if !focused { text = newValue }
        }
    }

    private func commitEdit() {
        if onEdit(text) { isEditing = false }
    }
}

/// Bottom playback bar: transport controls, scrubber, and speed.
struct PlayerBar: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    let document: ScribeDocument
    @State private var waveformSamples: [Float] = []

    private static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        HStack(spacing: 12) {
            Button { playback.skip(by: -15) } label: {
                Image(systemName: "gobackward.15")
            }
            .help("Back 15 seconds")

            Button { playback.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.primary)
            }
            .help(playback.isPlaying ? "Pause" : "Play")

            Button { playback.skip(by: 15) } label: {
                Image(systemName: "goforward.15")
            }
            .help("Forward 15 seconds")

            Text("\(playback.currentTime.clockString) / \(playback.duration.clockString)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            StaticWaveformView(
                samples: waveformSamples,
                progress: playback.duration > 0 ? playback.currentTime / playback.duration : 0,
                onSeek: { playback.seek(to: $0 * playback.duration) }
            )
            .frame(height: 28)

            Menu {
                ForEach(Self.rates, id: \.self) { rate in
                    Button {
                        playback.rate = rate
                    } label: {
                        HStack {
                            Text(rateLabel(rate))
                            if playback.rate == rate { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Text(rateLabel(playback.rate))
                    .font(.callout.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .frame(width: 48)
            .help("Playback speed")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.bar)
        .task(id: document.id) {
            waveformSamples = []
            let urls = document.tracks.map {
                library.folder(for: document.id).appendingPathComponent($0.fileName)
            }
            waveformSamples = await WaveformSampler.samples(for: urls)
        }
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == 1.0 ? "1×" : String(format: "%g×", rate)
    }
}
