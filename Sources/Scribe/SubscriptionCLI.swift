import Foundation

/// Summaries through a provider's own command-line tool, so they use the
/// subscription that tool is signed in to. Kleio never reads the tool's
/// credentials; it only runs the official CLI, like any other local caller.
///
/// These CLIs are coding agents and the transcript is untrusted text, so each
/// run turns off tools (or keeps them read-only), skips user plugins and MCP
/// servers, saves no session, and runs in an empty temporary folder.
enum SubscriptionCLI: String, CaseIterable {
    case claude
    case codex
    case cursor

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    var company: String {
        switch self {
        case .claude: return "Anthropic"
        case .codex: return "OpenAI"
        case .cursor: return "Cursor"
        }
    }

    var executableNames: [String] {
        switch self {
        case .claude: return ["claude"]
        case .codex: return ["codex"]
        case .cursor: return ["agent", "cursor-agent"]
        }
    }

    var installURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.com/product/claude-code")!
        case .codex: return URL(string: "https://developers.openai.com/codex/cli")!
        case .cursor: return URL(string: "https://cursor.com/cli")!
        }
    }

    var loginArguments: [String] {
        switch self {
        case .claude: return ["auth", "login"]
        case .codex: return ["login"]
        case .cursor: return ["login"]
        }
    }

    // MARK: Models

    struct ModelOption: Hashable {
        let id: String
        let name: String
    }

    /// Claude Code has no model list command, but these aliases always point
    /// to the latest model in each family.
    static let claudeModels = [
        ModelOption(id: "fable", name: "Fable (latest)"),
        ModelOption(id: "opus", name: "Opus (latest)"),
        ModelOption(id: "sonnet", name: "Sonnet (latest)"),
        ModelOption(id: "haiku", name: "Haiku (latest)"),
    ]

    var defaultModelName: String {
        switch self {
        case .claude: return "Default (Claude Code's choice)"
        case .codex: return "Default (Codex's choice)"
        case .cursor: return "Auto (Cursor's choice)"
        }
    }

    var modelListArguments: [String]? {
        switch self {
        case .claude: return nil
        case .codex: return ["debug", "models"]
        case .cursor: return ["models"]
        }
    }

    func models(from output: Data) -> [ModelOption] {
        switch self {
        case .claude:
            return Self.claudeModels
        case .codex:
            // The catalog also has internal models marked "hide".
            guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }
            return models
                .filter { $0["visibility"] as? String == "list" }
                .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
                .compactMap { model in
                    guard let slug = model["slug"] as? String else { return nil }
                    return ModelOption(id: slug, name: model["display_name"] as? String ?? slug)
                }
        case .cursor:
            // Lines look like "gpt-5.2 - GPT-5.2". "auto" is the default entry.
            let junk = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}"))
            return String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { line in
                let parts = line.components(separatedBy: " - ")
                guard parts.count >= 2 else { return nil }
                let id = parts[0].trimmingCharacters(in: junk)
                let name = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: junk)
                guard !id.isEmpty, !id.contains(" "), id != "auto" else { return nil }
                return ModelOption(id: id, name: name)
            }
        }
    }

    func availableModels() async -> [ModelOption] {
        guard let arguments = modelListArguments else { return models(from: Data()) }
        guard let executable = executableURL(),
              let result = try? await CLIProcess.run(executable, arguments: arguments, input: Data(),
                                                     workingDirectory: FileManager.default.temporaryDirectory,
                                                     timeout: 20),
              result.status == 0 else { return [] }
        return models(from: result.stdout)
    }

    // MARK: Locating the CLI

    /// Apps opened from Finder don't get the shell's PATH, so the official
    /// installers' locations are searched first.
    static func searchDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  path: String? = ProcessInfo.processInfo.environment["PATH"]) -> [URL] {
        var directories = [
            home.appendingPathComponent(".local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
        ]
        for entry in (path ?? "").split(separator: ":") where !entry.isEmpty {
            let url = URL(fileURLWithPath: String(entry))
            if !directories.contains(where: { $0.path == url.path }) { directories.append(url) }
        }
        return directories
    }

    func executableURL(in directories: [URL] = SubscriptionCLI.searchDirectories()) -> URL? {
        for directory in directories {
            for name in executableNames {
                let url = directory.appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    // MARK: Summaries

    struct Invocation: Equatable {
        let arguments: [String]
        let input: String
    }

    static let outputFileName = "summary.md"

    func invocation(system: String, message: String, model: String, workingDirectory: URL) -> Invocation {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        // Codex and Cursor have no system prompt option, so the instructions
        // lead the message instead.
        let combined = "<instructions>\n\(system)\n</instructions>\n\n\(message)"
        switch self {
        case .claude:
            var arguments = [
                "-p", "--output-format", "json",
                "--tools", "",
                "--strict-mcp-config",
                "--setting-sources", "",
                "--disable-slash-commands",
                "--no-session-persistence",
                "--permission-prompts", "none",
                "--system-prompt", system,
            ]
            if !model.isEmpty { arguments += ["--model", model] }
            return Invocation(arguments: arguments, input: message)
        case .codex:
            var arguments = [
                "exec",
                "--sandbox", "read-only",
                "--ephemeral",
                "--skip-git-repo-check",
                "--ignore-user-config",
                "--ignore-rules",
            ]
            for feature in ["shell_tool", "unified_exec", "plugins", "apps", "multi_agent",
                            "browser_use", "computer_use", "image_generation", "hooks"] {
                arguments += ["--disable", feature]
            }
            arguments += [
                "-c", "web_search=\"disabled\"",
                "-C", workingDirectory.path,
                "-o", workingDirectory.appendingPathComponent(Self.outputFileName).path,
            ]
            if !model.isEmpty { arguments += ["-m", model] }
            arguments.append("-")
            return Invocation(arguments: arguments, input: combined)
        case .cursor:
            var arguments = [
                "-p", "--output-format", "stream-json",
                "--mode", "ask",
                "--sandbox", "enabled",
                "--trust",
                "--workspace", workingDirectory.path,
            ]
            if !model.isEmpty { arguments += ["--model", model] }
            return Invocation(arguments: arguments, input: combined)
        }
    }

    func summaryText(from result: CLIProcess.Result, workingDirectory: URL) throws -> String {
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        let detail = Self.failureDetail(result)
        switch self {
        case .claude:
            guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
                throw SummaryService.SummaryError.badResponse(detail)
            }
            let text = json["result"] as? String ?? ""
            guard json["is_error"] as? Bool == false, json["subtype"] as? String == "success" else {
                throw SummaryService.SummaryError.badResponse(text.isEmpty ? detail : text)
            }
            guard json["stop_reason"] as? String == "end_turn" else {
                throw SummaryService.SummaryError.invalidOutput("The model stopped before finishing the summary.")
            }
            return text
        case .codex:
            guard result.status == 0 else { throw SummaryService.SummaryError.badResponse(detail) }
            let file = workingDirectory.appendingPathComponent(Self.outputFileName)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                throw SummaryService.SummaryError.badResponse("Codex finished without writing a summary.")
            }
            return text
        case .cursor:
            // The final answer is the assistant text after the last tool call.
            // Cursor's own `result` joins every turn's narration together.
            var answer = ""
            var finished = false
            var failure: String?
            for line in stdout.split(separator: "\n") {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "tool_call":
                    answer = ""
                case "assistant":
                    let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                    answer += content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                case "result":
                    if event["is_error"] as? Bool == false, event["subtype"] as? String == "success" {
                        finished = true
                    } else {
                        failure = event["result"] as? String ?? detail
                    }
                default:
                    break
                }
            }
            guard finished, result.status == 0 else {
                throw SummaryService.SummaryError.badResponse(failure ?? detail)
            }
            return answer
        }
    }

    private static func failureDetail(_ result: CLIProcess.Result) -> String {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        let text = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = text.split(separator: "\n").suffix(6).joined(separator: "\n")
        return tail.isEmpty ? "The CLI exited with status \(result.status)." : tail
    }

    func generate(system: String, message: String, model: String, timeout: TimeInterval = 300,
                  searching directories: [URL] = SubscriptionCLI.searchDirectories()) async throws -> String {
        guard let executable = executableURL(in: directories) else { throw SummaryService.SummaryError.noKey }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleio-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let call = invocation(system: system, message: message, model: model, workingDirectory: directory)
        let result = try await CLIProcess.run(executable, arguments: call.arguments, input: Data(call.input.utf8),
                                              workingDirectory: directory, timeout: timeout)
        return try summaryText(from: result, workingDirectory: directory)
    }

    // MARK: Sign-in

    enum Status: Equatable {
        case notInstalled
        case signedOut
        case signedIn
        case unknown(String)
    }

    var statusArguments: [String] {
        switch self {
        case .claude: return ["auth", "status", "--json"]
        case .codex: return ["login", "status"]
        case .cursor: return ["status"]
        }
    }

    func status(from result: CLIProcess.Result) -> Status {
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        switch self {
        case .claude:
            guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
                  let loggedIn = json["loggedIn"] as? Bool else { return .unknown(output) }
            return loggedIn ? .signedIn : .signedOut
        case .codex:
            return result.status == 0 ? .signedIn : .signedOut
        case .cursor:
            let lowered = output.lowercased()
            if lowered.contains("not logged in") { return .signedOut }
            return lowered.contains("logged in") ? .signedIn : .unknown(output)
        }
    }

    func currentStatus() async -> Status {
        guard let executable = executableURL() else { return .notInstalled }
        let directory = FileManager.default.temporaryDirectory
        do {
            let result = try await CLIProcess.run(executable, arguments: statusArguments, input: Data(),
                                                  workingDirectory: directory, timeout: 20)
            return status(from: result)
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// Opens Terminal on the CLI's own login command. A `.command` file opens
    /// in Terminal without asking for Automation access.
    func loginScript() -> String? {
        guard let executable = executableURL() else { return nil }
        let command = ([executable.path] + loginArguments).map(Self.shellQuoted).joined(separator: " ")
        return "#!/bin/zsh -l\n\(command)\necho\necho 'Return to Kleio and click Check Again.'\n"
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Runs a child process with its input on stdin, collecting all output.
/// Cancellation and the timeout both terminate the process.
enum CLIProcess {
    struct Result: Equatable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    enum RunError: LocalizedError, Equatable {
        case timedOut(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .timedOut(let seconds):
                return "The CLI didn't finish within \(Int(seconds)) seconds."
            }
        }
    }

    private final class Stopper: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false
        private(set) var timedOut = false

        /// Returns false when the run was stopped before the process started.
        func started(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            self.process = process
            if stopped, process.isRunning { process.terminate() }
            return !stopped
        }

        func stop(timedOut: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
            stopped = true
            self.timedOut = timedOut
            guard let process, process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    static func environment(for executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directories = [executable.deletingLastPathComponent()] + SubscriptionCLI.searchDirectories()
        var seen = Set<String>()
        environment["PATH"] = directories.map(\.path).filter { seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }

    static func run(_ executable: URL, arguments: [String], input: Data, workingDirectory: URL,
                    timeout: TimeInterval) async throws -> Result {
        let stopper = Stopper()
        let result: Result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.currentDirectoryURL = workingDirectory
                    process.environment = environment(for: executable)
                    // Output goes to files, not pipes. Some CLIs exit before
                    // flushing a pipe, and a helper process that inherits a
                    // pipe could keep a read waiting after the CLI exits.
                    let outputDirectory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("kleio-cli-\(UUID().uuidString)", isDirectory: true)
                    let outputURL = outputDirectory.appendingPathComponent("stdout")
                    let errorURL = outputDirectory.appendingPathComponent("stderr")
                    defer { try? FileManager.default.removeItem(at: outputDirectory) }
                    let stdin = Pipe()
                    let stdout: FileHandle, stderr: FileHandle
                    do {
                        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
                        stdout = try FileHandle(forWritingTo: outputURL)
                        stderr = try FileHandle(forWritingTo: errorURL)
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    defer { try? stdout.close(); try? stderr.close() }
                    process.standardInput = stdin
                    process.standardOutput = stdout
                    process.standardError = stderr
                    // A child that exits early must not kill Kleio with SIGPIPE.
                    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    _ = stopper.started(process)
                    let deadline = DispatchWorkItem { stopper.stop(timedOut: true) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

                    let writer = DispatchGroup()
                    DispatchQueue.global().async(group: writer) {
                        try? stdin.fileHandleForWriting.write(contentsOf: input)
                        try? stdin.fileHandleForWriting.close()
                    }
                    process.waitUntilExit()
                    writer.wait()
                    deadline.cancel()
                    let outputData = (try? Data(contentsOf: outputURL)) ?? Data()
                    let errorData = (try? Data(contentsOf: errorURL)) ?? Data()
                    continuation.resume(returning: Result(status: process.terminationStatus,
                                                          stdout: outputData, stderr: errorData))
                }
            }
        } onCancel: {
            stopper.stop(timedOut: false)
        }
        if stopper.timedOut { throw RunError.timedOut(timeout) }
        try Task.checkCancellation()
        return result
    }
}
