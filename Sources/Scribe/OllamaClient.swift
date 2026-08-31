import Foundation

/// Small client for an Ollama server running on this Mac.
struct OllamaClient {
    static let defaultBaseURL = URL(string: "http://localhost:11434")!

    enum ClientError: LocalizedError, Equatable {
        case unavailable
        case httpStatus(Int, String)
        case invalidResponse

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

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }
    }

    struct GenerateResponse: Decodable, Equatable {
        let response: String
        let doneReason: String?

        enum CodingKeys: String, CodingKey {
            case response
            case doneReason = "done_reason"
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
        configuration.timeoutIntervalForResource = 120
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
        maxTokens: Int = 2_048
    ) async throws -> String {
        let requestBody = GenerateRequest(
            model: model,
            system: system,
            prompt: prompt,
            options: .init(temperature: temperature, numPredict: maxTokens)
        )
        let result = try await send(requestBody)
        guard !result.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.invalidResponse
        }
        return result.response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ body: GenerateRequest) async throws -> GenerateResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
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
