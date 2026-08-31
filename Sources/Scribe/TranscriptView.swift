import SwiftUI
import AppKit

/// The transcript reading/editing view: header with editable title and
/// metadata, optional AI summary, searchable timestamped segments that
/// follow playback, and a player bar at the bottom.
struct TranscriptView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var playback: PlaybackController
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

    private var visibleSegments: [TranscriptSegment] {
        guard !transcriptSearch.isEmpty else { return document.segments }
        let query = transcriptSearch.lowercased()
        return document.segments.filter { $0.text.lowercased().contains(query) }
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
        .alert("Summarization Failed", isPresented: summaryErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(summaryError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.bold())
                .onSubmit(commitTitle)

            HStack(spacing: 6) {
                Text(document.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(document.duration.clockString)
                if let model = document.modelUsed {
                    Text("·")
                    Text(ModelManager.catalog.first { $0.variant == model }?.displayName ?? model)
                }
                if document.isMeetingRecording {
                    Text("·")
                    Label("Meeting", systemImage: "person.2.wave.2")
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
            .font(.callout)
            .foregroundStyle(.secondary)

            if showFindReplace { findReplaceBar }
            if showPeople { peopleBar }

            if summarizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else if let summary = document.summary, !summary.isEmpty {
                DisclosureGroup {
                    Text(LocalizedStringKey(summary))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    Label("Summary", systemImage: "sparkles")
                        .font(.callout.bold())
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var segmentList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(visibleSegments) { segment in
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
                }
            }
            .listStyle(.plain)
            .overlay {
                if document.segments.isEmpty {
                    ContentUnavailableView(
                        "No speech detected",
                        systemImage: "waveform.slash",
                        description: Text("The audio didn't contain any recognizable speech.")
                    )
                } else if visibleSegments.isEmpty {
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
        .padding(.top, 4)
    }

    private var peopleBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
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
        doc.segments[index].text = text
        library.update(doc)
    }

    private func commitSpeakerChange(_ segmentID: UUID, speaker: String?) {
        guard var doc = library.document(id: document.id),
              let index = doc.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        doc.segments[index].speaker = speaker
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
        segment.source == .microphone ? .blue : .purple
    }
}

/// Bottom playback bar: transport controls, scrubber, and speed.
struct PlayerBar: View {
    @EnvironmentObject private var playback: PlaybackController
    let document: ScribeDocument

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

            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 0.1)
            )

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
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == 1.0 ? "1×" : String(format: "%g×", rate)
    }
}
