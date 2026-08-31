import SwiftUI
import AppKit

/// The transcript reading/editing view: header with editable title and
/// metadata, optional AI summary, searchable timestamped segments that
/// follow playback, and a player bar at the bottom.
struct TranscriptView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var replacements: ReplacementStore
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var voiceProfiles = VoiceProfileStore.shared
    let document: ScribeDocument

    @State private var title: String = ""
    @State private var transcriptSearch = ""
    @State private var replacementText = ""
    @State private var showFindReplace = false
    @State private var matchCase = false
    @State private var replaceResult: String?
    @State private var showPeople = false
    @State private var newSpeakerName = ""
    @State private var summarizing = false
    @State private var summaryError: String?
    @State private var correctionSuggestions: [(wrong: String, right: String)] = []

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

    private var activeSegmentID: UUID? {
        guard playback.documentID == document.id else { return nil }
        let time = playback.currentTime
        return document.segments.last { $0.start <= time && time < max($0.end, $0.start + 0.5) }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            segmentList
            Divider()
            PlayerBar(document: document)
        }
        .toolbar { toolbarContent }
        .task(id: document.id) {
            title = document.title
            await playback.load(document: document)
        }
        .onDisappear {
            if playback.documentID == document.id { playback.unload() }
        }
        .onChange(of: appState.selection) { _, _ in
            correctionSuggestions = []
        }
        .alert("Summarization Failed", isPresented: summaryErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(summaryError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.bold())
                .onSubmit(commitTitle)

            HStack(spacing: 8) {
                metadataItem(document.createdAt.formatted(date: .abbreviated, time: .shortened))
                metadataItem(document.duration.clockString)
                if let model = document.modelUsed {
                    metadataItem(ModelManager.catalog.first { $0.variant == model }?.displayName ?? model)
                }
                if document.isMeetingRecording {
                    Label("Meeting", systemImage: "person.2.wave.2")
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                Spacer()
                TextField("Find in transcript", text: $transcriptSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Button {
                    showFindReplace.toggle()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .help("Find and replace")
            }
            .foregroundStyle(.secondary)

            if showFindReplace { findReplaceBar }
            if let suggestion = correctionSuggestions.first {
                correctionSuggestion(suggestion)
            }
            if showPeople { peopleBar }

            if summarizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else if let summary = document.summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Summary", systemImage: "sparkles")
                        .font(.callout.bold())
                    // LocalizedStringKey keeps the AI summary's markdown rendering.
                    Text(LocalizedStringKey(summary))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func metadataItem(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.08)))
    }

    private var segmentList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(timelineRows) { row in
                    switch row {
                    case .segment(let segment):
                        SegmentRow(
                            segment: segment,
                            speakerName: document.speakerName(for: segment),
                            availableSpeakers: document.availableSpeakerNames,
                            showSpeaker: document.hasSpeakerLabels,
                            isActive: segment.id == activeSegmentID,
                            highlight: transcriptSearch,
                            onSeek: { playback.seek(to: segment.start) },
                            onEdit: { newText in commitSegmentEdit(segment.id, text: newText) },
                            onSpeakerChange: { speaker in commitSpeakerChange(segment.id, speaker: speaker) }
                        )
                        .id(segment.id)
                        .listRowSeparator(.hidden)
                    case .note(let note):
                        MeetingNoteRow(
                            note: note,
                            onSeek: { playback.seek(to: note.time) },
                            onEdit: { newText in commitNoteEdit(note.id, text: newText) },
                            onDelete: { deleteNote(note.id) }
                        )
                        .id(note.id)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
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

            Button {
                showPeople.toggle()
            } label: {
                Label("People", systemImage: "person.2")
            }
            .help("Add, rename, and assign speakers")

            Button {
                summarize()
            } label: {
                Label("Summarize", systemImage: "sparkles")
            }
            .help(SummaryService.isConfigured
                  ? "Generate an AI summary"
                  : "Add an API key in Settings → AI to enable summaries")
            .disabled(summarizing || document.segments.isEmpty)
        }
    }

    private var summaryErrorBinding: Binding<Bool> {
        Binding(get: { summaryError != nil }, set: { if !$0 { summaryError = nil } })
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

    private var peopleBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("People", systemImage: "person.2")
                    .font(.callout.bold())
                Text("Click a speaker badge on any segment to assign it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(document.availableSpeakerNames, id: \.self) { speaker in
                    SpeakerEditorChip(name: speaker) { newName in
                        renameSpeaker(speaker, to: newName)
                    }
                }
                TextField("New speaker", text: $newSpeakerName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .onSubmit(addSpeaker)
                Button(action: addSpeaker) {
                    Image(systemName: "plus")
                }
                .disabled(newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .padding(.top, 4)
    }

    private func commitTitle() {
        guard var doc = library.document(id: document.id), !title.isEmpty, doc.title != title else { return }
        doc.title = title
        library.update(doc)
    }

    private func commitSegmentEdit(_ segmentID: UUID, text: String) {
        guard var doc = library.document(id: document.id),
              let index = doc.segments.firstIndex(where: { $0.id == segmentID }),
              doc.segments[index].text != text else { return }
        let oldText = doc.segments[index].text
        doc.segments[index].text = text
        library.update(doc)
        let corrections = DictationDiff.proposedCorrections(original: oldText, edited: text)
        guard (1...3).contains(corrections.count),
              oldText.split(whereSeparator: { $0.isWhitespace }).count
                == text.split(whereSeparator: { $0.isWhitespace }).count else { return }
        correctionSuggestions = corrections.filter { correction in
            !replacements.rules.contains(where: { rule in
                rule.original.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(correction.wrong) == .orderedSame
                    && rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(correction.right) == .orderedSame
            })
        }
    }

    private func commitNoteEdit(_ noteID: UUID, text: String) {
        guard var doc = library.document(id: document.id),
              let index = doc.notes?.firstIndex(where: { $0.id == noteID }),
              doc.notes?[index].text != text else { return }
        doc.notes?[index].text = text
        library.update(doc)
    }

    private func deleteNote(_ noteID: UUID) {
        guard var doc = library.document(id: document.id) else { return }
        doc.notes?.removeAll { $0.id == noteID }
        library.update(doc)
    }

    private func dismissCorrectionSuggestion() {
        guard !correctionSuggestions.isEmpty else { return }
        correctionSuggestions.removeFirst()
    }

    private func commitSpeakerChange(_ segmentID: UUID, speaker: String?) {
        guard var doc = library.document(id: document.id),
              let index = doc.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        doc.segments[index].speaker = speaker
        // A single reassigned segment is not enough evidence to learn a voice.
        if let speaker, !speaker.isEmpty {
            var known = doc.knownSpeakers ?? []
            if !known.contains(speaker) { known.append(speaker) }
            doc.knownSpeakers = known
        }
        library.update(doc)
    }

    private func addSpeaker() {
        let name = newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var doc = library.document(id: document.id) else { return }
        var known = doc.knownSpeakers ?? []
        if !known.contains(name) { known.append(name) }
        doc.knownSpeakers = known
        library.update(doc)
        newSpeakerName = ""
    }

    private func renameSpeaker(_ oldName: String, to proposedName: String) {
        let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != oldName,
              var doc = library.document(id: document.id) else { return }
        for index in doc.segments.indices where doc.speakerName(for: doc.segments[index]) == oldName {
            doc.segments[index].speaker = newName
        }
        var known = (doc.knownSpeakers ?? []).map { $0 == oldName ? newName : $0 }
        if !known.contains(newName) { known.append(newName) }
        var seen = Set<String>()
        doc.knownSpeakers = known.filter { seen.insert($0).inserted }
        if let embedding = doc.speakerVoiceprints?[oldName] {
            if voiceProfiles.hasProfile(named: oldName) {
                voiceProfiles.renameProfile(from: oldName, to: newName)
            }
            if voiceProfiles.isRecognitionEnabled {
                voiceProfiles.learn(name: newName, embedding: embedding)
            }
            doc.rekeySpeakerVoiceprint(from: oldName, to: newName)
        }
        library.update(doc)
    }

    private func replaceAll() {
        guard !transcriptSearch.isEmpty, var doc = library.document(id: document.id) else { return }
        let options: String.CompareOptions = matchCase ? [] : [.caseInsensitive]
        var changedSegments = 0
        for index in doc.segments.indices {
            let oldText = doc.segments[index].text
            let newText = oldText.replacingOccurrences(
                of: transcriptSearch,
                with: replacementText,
                options: options
            )
            if newText != oldText {
                doc.segments[index].text = newText
                changedSegments += 1
            }
        }
        library.update(doc)
        replaceResult = changedSegments == 1 ? "1 segment changed" : "\(changedSegments) segments changed"
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Exporter.render(document, as: .txt), forType: .string)
    }

    private func summarize() {
        guard SummaryService.isConfigured else {
            summaryError = SummaryService.SummaryError.noKey.localizedDescription
            return
        }
        summarizing = true
        Task {
            do {
                let summary = try await SummaryService.summarize(document)
                if var doc = library.document(id: document.id) {
                    doc.summary = summary
                    library.update(doc)
                }
            } catch {
                summaryError = error.localizedDescription
            }
            summarizing = false
        }
    }
}

struct SpeakerEditorChip: View {
    let name: String
    let onRename: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Speaker", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.caption.bold())
            .frame(width: 110)
            .focused($focused)
            .onSubmit { onRename(text) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { onRename(text) }
            }
            .onAppear { text = name }
            .onChange(of: name) { _, newValue in
                if !focused { text = newValue }
            }
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let speakerName: String
    let availableSpeakers: [String]
    let showSpeaker: Bool
    let isActive: Bool
    let highlight: String
    let onSeek: () -> Void
    let onEdit: (String) -> Void
    let onSpeakerChange: (String?) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onSeek) {
                Text(segment.start.clockString)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Jump playback here")
            .frame(width: 56, alignment: .trailing)

            if showSpeaker {
                Menu {
                    ForEach(availableSpeakers, id: \.self) { speaker in
                        Button {
                            onSpeakerChange(speaker)
                        } label: {
                            if speaker == speakerName {
                                Label(speaker, systemImage: "checkmark")
                            } else {
                                Text(speaker)
                            }
                        }
                    }
                    Divider()
                    Button("No Speaker") { onSpeakerChange(nil) }
                } label: {
                    Text(speakerName.isEmpty ? "Speaker" : speakerName)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(speakerColor.opacity(0.18)))
                        .foregroundStyle(speakerColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focused)
                .onSubmit { onEdit(text) }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { onEdit(text) }
                }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.10) : .clear)
        )
        .onAppear { text = segment.text }
        .onChange(of: segment.text) { _, newValue in
            if !focused { text = newValue }
        }
    }

    private var speakerColor: Color {
        switch speakerName {
        case "You": return .blue
        case "Them": return .purple
        default:
            let palette: [Color] = [.blue, .purple, .green, .orange, .pink, .teal]
            let value = speakerName.unicodeScalars.reduce(UInt64(5_381)) { partial, scalar in
                (partial &* 33) &+ UInt64(scalar.value)
            }
            return palette[Int(value % UInt64(palette.count))]
        }
    }
}

struct MeetingNoteRow: View {
    let note: MeetingNote
    let onSeek: () -> Void
    let onEdit: (String) -> Void
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
        onEdit(text)
        isEditing = false
    }
}

/// Bottom playback bar: transport controls, scrubber, and speed.
struct PlayerBar: View {
    @EnvironmentObject private var playback: PlaybackController
    let document: ScribeDocument
    @State private var waveformSamples: [Float] = []

    private static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        HStack(spacing: 14) {
            Button { playback.skip(by: -15) } label: {
                Image(systemName: "gobackward.15")
            }
            .help("Back 15 seconds")

            Button { playback.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
            }
            .help(playback.isPlaying ? "Pause" : "Play")

            Button { playback.skip(by: 15) } label: {
                Image(systemName: "goforward.15")
            }
            .help("Forward 15 seconds")

            Text(playback.currentTime.clockString)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)

            StaticWaveformView(
                samples: waveformSamples,
                progress: playback.duration > 0 ? playback.currentTime / playback.duration : 0,
                onSeek: { playback.seek(to: $0 * playback.duration) }
            )
            .frame(height: 44)

            Text(playback.duration.clockString)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

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
            .frame(width: 64)
            .help("Playback speed")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .task(id: document.id) {
            waveformSamples = []
            let urls = document.tracks.map {
                LibraryStore.folder(for: document.id).appendingPathComponent($0.fileName)
            }
            waveformSamples = await WaveformSampler.samples(for: urls)
        }
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == 1.0 ? "1×" : String(format: "%g×", rate)
    }
}
