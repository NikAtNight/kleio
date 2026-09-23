import Foundation

/// Small client for an Ollama server running on this Mac.
struct OllamaClient {
    static let defaultBaseURL = URL(string: "http://localhost:11434")!

    enum ClientError: LocalizedError, Equatable {
        case unavailable
        case httpStatus(Int, String)
        case invalidResponse
        case incompleteResponse

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Ollama is not running. Start Ollama, then try again."
            case .httpStatus(let status, let detail):
                return detail.isEmpty
                    ? "Ollama returned HTTP \(status)."
                    : "Ollama returned HTTP \(status): \(detail)"
            case .invalidResponse:
                return "Ollama returned an unexpected response."
            case .incompleteResponse:
                return "The model stopped before finishing the summary. Try again or choose another summary model in Settings."
            }
        }
    }

    struct GenerateRequest: Encodable, Equatable {
        let model: String
        let system: String
        let prompt: String
        let stream = false
        let think = false
        let options: Options

        struct Options: Encodable, Equatable {
            let temperature: Double
            let numPredict: Int
            var numContext: Int? = nil

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
                case numContext = "num_ctx"
            }
        }
    }

    struct GenerateResponse: Decodable, Equatable {
        let response: String
        let doneReason: String?
        let done: Bool?

        enum CodingKeys: String, CodingKey {
            case response
            case doneReason = "done_reason"
            case done
        }
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = Self.defaultBaseURL, session: URLSession = Self.defaultSession) {
        self.baseURL = baseURL
        self.session = session
    }

    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        // Long summaries on larger local models can take several minutes.
        // Each request sets its own shorter timeout.
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    func installedModels() async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            return tags.models.map(\.name).sorted()
        } catch {
            return []
        }
    }

    func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func modelContextSize(_ model: String) async throws -> Int {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": model])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["model_info"] as? [String: Any],
              let context = info.filter({ $0.key.hasSuffix(".context_length") })
                .compactMap({ $0.value as? Int }).filter({ $0 > 0 }).min() else {
            throw ClientError.invalidResponse
        }
        return context
    }

    /// Starts loading a model before its first summary request. A failed
    /// prewarm is harmless because the actual request reports the error.
    func prewarm(model: String) async {
        struct PrewarmRequest: Encodable {
            let model: String
            let keepAlive = "30m"

            enum CodingKeys: String, CodingKey {
                case model
                case keepAlive = "keep_alive"
            }
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try? JSONEncoder().encode(PrewarmRequest(model: model))
        _ = try? await session.data(for: request)
    }

    func generate(
        model: String,
        system: String = "",
        prompt: String,
        temperature: Double = 0.2,
        maxTokens: Int = 2_048,
        contextSize: Int? = nil,
        requireComplete: Bool = false,
        timeout: TimeInterval = 45
    ) async throws -> String {
        let requestBody = GenerateRequest(
            model: model,
            system: system,
            prompt: prompt,
            options: .init(temperature: temperature, numPredict: maxTokens, numContext: contextSize)
        )
        let result = try await send(requestBody, timeout: timeout)
        if requireComplete, result.done != true || result.doneReason != "stop" {
            throw ClientError.incompleteResponse
        }
        guard !result.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.invalidResponse
        }
        return result.response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ body: GenerateRequest, timeout: TimeInterval) async throws -> GenerateResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClientError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                throw ClientError.httpStatus(
                    httpResponse.statusCode,
                    String(data: data, encoding: .utf8) ?? ""
                )
            }
            do {
                return try JSONDecoder().decode(GenerateResponse.self, from: data)
            } catch {
                throw ClientError.invalidResponse
            }
        } catch let error as ClientError {
            throw error
        } catch is URLError {
            throw ClientError.unavailable
        } catch {
            throw ClientError.unavailable
        }
    }
}
