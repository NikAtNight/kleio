import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
            ReplacementSettings()
                .tabItem { Label("Cleanup", systemImage: "text.badge.checkmark") }
            WatchFolderSettings()
                .tabItem { Label("Watch Folders", systemImage: "folder.badge.gearshape") }
            DictationSettings()
                .tabItem { Label("Dictation", systemImage: "text.cursor") }
            AISettings()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 660, height: 500)
    }
}

struct DictationSettings: View {
    @EnvironmentObject private var dictation: DictationController
    @State private var accessibilityGranted = false

    var body: some View {
        Form {
            Toggle(
                "Enable system-wide dictation",
                isOn: Binding(
                    get: { dictation.enabled },
                    set: { dictation.setEnabled($0, promptForAccessibility: $0) }
                )
            )

            LabeledContent("Shortcut:") {
                Text("⌥ Space")
                    .font(.body.monospaced())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
            }

            LabeledContent("Automatic paste:") {
                HStack {
                    Label(
                        accessibilityGranted ? "Allowed" : "Needs Accessibility permission",
                        systemImage: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .foregroundStyle(accessibilityGranted ? Color.green : Color.orange)
                    if !accessibilityGranted {
                        Button("Allow…") {
                            dictation.requestAccessibility()
                            dictation.openAccessibilitySettings()
                        }
                    }
                }
            }

            LabeledContent("Status:", value: dictation.statusText)

            if dictation.phase == .recording {
                LevelMeter(label: "Microphone", icon: "mic.fill", level: dictation.level)
                HStack {
                    Button("Finish & Insert") { dictation.toggle() }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel", role: .destructive) { dictation.cancelRecording() }
                }
            } else {
                Button("Start Dictation") {
                    if !dictation.enabled {
                        dictation.setEnabled(true, promptForAccessibility: true)
                    }
                    dictation.toggle()
                }
                .disabled(dictation.phase != .idle)
            }

            Text("Dictation records only while the shortcut is active, transcribes with your selected local model, applies Cleanup rules, and inserts the result into the app you were using. Without Accessibility permission, the result is copied to the clipboard instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .onAppear { accessibilityGranted = dictation.isAccessibilityGranted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = dictation.isAccessibilityGranted
        }
    }
}

struct ReplacementSettings: View {
    @EnvironmentObject private var replacements: ReplacementStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Toggle("Remove filler words (um, uh, erm)", isOn: $replacements.removeFillerWords)
                Toggle("Case sensitive", isOn: $replacements.caseSensitive)
                Toggle("Only replace separate words", isOn: $replacements.wholeWords)
            }
            .formStyle(.grouped)

            HStack {
                Text("Global replacements")
                    .font(.headline)
                Spacer()
                Button("Import…", action: importRules)
                Button("Export…", action: exportRules)
                Button {
                    replacements.addRule()
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }

            List {
                ForEach($replacements.rules) { $rule in
                    HStack(spacing: 10) {
                        TextField("Original", text: $rule.original)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        TextField("Replacement", text: $rule.replacement)
                    }
                }
                .onDelete(perform: replacements.deleteRules)
            }
            .overlay {
                if replacements.rules.isEmpty {
                    ContentUnavailableView(
                        "No replacements",
                        systemImage: "arrow.left.arrow.right",
                        description: Text("Add common names or terms that Whisper consistently mishears.")
                    )
                }
            }

            Text("Cleanup is applied automatically to new file, recording, podcast, watch-folder, and dictation transcripts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func exportRules() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Scribe Replacements.json"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? JSONEncoder().encode(replacements.rules) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let decoded = try JSONDecoder().decode([TextReplacement].self, from: Data(contentsOf: url))
            replacements.rules = decoded
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

struct WatchFolderSettings: View {
    @EnvironmentObject private var watcher: WatchFolderManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Watched folders").font(.headline)
                    Text("New audio and video files are queued after they finish copying.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: chooseFolder) {
                    Label("Add Folder", systemImage: "plus")
                }
            }

            List {
                ForEach(watcher.folders) { folder in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            NSWorkspace.shared.open(folder.url)
                        } label: {
                            Image(systemName: "arrow.forward.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Open in Finder")
                        Button(role: .destructive) {
                            watcher.removeFolder(folder)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 170)
            .overlay {
                if watcher.folders.isEmpty {
                    ContentUnavailableView(
                        "No watched folders",
                        systemImage: "folder.badge.plus",
                        description: Text("Add a folder to turn incoming recordings into transcripts automatically.")
                    )
                }
            }

            Form {
                Toggle("Automatically transcribe new files", isOn: $watcher.autoTranscribe)
                Toggle("Export finished transcripts beside the source", isOn: $watcher.autoExport)
                LabeledContent("Export formats:") {
                    HStack(spacing: 12) {
                        ForEach([ExportFormat.txt, .md, .html, .srt, .vtt], id: \.self) { format in
                            Toggle(format.rawValue.uppercased(), isOn: formatBinding(format))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
                .disabled(!watcher.autoExport)
                if let last = watcher.lastImportedFile {
                    LabeledContent("Last imported:", value: last)
                }
            }
            .formStyle(.grouped)
        }
        .padding(20)
    }

    private func formatBinding(_ format: ExportFormat) -> Binding<Bool> {
        Binding(
            get: { watcher.exportFormats.contains(format) },
            set: { selected in
                if selected {
                    watcher.exportFormats.insert(format)
                } else {
                    watcher.exportFormats.remove(format)
                }
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        watcher.addFolder(url)
    }
}

struct GeneralSettings: View {
    @AppStorage("language") private var language = ""
    @AppStorage("translate") private var translate = false
    @AppStorage("automaticSpeakerRecognition") private var automaticSpeakerRecognition = false

    private static let languages: [(code: String, name: String)] = [
        ("", "Auto-detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("ja", "Japanese"), ("zh", "Chinese"), ("ko", "Korean"), ("ru", "Russian"),
        ("hi", "Hindi"), ("ar", "Arabic"), ("tr", "Turkish"), ("pl", "Polish"),
        ("uk", "Ukrainian"), ("sv", "Swedish"),
    ]

    var body: some View {
        Form {
            Picker("Spoken language:", selection: $language) {
                ForEach(Self.languages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .help("Auto-detect works well; setting it explicitly is faster and more accurate. English-only models always use English.")

            Toggle("Translate to English", isOn: $translate)
                .help("Transcribe non-English audio directly into English text")

            Toggle("Recognize speakers automatically", isOn: $automaticSpeakerRecognition)
                .help("Runs a second, fully local diarization pass. Additional Core ML models download on first use.")

            if automaticSpeakerRecognition {
                Text("Speaker recognition runs after Whisper for imports, mic recordings, and remote meeting audio. The first run downloads an additional local model; transcription still succeeds if diarization cannot run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Library:") {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([LibraryStore.baseURL])
                }
            }

            Text("Transcription runs entirely on this Mac. Audio and transcripts never leave your machine unless you use AI summaries.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

struct ModelSettings: View {
    @EnvironmentObject private var modelManager: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(ModelManager.catalog) { model in
                    ModelRow(model: model)
                }
            }
            .listStyle(.inset)
            .frame(height: 380)

            Text("Larger models are more accurate but slower. Small (English) is a good default for calls; Large v3 Turbo is the accuracy sweet spot on Apple Silicon.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }
}

struct ModelRow: View {
    @EnvironmentObject private var modelManager: ModelManager
    let model: WhisperModelInfo

    private var isDownloaded: Bool { modelManager.isDownloaded(model.variant) }
    private var isSelected: Bool { modelManager.selectedVariant == model.variant }
    private var progress: Double? { modelManager.downloadProgress[model.variant] }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if isDownloaded { modelManager.selectedVariant = model.variant }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isDownloaded)
            .help(isDownloaded ? "Use this model" : "Download the model first")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.body.weight(isSelected ? .semibold : .regular))
                Text(model.detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Text(model.sizeString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if let progress {
                ProgressView(value: progress)
                    .frame(width: 80)
                    .controlSize(.small)
            } else if isDownloaded {
                Button("Delete") {
                    modelManager.delete(model.variant)
                }
                .controlSize(.small)
                .disabled(isSelected && modelManager.downloadedVariants.count == 1)
            } else {
                Button("Download") {
                    Task { await modelManager.download(model.variant) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }
}

struct AISettings: View {
    @AppStorage("aiProvider") private var provider = SummaryService.Provider.anthropic.rawValue
    @AppStorage("aiAPIKey") private var apiKey = ""
    @AppStorage("aiModel") private var model = ""
    @AppStorage("summaryPrompt") private var prompt = ""

    private var selectedProvider: SummaryService.Provider {
        SummaryService.Provider(rawValue: provider) ?? .anthropic
    }

    var body: some View {
        Form {
            Picker("Provider:", selection: $provider) {
                ForEach(SummaryService.Provider.allCases) { p in
                    Text(p.displayName).tag(p.rawValue)
                }
            }

            SecureField("API key:", text: $apiKey)

            TextField("Model:", text: $model, prompt: Text(selectedProvider.defaultModel))

            VStack(alignment: .leading, spacing: 4) {
                Text("Summary prompt:")
                TextEditor(text: $prompt)
                    .font(.callout)
                    .frame(height: 110)
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text(SummaryService.defaultPrompt)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }

            Text("Summaries send the transcript to the provider you choose, using your own key. Leave the key empty to keep Scribe fully offline.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
