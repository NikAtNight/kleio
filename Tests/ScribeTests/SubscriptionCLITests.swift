import Foundation
import XCTest
@testable import Scribe

final class SubscriptionCLITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kleio-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func script(_ name: String, _ body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func result(_ stdout: String, status: Int32 = 0, stderr: String = "") -> CLIProcess.Result {
        CLIProcess.Result(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    }

    private func pair(_ arguments: [String], _ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    func testEveryInvocationLocksDownTheAgent() {
        let claude = SubscriptionCLI.claude.invocation(system: "SYSTEM", message: "MESSAGE", model: "", workingDirectory: directory)
        XCTAssertEqual(pair(claude.arguments, "--tools"), "")
        XCTAssertEqual(pair(claude.arguments, "--setting-sources"), "")
        XCTAssertEqual(pair(claude.arguments, "--system-prompt"), "SYSTEM")
        XCTAssertTrue(claude.arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(claude.arguments.contains("--no-session-persistence"))
        XCTAssertFalse(claude.arguments.contains("--model"))
        XCTAssertEqual(claude.input, "MESSAGE")

        let codex = SubscriptionCLI.codex.invocation(system: "SYSTEM", message: "MESSAGE", model: " gpt-x ", workingDirectory: directory)
        XCTAssertEqual(pair(codex.arguments, "--sandbox"), "read-only")
        XCTAssertEqual(pair(codex.arguments, "-C"), directory.path)
        XCTAssertEqual(pair(codex.arguments, "-m"), "gpt-x")
        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check"] {
            XCTAssertTrue(codex.arguments.contains(flag), flag)
        }
        let disabled = codex.arguments.indices.filter { codex.arguments[$0] == "--disable" }.map { codex.arguments[$0 + 1] }
        XCTAssertTrue(disabled.contains("shell_tool"))
        XCTAssertTrue(disabled.contains("unified_exec"))
        XCTAssertEqual(codex.arguments.last, "-")
        XCTAssertTrue(codex.input.hasPrefix("<instructions>\nSYSTEM\n</instructions>"))
        XCTAssertTrue(codex.input.hasSuffix("MESSAGE"))

        let cursor = SubscriptionCLI.cursor.invocation(system: "SYSTEM", message: "MESSAGE", model: "", workingDirectory: directory)
        XCTAssertEqual(pair(cursor.arguments, "--mode"), "ask")
        XCTAssertEqual(pair(cursor.arguments, "--sandbox"), "enabled")
        XCTAssertEqual(pair(cursor.arguments, "--workspace"), directory.path)
        XCTAssertFalse(cursor.arguments.contains("--force"))
        XCTAssertFalse(cursor.arguments.contains("--approve-mcps"))
        XCTAssertTrue(cursor.input.contains("SYSTEM") && cursor.input.contains("MESSAGE"))
    }

    func testClaudeOutputRequiresACompleteSuccessfulResult() throws {
        let ok = ###"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","result":"## Summary\nDone."}"###
        XCTAssertEqual(try SubscriptionCLI.claude.summaryText(from: result(ok), workingDirectory: directory), "## Summary\nDone.")

        let failed = ###"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"###
        XCTAssertThrowsError(try SubscriptionCLI.claude.summaryText(from: result(failed, status: 1), workingDirectory: directory)) {
            XCTAssertTrue($0.localizedDescription.contains("Not logged in"))
        }

        let truncated = ###"{"type":"result","subtype":"success","is_error":false,"stop_reason":"max_tokens","result":"## Sum"}"###
        XCTAssertThrowsError(try SubscriptionCLI.claude.summaryText(from: result(truncated), workingDirectory: directory))
        XCTAssertThrowsError(try SubscriptionCLI.claude.summaryText(from: result("", status: 1, stderr: "boom"), workingDirectory: directory))
    }

    func testCursorKeepsOnlyTheAnswerAfterTheLastToolCall() throws {
        let stream = [
            ###"{"type":"system","subtype":"init"}"###,
            ###"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look around."}]}}"###,
            ###"{"type":"tool_call","subtype":"started"}"###,
            ###"{"type":"tool_call","subtype":"completed"}"###,
            ###"{"type":"assistant","message":{"content":[{"type":"text","text":"## Summary\n"}]}}"###,
            ###"{"type":"assistant","message":{"content":[{"type":"text","text":"The team shipped."}]}}"###,
            ###"{"type":"result","subtype":"success","is_error":false,"result":"Let me look around.## Summary\nThe team shipped."}"###,
        ].joined(separator: "\n")
        XCTAssertEqual(try SubscriptionCLI.cursor.summaryText(from: result(stream), workingDirectory: directory),
                       "## Summary\nThe team shipped.")

        let unfinished = ###"{"type":"assistant","message":{"content":[{"type":"text","text":"Partial"}]}}"###
        XCTAssertThrowsError(try SubscriptionCLI.cursor.summaryText(from: result(unfinished), workingDirectory: directory))
        let failed = ###"{"type":"result","subtype":"error","is_error":true,"result":"Authentication required"}"###
        XCTAssertThrowsError(try SubscriptionCLI.cursor.summaryText(from: result(failed), workingDirectory: directory)) {
            XCTAssertTrue($0.localizedDescription.contains("Authentication required"))
        }
    }

    func testCodexReadsTheLastMessageFileOnlyAfterSuccess() throws {
        XCTAssertThrowsError(try SubscriptionCLI.codex.summaryText(from: result("", status: 1, stderr: "Not logged in"), workingDirectory: directory)) {
            XCTAssertTrue($0.localizedDescription.contains("Not logged in"))
        }
        XCTAssertThrowsError(try SubscriptionCLI.codex.summaryText(from: result(""), workingDirectory: directory))
        try "## Summary\nDone.".write(to: directory.appendingPathComponent(SubscriptionCLI.outputFileName), atomically: true, encoding: .utf8)
        XCTAssertEqual(try SubscriptionCLI.codex.summaryText(from: result("ignored"), workingDirectory: directory), "## Summary\nDone.")
    }

    func testSignInStatusParsing() {
        XCTAssertEqual(SubscriptionCLI.claude.status(from: result(###"{"loggedIn": true}"###)), .signedIn)
        XCTAssertEqual(SubscriptionCLI.claude.status(from: result(###"{"loggedIn": false}"###, status: 1)), .signedOut)
        XCTAssertEqual(SubscriptionCLI.codex.status(from: result("Logged in using ChatGPT")), .signedIn)
        XCTAssertEqual(SubscriptionCLI.codex.status(from: result("Not logged in", status: 1)), .signedOut)
        XCTAssertEqual(SubscriptionCLI.cursor.status(from: result("✓ Logged in as someone@example.com")), .signedIn)
        XCTAssertEqual(SubscriptionCLI.cursor.status(from: result("Not logged in")), .signedOut)
    }

    func testFindsCLIsOutsideTheAppPATH() throws {
        let home = directory.appendingPathComponent("home")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let directories = SubscriptionCLI.searchDirectories(home: home, path: "/usr/bin:/opt/homebrew/bin")
        XCTAssertEqual(directories.first?.path, bin.path)
        XCTAssertEqual(directories.filter { $0.path == "/opt/homebrew/bin" }.count, 1)
        XCTAssertTrue(directories.contains { $0.path == "/usr/bin" })

        XCTAssertNil(SubscriptionCLI.cursor.executableURL(in: [bin]))
        let fake = bin.appendingPathComponent("cursor-agent")
        try "#!/bin/sh\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        XCTAssertEqual(SubscriptionCLI.cursor.executableURL(in: [bin])?.path, fake.path)
    }

    func testProcessReceivesLargeInputAndRunsInTheGivenFolder() async throws {
        let echo = try script("echo-input", "pwd >&2\ncat")
        let input = String(repeating: "A transcript line that is long enough to fill pipes.\n", count: 5_000)
        let output = try await CLIProcess.run(echo, arguments: [], input: Data(input.utf8),
                                              workingDirectory: directory, timeout: 20)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), input)
        XCTAssertEqual(URL(fileURLWithPath: String(decoding: output.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
    }

    func testEarlyExitDoesNotCrashWhileWritingInput() async throws {
        let quits = try script("quits", "exit 3")
        let input = Data(repeating: 65, count: 1_000_000)
        let output = try await CLIProcess.run(quits, arguments: [], input: input, workingDirectory: directory, timeout: 20)
        XCTAssertEqual(output.status, 3)
    }

    func testTimeoutAndCancellationStopTheProcess() async throws {
        let slow = try script("slow", "exec sleep 30")
        let started = Date()
        do {
            _ = try await CLIProcess.run(slow, arguments: [], input: Data(), workingDirectory: directory, timeout: 0.5)
            XCTFail("Expected a timeout")
        } catch let error as CLIProcess.RunError {
            XCTAssertEqual(error, .timedOut(0.5))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)

        let task = Task { try await CLIProcess.run(slow, arguments: [], input: Data(), workingDirectory: self.directory, timeout: 60) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelled = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 10)
    }

    func testGenerateRunsAFakeCLIInATemporaryFolderAndCleansUp() async throws {
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("cwd.txt")
        let fake = bin.appendingPathComponent("claude")
        try """
        #!/bin/sh
        pwd > '\(log.path)'
        input=$(cat)
        printf '{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","result":"Got: %s"}' "$input"
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let summary = try await SubscriptionCLI.claude.generate(system: "SYSTEM", message: "hello", model: "",
                                                                searching: [bin])
        XCTAssertEqual(summary, "Got: hello")
        let workingDirectory = try String(contentsOf: log, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(workingDirectory.contains("kleio-summary-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory))

        do {
            _ = try await SubscriptionCLI.claude.generate(system: "S", message: "M", model: "", searching: [directory.appendingPathComponent("missing")])
            XCTFail("Expected a missing CLI error")
        } catch SummaryService.SummaryError.noKey {
        }
    }

    func testModelListsComeFromEachCLI() {
        XCTAssertNil(SubscriptionCLI.claude.modelListArguments)
        XCTAssertEqual(SubscriptionCLI.claude.models(from: Data()).map(\.id), ["fable", "opus", "sonnet", "haiku"])

        let catalog = ###"{"models":[{"slug":"gpt-b","display_name":"GPT-B","visibility":"list","priority":2},{"slug":"internal","display_name":"Internal","visibility":"hide","priority":0},{"slug":"gpt-a","display_name":"GPT-A","visibility":"list","priority":1}]}"###
        XCTAssertEqual(SubscriptionCLI.codex.models(from: Data(catalog.utf8)),
                       [.init(id: "gpt-a", name: "GPT-A"), .init(id: "gpt-b", name: "GPT-B")])
        XCTAssertEqual(SubscriptionCLI.codex.models(from: Data("not json".utf8)), [])

        let listing = "Available models\n\nauto - Auto (current, default)\ngpt-5.2 - GPT-5.2\ngrok-4.7-low-fast - Grok 4.7  Low Fast\u{200B}\u{200B}\nclaude-x - Claude X - Preview\n"
        XCTAssertEqual(SubscriptionCLI.cursor.models(from: Data(listing.utf8)), [
            .init(id: "gpt-5.2", name: "GPT-5.2"),
            .init(id: "grok-4.7-low-fast", name: "Grok 4.7  Low Fast"),
            .init(id: "claude-x", name: "Claude X - Preview"),
        ])
    }

    func testSubscriptionProvidersKeepSeparateModels() {
        let keys = [SummaryService.Provider.claudeCode, .codex, .cursor].map(\.modelDefaultsKey)
        XCTAssertEqual(Set(keys).count, 3)
        XCTAssertFalse(keys.contains(SummaryService.Provider.anthropic.modelDefaultsKey))
        XCTAssertEqual(SummaryService.Provider.ollama.modelDefaultsKey, "aiOllamaModel")
        XCTAssertEqual(SummaryService.Provider.anthropic.modelDefaultsKey, "aiModel")
        for key in keys { XCTAssertTrue(LibraryBackup.preferenceKeys.contains(key), key) }
    }
}
