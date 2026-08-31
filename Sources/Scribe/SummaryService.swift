import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional AI summarization using a cloud provider or a local model.
enum SummaryService {
    enum Provider: String, CaseIterable, Identifiable {
        case anthropic
        case openai
        case appleIntelligence
        case ollama

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic (Claude)"
            case .openai: return "OpenAI"
            case .appleIntelligence: return "Apple Intelligence (on this Mac)"
            case .ollama: return "Ollama (local)"
            }
        }
        var defaultModel: String {
            switch self {
            case .anthropic: return "claude-sonnet-5"
            case .openai: return "gpt-4o-mini"
            case .appleIntelligence: return ""
            case .ollama: return ""
            }
        }
    }

    enum SummaryError: LocalizedError {
        case noKey
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .noKey:
                if SummaryService.provider == .ollama {
                    return "Choose an Ollama model in Settings → AI."
                }
                return "No API key configured. Add one in Settings → AI."
            case .badResponse(let detail):
                return "The AI request failed: \(detail)"
            }
        }
    }

    static let defaultPrompt = """
    Summarize this transcript in Markdown. Use exactly these sections:
    ## Summary
    Write 2-4 tight sentences.
    ## Action items
    Use `- [ ] owner: task` lines. Omit this section if there are none.
    ## Decisions
    Use bullets. Omit this section if there are none.
    """

    static var provider: Provider {
        Provider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .anthropic
    }

    static var apiKey: String {
        UserDefaults.standard.string(forKey: "aiAPIKey") ?? ""
    }

    static var model: String {
        let key = provider == .ollama ? "aiOllamaModel" : "aiModel"
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        return stored.isEmpty ? provider.defaultModel : stored
    }

    static var prompt: String {
        let stored = UserDefaults.standard.string(forKey: "summaryPrompt") ?? ""
        return stored.isEmpty ? defaultPrompt : stored
    }

    static var isConfigured: Bool {
        switch provider {
        case .anthropic, .openai:
            return !apiKey.isEmpty
        case .appleIntelligence:
            return true
        case .ollama:
            return !model.isEmpty
        }
    }

    static func summarize(_ doc: ScribeDocument) async throws -> String {
        guard isConfigured else { throw SummaryError.noKey }

        // Keep well inside context limits; a 2 h meeting is ~100k chars.
        var transcript = Exporter.render(doc, as: .txt)
        let limit = 150_000
        if transcript.count > limit {
            transcript = String(transcript.prefix(limit)) + "\n[transcript truncated]"
        }
        let userMessage = "\(prompt)\n\nTitle: \(doc.title)\nDuration: \(doc.duration.clockString)\n\nTranscript:\n\(transcript)"

        switch provider {
        case .anthropic: return try await callAnthropic(userMessage)
        case .openai: return try await callOpenAI(userMessage)
        case .appleIntelligence: return try await callAppleIntelligence(userMessage)
        case .ollama: return try await OllamaClient().generate(model: model, prompt: userMessage)
        }
    }

    private static func callAppleIntelligence(_ message: String) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw SummaryError.badResponse("Apple Intelligence requires macOS 26 or later.")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw SummaryError.badResponse(
                "Apple Intelligence is unavailable on this Mac. Enable it in System Settings and try again."
            )
        }
        let session = LanguageModelSession()
        let response = try await session.respond(
            to: message,
            options: GenerationOptions(temperature: 0.2)
        )
        return response.content
        #else
        throw SummaryError.badResponse("Apple Intelligence is unavailable in this version of macOS.")
        #endif
    }

    private static func callAnthropic(_ message: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 2048,
            "messages": [["role": "user", "content": message]],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SummaryError.badResponse(String(data: data, encoding: .utf8) ?? "unknown error")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw SummaryError.badResponse("unexpected response shape")
        }
        return text
    }

    private static func callOpenAI(_ message: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": message]],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SummaryError.badResponse(String(data: data, encoding: .utf8) ?? "unknown error")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let messageObj = choices.first?["message"] as? [String: Any],
              let text = messageObj["content"] as? String else {
            throw SummaryError.badResponse("unexpected response shape")
        }
        return text
    }
}
