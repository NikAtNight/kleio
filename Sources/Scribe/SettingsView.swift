import SwiftUI

/// Settings pages, grouped the way the sidebar shows them.
enum SettingsPane: String, CaseIterable, Identifiable {
    case audio, calls, speakers
    case models, language, cleanup, watchFolders
    case calendar, ai
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: return "Audio Devices"
        case .calls: return "Call Detection"
        case .speakers: return "Speakers"
        case .models: return "Models"
        case .language: return "Language"
        case .cleanup: return "Find & Replace"
        case .watchFolders: return "Watch Folders"
        case .calendar: return "Calendar"
        case .ai: return "AI Summaries"
        case .library: return "Library & Backup"
        }
    }

    var icon: String {
        switch self {
        case .audio: return "mic.fill"
        case .calls: return "phone.fill"
        case .speakers: return "person.2.fill"
        case .models: return "cpu.fill"
        case .language: return "globe"
        case .cleanup: return "text.badge.checkmark"
        case .watchFolders: return "folder.fill"
        case .calendar: return "calendar"
        case .ai: return "sparkles"
        case .library: return "externaldrive.fill"
        }
    }

    var tint: Color {
        switch self {
        case .audio: return .pink
        case .calls: return .green
        case .speakers: return .orange
        case .models: return .blue
        case .language: return .teal
        case .cleanup: return .indigo
        case .watchFolders: return .cyan
        case .calendar: return .red
        case .ai: return .purple
        case .library: return .gray
        }
    }

    /// The open page. Writing it before `openSettings()` opens that page.
    static let storageKey = "settingsPane"

    static func select(_ pane: SettingsPane) {
        UserDefaults.standard.set(pane.rawValue, forKey: storageKey)
    }

    static let groups: [(title: String, panes: [SettingsPane])] = [
        ("Recording", [.audio, .calls, .speakers]),
        ("Transcription", [.models, .language, .cleanup, .watchFolders]),
        ("Integrations", [.calendar, .ai]),
        ("Library", [.library]),
    ]
}

struct SettingsView: View {
    @AppStorage(SettingsPane.storageKey) private var selection: SettingsPane = .audio

    var body: some View {
        // A plain split keeps the sidebar a fixed, readable width;
        // NavigationSplitView ignored its column width in this window.
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(SettingsPane.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.panes) { pane in
                            Label {
                                Text(pane.title)
                            } icon: {
                                Image(systemName: pane.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .tag(pane)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 215)
            Divider()
            pane(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(selection.title)
        .frame(minWidth: 780, idealWidth: 860, minHeight: 540, idealHeight: 640)
    }

    @ViewBuilder
    private func pane(_ pane: SettingsPane) -> some View {
        switch pane {
        case .audio: AudioSettings()
        case .calls: CallSettings()
        case .speakers: SpeakerSettings()
        case .models: ModelSettings()
        case .language: LanguageSettings()
        case .cleanup: ReplacementSettings()
        case .watchFolders: WatchFolderSettings()
        case .calendar: CalendarSettingsView()
        case .ai: AISettings()
        case .library: LibrarySettings()
        }
    }
}

/// A grouped-form footnote. Keeps explanatory text visually quieter than controls.
struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ReplacementSettings: View {
    @EnvironmentObject private var replacements: ReplacementStore

    var body: some View {
        Form {
            Section {
                Toggle("Remove filler words (um, uh, erm)", isOn: $replacements.removeFillerWords)
                Toggle("Case sensitive", isOn: $replacements.caseSensitive)
                Toggle("Only replace separate words", isOn: $replacements.wholeWords)
            }

            Section {
                if replacements.rules.isEmpty {
                    Text("No replacements yet. Add names or terms the model keeps mishearing.")
                        .foregroundStyle(.secondary)
                }
                ForEach($replacements.rules) { $rule in
                    HStack(spacing: 10) {
                        TextField("Original", text: $rule.original, prompt: Text("Heard as"))
                            .labelsHidden()
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        TextField("Replacement", text: $rule.replacement, prompt: Text("Replace with"))
                            .labelsHidden()
                        Button {
                            // Commit any in-progress edit first: a field still
                            // editing the removed row would write to the wrong rule.
                            let id = rule.id
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            DispatchQueue.main.async { replacements.rules.removeAll { $0.id == id } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this replacement")
                    }
                }
            } header: {
                HStack {
                    Text("Replacements")
                    Spacer()
                    Menu {
                        Button("Import…", action: importRules)
                        Button("Export…", action: exportRules)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button {
                        replacements.addRule()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
            } footer: {
                SettingsNote("Applied automatically to new recording, file, podcast, and watch-folder transcripts. Editing a word in a transcript can also suggest a replacement.")
            }
        }
        .formStyle(.grouped)
    }

    private func exportRules() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Kleio Replacements.json"
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
        Form {
            Section {
                if watcher.folders.isEmpty {
                    Text("No watched folders. Add one to turn incoming recordings into transcripts automatically.")
                        .foregroundStyle(.secondary)
                }
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
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop watching this folder")
                    }
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button(action: chooseFolder) {
                        Label("Add Folder", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
            } footer: {
                SettingsNote("New audio and video files are queued after they finish copying.")
            }

            Section {
                Toggle("Automatically transcribe new files", isOn: $watcher.autoTranscribe)
                Toggle("Export finished transcripts beside the source", isOn: $watcher.autoExport)
                LabeledContent("Export formats") {
                    HStack(spacing: 12) {
                        ForEach([ExportFormat.txt, .md, .html, .srt, .vtt], id: \.self) { format in
                            Toggle(format.rawValue.uppercased(), isOn: formatBinding(format))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
                .disabled(!watcher.autoExport)
                if let last = watcher.lastImportedFile {
                    LabeledContent("Last imported", value: last)
                }
            }
        }
        .formStyle(.grouped)
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

struct AudioSettings: View {
    @AppStorage("preferredInputDeviceUID") private var preferredInputDeviceUID = ""
    @AppStorage(AudioDevices.preferredOutputDeviceUIDKey) private var preferredOutputDeviceUID = ""
    @State private var inputDevices = AudioDevices.inputDevices()
    @State private var outputDevices = AudioDevices.outputDevices()

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $preferredInputDeviceUID) {
                    Text(systemDefaultLabel).tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Picker("Headset or speakers", selection: $preferredOutputDeviceUID) {
                    Text(systemDefaultOutputLabel).tag("")
                    ForEach(outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            } footer: {
                SettingsNote("App audio is recorded through the output your call plays on. Kleio doesn't change your Mac's sound settings. A Bluetooth headset's microphone lowers its audio quality, so a separate microphone works best with one.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshDevices()
            AudioDevices.observeDeviceChanges { refreshDevices() }
        }
    }

    private var systemDefaultLabel: String {
        guard let defaultID = AudioDevices.defaultInputDeviceID(),
              let device = inputDevices.first(where: { $0.id == defaultID }) else {
            return "System default"
        }
        return "System default (\(device.name))"
    }

    private var systemDefaultOutputLabel: String {
        guard let defaultID = AudioDevices.defaultOutputDeviceID(),
              let device = outputDevices.first(where: { $0.id == defaultID }) else {
            return "System default"
        }
        return "System default (\(device.name))"
    }

    private func refreshDevices() {
        inputDevices = AudioDevices.inputDevices()
        outputDevices = AudioDevices.outputDevices()
    }
}

struct CallSettings: View {
    @EnvironmentObject private var callDetection: CallDetectionController
    @AppStorage("manualAutoStopEnabled") private var manualAutoStopEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Ask to record when a call is detected", isOn: $callDetection.enabled)
                if callDetection.enabled && !callDetection.accessibilityGranted {
                    LabeledContent("Accessibility access") {
                        Button("Open Settings…") { callDetection.openAccessibilitySettings() }
                    }
                }
            } footer: {
                SettingsNote("Shows a prompt in the bottom-left corner with Audio and Audio + screen. Detection needs Accessibility access and readable call controls.")
            }

            Section {
                Toggle("End meeting recordings when the call ends", isOn: $manualAutoStopEnabled)
            } footer: {
                SettingsNote("Applies to recordings you start yourself. Kleio stops about 15 seconds after you leave the call (needs call detection above), when the meeting app closes, or when both sides stay silent for a few minutes.")
            }
        }
        .formStyle(.grouped)
    }
}

struct SpeakerSettings: View {
    @AppStorage("microphoneSpeakerName") private var microphoneName = "Me"
    @AppStorage("expectedRemoteSpeakerCount") private var speakerCount = 0
    @AppStorage("automaticSpeakerRecognition") private var automaticSpeakerRecognition = false

    var body: some View {
        Form {
            Section {
                TextField("My microphone name", text: $microphoneName)
                RemoteSpeakerCountPicker(selection: $speakerCount)
            } footer: {
                SettingsNote("Your microphone is always you. Choose one other person to keep all remote speech under one name and skip speaker-count guessing.")
            }

            Section {
                SpeakerModelSettings()
                Toggle("Also detect speakers in imported files", isOn: $automaticSpeakerRecognition)
            } header: {
                Text("Speaker detection")
            } footer: {
                SettingsNote("Rename and merge people in a transcript. Saved names stay on this Mac; corrections never change a voice fingerprint.")
            }
        }
        .formStyle(.grouped)
    }
}

struct LanguageSettings: View {
    @AppStorage("language") private var language = ""
    @AppStorage("translate") private var translate = false

    private static let languages: [(code: String, name: String)] = [
        ("", "Auto-detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("ja", "Japanese"), ("zh", "Chinese"), ("ko", "Korean"), ("ru", "Russian"),
        ("hi", "Hindi"), ("ar", "Arabic"), ("tr", "Turkish"), ("pl", "Polish"),
        ("uk", "Ukrainian"), ("sv", "Swedish"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Spoken language", selection: $language) {
                    ForEach(Self.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
            } footer: {
                SettingsNote("Auto-detect works well; setting it explicitly is faster and more accurate. English-only models always use English. Parakeet models stop with an error if they don't support the chosen language.")
            }

            Section {
                Toggle("Translate to English", isOn: $translate)
            } footer: {
                SettingsNote("Transcribes non-English audio directly into English text. Whisper models only.")
            }
        }
        .formStyle(.grouped)
    }
}

struct LibrarySettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Recordings folder") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([LibraryStore.baseURL])
                    }
                }
            } footer: {
                SettingsNote("Recording, transcription, and speaker detection run on this Mac. AI summaries use the provider you choose in AI Summaries.")
            }

            LibraryBackupSettings()
        }
        .formStyle(.grouped)
    }
}

struct ModelSettings: View {
    @EnvironmentObject private var modelManager: ModelManager
    @AppStorage(Transcriber.idleUnloadMinutesKey) private var idleUnloadMinutes = Transcriber.defaultIdleUnloadMinutes
    @State private var showsMoreWhisper = false

    /// Shown up front; the remaining Whisper builds sit behind a disclosure.
    private static let featuredWhisper: Set<String> = [
        "openai_whisper-small.en", "openai_whisper-large-v3-v20240930",
        "openai_whisper-large-v3-v20240930_626MB",
    ]

    private var downloaded: [TranscriptionModelInfo] {
        ModelManager.catalog.filter { modelManager.isDownloaded($0.variant) }
    }

    private func available(_ engine: TranscriptionModelEngine) -> [TranscriptionModelInfo] {
        ModelManager.catalog.filter { $0.engine == engine && !modelManager.isDownloaded($0.variant) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Transcription model", selection: $modelManager.selectedVariant) {
                    ForEach(downloaded) { model in
                        Text(model.displayName).tag(model.variant)
                    }
                    if !downloaded.contains(where: { $0.variant == modelManager.selectedVariant }) {
                        Text(ModelManager.displayName(for: modelManager.selectedVariant))
                            .tag(modelManager.selectedVariant)
                    }
                }
                Picker("Unload when idle", selection: $idleUnloadMinutes) {
                    Text("Never").tag(0)
                    Text("After 1 minute").tag(1)
                    Text("After 5 minutes").tag(5)
                    Text("After 10 minutes").tag(10)
                    Text("After 30 minutes").tag(30)
                    Text("After 1 hour").tag(60)
                }
            } header: {
                Text("In use")
            } footer: {
                SettingsNote("Used for meetings, imports, and watch folders. Unloading frees the model's memory after a stretch with no transcription; the next job reloads it in a few seconds.")
            }

            if !downloaded.isEmpty {
                Section("Downloaded") {
                    ForEach(downloaded) { ModelRow(model: $0) }
                }
            }

            let parakeet = available(.parakeet)
            if !parakeet.isEmpty {
                Section {
                    ForEach(parakeet) { ModelRow(model: $0) }
                } header: {
                    Text("Parakeet")
                } footer: {
                    SettingsNote(TranscriptionModelEngine.parakeet.summary)
                }
            }

            let whisper = available(.whisper)
            if !whisper.isEmpty {
                Section {
                    ForEach(whisper.filter { Self.featuredWhisper.contains($0.variant) }) { ModelRow(model: $0) }
                    let more = whisper.filter { !Self.featuredWhisper.contains($0.variant) }
                    if !more.isEmpty {
                        DisclosureGroup("More Whisper models (\(more.count))", isExpanded: $showsMoreWhisper) {
                            ForEach(more) { ModelRow(model: $0) }
                        }
                    }
                } header: {
                    Text("Whisper")
                } footer: {
                    SettingsNote(TranscriptionModelEngine.whisper.summary + " Compressed builds trade a little accuracy for a smaller download.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SpeakerModelSettings: View {
    @AppStorage("speakerDetectionModel") private var selectedModel = "community1"
    @State private var downloading = false
    @State private var ready = false
    @State private var error: String?

    private var model: SpeakerDetectionModel {
        SpeakerDetectionModel(rawValue: selectedModel) ?? .community1
    }

    var body: some View {
        Picker("Model", selection: $selectedModel) {
            Text("Community-1").tag("community1")
            Text("Sortformer (experimental)").tag("sortformer")
        }
        .disabled(downloading)
        .onChange(of: selectedModel, initial: true) { _, _ in
            ready = SpeakerDiarizer.modelsReady(for: model)
            error = nil
        }
        LabeledContent("Status") {
            if downloading {
                ProgressView().controlSize(.small)
            } else if ready {
                Label("Ready offline", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Download") {
                    downloading = true
                    error = nil
                    Task {
                        do { try await SpeakerDiarizer().prepareModels(for: model) }
                        catch { self.error = error.localizedDescription }
                        ready = SpeakerDiarizer.modelsReady(for: model)
                        downloading = false
                    }
                }
            }
        }
        SettingsNote(model == .sortformer
             ? "Experimental option for 2 to 4 other participants. It may still split voices; the chosen count does not force an exact number of groups. Use Community-1 for automatic counting or larger calls."
             : "Local speaker grouping for meetings and imported audio. A known participant count helps prevent false splits.")
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
}

struct ModelRow: View {
    @EnvironmentObject private var modelManager: ModelManager
    let model: TranscriptionModelInfo

    private var isDownloaded: Bool { modelManager.isDownloaded(model.variant) }
    private var isSelected: Bool { modelManager.selectedVariant == model.variant }
    private var progress: Double? { modelManager.downloadProgress[model.variant] }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                    if isDownloaded {
                        Text(model.engine.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(model.detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(model.sizeString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Group {
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 72)
                } else if isDownloaded {
                    HStack(spacing: 8) {
                        if isSelected {
                            Label("In use", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                        } else {
                            Button("Use") { modelManager.selectedVariant = model.variant }
                        }
                        Button {
                            modelManager.delete(model.variant)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete \(model.displayName)")
                        .disabled(isSelected && modelManager.downloadedVariants.count == 1)
                    }
                } else {
                    Button {
                        Task { await modelManager.download(model.variant) }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
            }
            .controlSize(.small)
            .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

struct AISettings: View {
    @AppStorage("aiProvider") private var provider = SummaryService.Provider.anthropic.rawValue
    @AppStorage("aiModel.anthropic") private var anthropicModel = ""
    @AppStorage("aiModel.openai") private var openaiModel = ""
    @AppStorage("aiOllamaModel") private var ollamaModel = ""
    @AppStorage("aiModel.claudeCode") private var claudeCodeModel = ""
    @AppStorage("aiModel.codex") private var codexModel = ""
    @AppStorage("aiModel.cursor") private var cursorModel = ""
    @AppStorage("summaryPrompt") private var prompt = ""
    @State private var ollamaModels: [String] = []
    @State private var cliModels: [SubscriptionCLI.ModelOption] = []
    @State private var apiKeyDraft = ""
    @State private var savedAPIKey = ""
    @State private var credentialError: String?
    @State private var migrationError: String?
    private let summarySettings = SummarySettings()

    private var selectedProvider: SummaryService.Provider {
        SummaryService.Provider(rawValue: provider) ?? .anthropic
    }

    private var modelBinding: Binding<String> {
        switch selectedProvider {
        case .ollama: return $ollamaModel
        case .claudeCode: return $claudeCodeModel
        case .codex: return $codexModel
        case .cursor: return $cursorModel
        case .anthropic: return $anthropicModel
        case .openai: return $openaiModel
        case .appleIntelligence: return .constant("")
        }
    }

    private var privacyNote: String {
        if let cli = selectedProvider.subscriptionCLI {
            return "Summaries run the \(cli.displayName) CLI on this Mac with its tools turned off. The transcript goes to \(cli.company) and counts toward your subscription's usage limits."
        }
        return selectedProvider == .appleIntelligence || selectedProvider == .ollama
            ? "Local providers never send the transcript off the Mac."
            : "Summaries send the transcript to the provider you choose, using your own key. Leave the key empty to keep Kleio fully offline."
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: Binding(get: { provider }, set: { value in
                    // Pin legacy settings to the old selection before switching.
                    summarySettings.captureLegacyProvider()
                    provider = value
                })) {
                    ForEach(SummaryService.Provider.allCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }

                if selectedProvider.usesAPIKey {
                    SecureField("API key", text: $apiKeyDraft)
                    HStack {
                        Button(apiKeyDraft.isEmpty ? "Remove Key" : "Save Key") { saveAPIKey() }
                            .disabled(apiKeyDraft == savedAPIKey)
                        Text(apiKeyDraft != savedAPIKey ? "Unsaved key"
                             : savedAPIKey.isEmpty ? "No key saved" : "Stored in Keychain")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let migrationError {
                    Text(migrationError).font(.caption).foregroundStyle(.red)
                    if selectedProvider.usesAPIKey, summarySettings.needsLegacyProvider {
                        Button("Move Older Settings to \(selectedProvider.displayName)") {
                            do {
                                try summarySettings.assignLegacySettings(to: selectedProvider)
                                loadAPIKey()
                            } catch {
                                self.migrationError = error.localizedDescription
                            }
                        }
                    }
                }
                if let credentialError {
                    Text(credentialError).font(.caption).foregroundStyle(.red)
                }
                if migrationError != nil || credentialError != nil {
                    Button("Retry Keychain") { loadAPIKey() }
                }

                if let cli = selectedProvider.subscriptionCLI {
                    SubscriptionCLIStatusRow(cli: cli)
                }

                if selectedProvider == .ollama, !ollamaModels.isEmpty {
                    Picker("Model", selection: $ollamaModel) {
                        Text("Choose a model").tag("")
                        ForEach(ollamaModels, id: \.self) { installedModel in
                            Text(SummaryService.supportsSummaries(model: installedModel)
                                 ? installedModel : "\(installedModel) · can't summarize")
                                .tag(installedModel)
                                .disabled(!SummaryService.supportsSummaries(model: installedModel))
                        }
                    }
                } else if let cli = selectedProvider.subscriptionCLI {
                    Picker("Model", selection: modelBinding) {
                        Text(cli.defaultModelName).tag("")
                        let saved = modelBinding.wrappedValue
                        // Keep a model chosen earlier visible even if the CLI no longer lists it.
                        if !saved.isEmpty, !cliModels.contains(where: { $0.id == saved }) {
                            Text(saved).tag(saved)
                        }
                        ForEach(cliModels, id: \.self) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                } else if selectedProvider != .appleIntelligence {
                    TextField(
                        "Model",
                        text: modelBinding,
                        prompt: Text(selectedProvider.defaultModel)
                    )
                }

                if selectedProvider == .ollama, !SummaryService.supportsSummaries(model: ollamaModel) {
                    Label("s1-mini is a text-cleanup model. Choose a general-purpose model for summaries.",
                          systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } footer: {
                SettingsNote(privacyNote)
            }

            Section("Summary prompt") {
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
        }
        .formStyle(.grouped)
        .onChange(of: provider, initial: true) { _, _ in loadAPIKey() }
        .task(id: provider) {
            ollamaModels = []
            cliModels = []
            if selectedProvider == .ollama {
                ollamaModels = await OllamaClient().installedModels()
            } else if let cli = selectedProvider.subscriptionCLI {
                cliModels = await cli.availableModels()
            }
        }
    }

    private func loadAPIKey() {
        apiKeyDraft = ""
        savedAPIKey = ""
        credentialError = nil
        migrationError = nil
        do { try summarySettings.migrateLegacySettings() }
        catch { migrationError = error.localizedDescription }
        guard selectedProvider.usesAPIKey else { return }
        do {
            savedAPIKey = try summarySettings.apiKey(for: selectedProvider)
            apiKeyDraft = savedAPIKey
        } catch {
            credentialError = error.localizedDescription
        }
    }

    private func saveAPIKey() {
        do {
            try summarySettings.saveAPIKey(apiKeyDraft, for: selectedProvider)
            loadAPIKey()
        } catch {
            credentialError = "The API key wasn't saved. \(error.localizedDescription)"
        }
    }
}

/// Shows whether a subscription CLI is installed and signed in. Sign-in
/// happens in the CLI itself; Kleio only opens Terminal on its login command.
private struct SubscriptionCLIStatusRow: View {
    let cli: SubscriptionCLI
    @State private var status: SubscriptionCLI.Status?
    @State private var loginError: String?

    var body: some View {
        LabeledContent("Account") {
            HStack(spacing: 8) {
                switch status {
                case nil:
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                case .signedIn:
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .signedOut:
                    Label("Not signed in", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Button("Sign In…", action: openLogin)
                case .notInstalled:
                    Label("\(cli.displayName) CLI not found", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Link("Install…", destination: cli.installURL)
                case .unknown:
                    Label("Couldn't check sign-in", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Button("Sign In…", action: openLogin)
                }
                Button("Check Again") { Task { await refresh() } }
                    .disabled(status == nil)
            }
        }
        .task(id: cli) { await refresh() }
        .alert("Couldn't open Terminal", isPresented: Binding(get: { loginError != nil },
                                                             set: { if !$0 { loginError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginError ?? "")
        }
    }

    private func refresh() async {
        status = nil
        status = await cli.currentStatus()
    }

    private func openLogin() {
        guard let script = cli.loginScript() else {
            status = .notInstalled
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kleio \(cli.displayName) Sign In.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnknown) }
        } catch {
            loginError = "Run `\(cli.executableNames[0]) \(cli.loginArguments.joined(separator: " "))` in Terminal, then click Check Again."
        }
    }
}
