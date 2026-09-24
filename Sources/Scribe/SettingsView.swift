import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
            CalendarSettingsView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
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
    @AppStorage("dictationCleanupEnabled") private var cleanupEnabled = false
    @AppStorage("dictationCleanupBackend") private var cleanupBackend = TranscriptCleaner.preferredBackend.rawValue
    @AppStorage("dictationCleanupOllamaModel") private var ollamaModel = TranscriptCleaner.defaultOllamaModel
    @State private var ollamaModels: [String] = []

    private var selectedCleanupBackend: TranscriptCleaner.Backend {
        TranscriptCleaner.selectedBackend(
            preference: TranscriptCleaner.Backend(rawValue: cleanupBackend) ?? .ollama
        )
    }

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

            Toggle("Clean up dictation with a local model", isOn: $cleanupEnabled)

            if cleanupEnabled {
                Picker("Backend:", selection: $cleanupBackend) {
                    if AppleIntelligenceCleaner.isAvailable {
                        Text(TranscriptCleaner.Backend.appleIntelligence.displayName)
                            .tag(TranscriptCleaner.Backend.appleIntelligence.rawValue)
                    }
                    Text(TranscriptCleaner.Backend.ollama.displayName)
                        .tag(TranscriptCleaner.Backend.ollama.rawValue)
                }

                if selectedCleanupBackend == .ollama {
                    if !ollamaModels.isEmpty {
                        Picker("Ollama model:", selection: $ollamaModel) {
                            Text("Choose a model").tag("")
                            ForEach(ollamaModels, id: \.self) { installedModel in
                                Text(installedModel).tag(installedModel)
                            }
                        }
                    } else {
                        TextField("Ollama model:", text: $ollamaModel)
                    }
                }

                Text("Runs entirely on this Mac. scripts/setup-s1-mini.sh registers the recommended model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        .formStyle(.grouped)
        .onAppear { accessibilityGranted = dictation.isAccessibilityGranted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = dictation.isAccessibilityGranted
        }
        .task(id: "\(cleanupEnabled)-\(cleanupBackend)") {
            if cleanupBackend == TranscriptCleaner.Backend.appleIntelligence.rawValue,
               !AppleIntelligenceCleaner.isAvailable {
                cleanupBackend = TranscriptCleaner.Backend.ollama.rawValue
                return
            }
            guard cleanupEnabled, selectedCleanupBackend == .ollama else {
                ollamaModels = []
                return
            }
            ollamaModels = await OllamaClient().installedModels()
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
    @EnvironmentObject private var callDetection: CallDetectionController
    @AppStorage("language") private var language = ""
    @AppStorage("translate") private var translate = false
    @AppStorage("automaticSpeakerRecognition") private var automaticSpeakerRecognition = false
    @AppStorage("microphoneSpeakerName") private var microphoneName = "Me"
    @AppStorage("expectedRemoteSpeakerCount") private var speakerCount = 0
    @AppStorage("preferredInputDeviceUID") private var preferredInputDeviceUID = ""
    @AppStorage("manualAutoStopEnabled") private var manualAutoStopEnabled = false
    @State private var inputDevices = AudioDevices.inputDevices()

    private static let languages: [(code: String, name: String)] = [
        ("", "Auto-detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("ja", "Japanese"), ("zh", "Chinese"), ("ko", "Korean"), ("ru", "Russian"),
        ("hi", "Hindi"), ("ar", "Arabic"), ("tr", "Turkish"), ("pl", "Polish"),
        ("uk", "Ukrainian"), ("sv", "Swedish"),
    ]

    var body: some View {
        Form {
            Picker("Microphone:", selection: $preferredInputDeviceUID) {
                Text(systemDefaultLabel).tag("")
                ForEach(inputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }

            Picker("Spoken language:", selection: $language) {
                ForEach(Self.languages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .help("Auto-detect works well; setting it explicitly is faster and more accurate. English-only models always use English.")

            Toggle("Translate to English", isOn: $translate)
                .help("Transcribe non-English audio directly into English text")

            Section("Speakers") {
                TextField("My microphone name:", text: $microphoneName)
                RemoteSpeakerCountPicker(selection: $speakerCount)
                Text("Meeting recordings keep your microphone separate and detect the other speakers. Choose one other person to skip speaker-count guessing.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Also detect speakers in imported files", isOn: $automaticSpeakerRecognition)
                Text("Rename and merge people in a transcript. Saved names stay on this Mac; corrections never change a voice fingerprint.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Recording") {
                Toggle("Ask to record when a call is detected", isOn: $callDetection.enabled)
                Text("Shows a bottom-left prompt with Audio and Audio + screen. Detection needs Accessibility access and readable call controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if callDetection.enabled && !callDetection.accessibilityGranted {
                    Button("Open Accessibility Settings…") { callDetection.openAccessibilitySettings() }
                }
                Toggle("End meeting recordings when the call ends", isOn: $manualAutoStopEnabled)

                Text("Applies to recordings you start yourself. Kleio stops about 15 seconds after you leave the call (needs call detection above), when the meeting app closes, or when both sides stay silent for a few minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LibraryBackupSettings()

            LabeledContent("Library:") {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([LibraryStore.baseURL])
                }
            }

            Text("Recording, transcription, and speaker detection run locally. AI summaries use the provider you select in AI settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear {
            refreshInputDevices()
            AudioDevices.observeDeviceChanges { refreshInputDevices() }
        }
    }

    private var systemDefaultLabel: String {
        guard let defaultID = AudioDevices.defaultInputDeviceID(),
              let device = inputDevices.first(where: { $0.id == defaultID }) else {
            return "System default"
        }
        return "System default (\(device.name))"
    }

    private func refreshInputDevices() {
        inputDevices = AudioDevices.inputDevices()
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
            .frame(minHeight: 180)

            SpeakerModelSettings()
                .padding(.horizontal, 16)

            Text("Larger models are more accurate but slower. Small (English) is a good default for calls; Large v3 Turbo is the accuracy sweet spot on Apple Silicon.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Picker("Speaker detection", selection: $selectedModel) {
                    Text("Community-1").tag("community1")
                    Text("Sortformer · experimental").tag("sortformer")
                }
                Spacer()
                if downloading {
                    ProgressView().controlSize(.small)
                } else if ready {
                    Label("Ready offline", systemImage: "checkmark.circle").foregroundStyle(.secondary)
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
            }.disabled(downloading)
            Text(model == .sortformer
                 ? "Experimental option for 2 to 4 other participants. It may still split voices; the chosen count does not force an exact number of groups. Use Community-1 for automatic counting or larger calls."
                 : "Local speaker grouping for meetings and imported audio. A known participant count helps prevent false splits.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: selectedModel, initial: true) { _, _ in
            ready = SpeakerDiarizer.modelsReady(for: model)
            error = nil
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
    @AppStorage("aiOllamaModel") private var ollamaModel = ""
    @AppStorage("aiModel.claudeCode") private var claudeCodeModel = ""
    @AppStorage("aiModel.codex") private var codexModel = ""
    @AppStorage("aiModel.cursor") private var cursorModel = ""
    @AppStorage("summaryPrompt") private var prompt = ""
    @State private var ollamaModels: [String] = []
    @State private var cliModels: [SubscriptionCLI.ModelOption] = []

    private var selectedProvider: SummaryService.Provider {
        SummaryService.Provider(rawValue: provider) ?? .anthropic
    }

    private var modelBinding: Binding<String> {
        switch selectedProvider {
        case .ollama: return $ollamaModel
        case .claudeCode: return $claudeCodeModel
        case .codex: return $codexModel
        case .cursor: return $cursorModel
        case .anthropic, .openai, .appleIntelligence: return $model
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
            Picker("Provider:", selection: $provider) {
                ForEach(SummaryService.Provider.allCases) { p in
                    Text(p.displayName).tag(p.rawValue)
                }
            }

            if selectedProvider == .anthropic || selectedProvider == .openai {
                SecureField("API key:", text: $apiKey)
            }

            if let cli = selectedProvider.subscriptionCLI {
                SubscriptionCLIStatusRow(cli: cli)
            }

            if selectedProvider == .ollama, !ollamaModels.isEmpty {
                Picker("Model:", selection: $ollamaModel) {
                    Text("Choose a model").tag("")
                    ForEach(ollamaModels, id: \.self) { installedModel in
                        Text(SummaryService.supportsSummaries(model: installedModel)
                             ? installedModel : "\(installedModel) · Dictation cleanup only")
                            .tag(installedModel)
                            .disabled(!SummaryService.supportsSummaries(model: installedModel))
                    }
                }
            } else if let cli = selectedProvider.subscriptionCLI {
                Picker("Model:", selection: modelBinding) {
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
                    "Model:",
                    text: modelBinding,
                    prompt: Text(selectedProvider.defaultModel)
                )
            }

            if selectedProvider == .ollama, !SummaryService.supportsSummaries(model: ollamaModel) {
                Label("s1-mini is for dictation cleanup. Choose a general-purpose model for summaries.",
                      systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

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

            Text(privacyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
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
}

/// Shows whether a subscription CLI is installed and signed in. Sign-in
/// happens in the CLI itself; Kleio only opens Terminal on its login command.
private struct SubscriptionCLIStatusRow: View {
    let cli: SubscriptionCLI
    @State private var status: SubscriptionCLI.Status?
    @State private var loginError: String?

    var body: some View {
        LabeledContent("Account:") {
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
