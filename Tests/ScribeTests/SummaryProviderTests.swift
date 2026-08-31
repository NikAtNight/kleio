import Foundation
import XCTest
@testable import Scribe

final class SummaryProviderTests: XCTestCase {
    private let providerKey = "aiProvider"
    private let apiKeyKey = "aiAPIKey"
    private let modelKey = "aiModel"
    private let ollamaModelKey = "aiOllamaModel"
    private var savedDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in [providerKey, apiKeyKey, modelKey, ollamaModelKey] {
            if let value = UserDefaults.standard.object(forKey: key) {
                savedDefaults[key] = value
            }
        }
    }

    override func tearDown() {
        for key in [providerKey, apiKeyKey, modelKey, ollamaModelKey] {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testConfigurationDependsOnSelectedProvider() {
        UserDefaults.standard.set("anthropic", forKey: providerKey)
        UserDefaults.standard.set("", forKey: apiKeyKey)
        XCTAssertFalse(SummaryService.isConfigured)

        UserDefaults.standard.set("test-key", forKey: apiKeyKey)
        XCTAssertTrue(SummaryService.isConfigured)

        UserDefaults.standard.set("openai", forKey: providerKey)
        XCTAssertTrue(SummaryService.isConfigured)

        UserDefaults.standard.set("appleIntelligence", forKey: providerKey)
        UserDefaults.standard.set("", forKey: apiKeyKey)
        XCTAssertTrue(SummaryService.isConfigured)

        UserDefaults.standard.set("ollama", forKey: providerKey)
        UserDefaults.standard.set("", forKey: ollamaModelKey)
        XCTAssertFalse(SummaryService.isConfigured)

        UserDefaults.standard.set("llama3.2", forKey: ollamaModelKey)
        XCTAssertTrue(SummaryService.isConfigured)
    }

    func testOllamaGenerationDecodesResponseAndSendsPlainPrompt() async throws {
        let response = """
        {"model":"llama3.2","response":"A short summary.","done":true,"done_reason":"stop"}
        """
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/generate")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(response.utf8)
            )
        }

        let request = OllamaClient.GenerateRequest(
            model: "llama3.2",
            system: "Summarize faithfully.",
            prompt: "Transcript text",
            options: .init(temperature: 0.3, numPredict: 2_048)
        )
        let requestJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        XCTAssertEqual(requestJSON?["model"] as? String, "llama3.2")
        XCTAssertEqual(requestJSON?["system"] as? String, "Summarize faithfully.")
        XCTAssertEqual(requestJSON?["prompt"] as? String, "Transcript text")
        XCTAssertEqual(requestJSON?["think"] as? Bool, false)
        XCTAssertEqual((requestJSON?["options"] as? [String: Any])?["temperature"] as? Double, 0.3)

        let result = try await makeClient().generate(
            model: "llama3.2",
            system: "Summarize faithfully.",
            prompt: "Transcript text",
            temperature: 0.3
        )

        XCTAssertEqual(result, "A short summary.")
    }

    func testOllamaMapsUnreachableServerToClearError() async {
        URLProtocolStub.handler = { _ in throw URLError(.notConnectedToInternet) }

        do {
            _ = try await makeClient().generate(model: "llama3.2", prompt: "Transcript text")
            XCTFail("Expected the request to fail")
        } catch let error as OllamaClient.ClientError {
            XCTAssertEqual(error, .unavailable)
            XCTAssertEqual(error.localizedDescription, "Ollama is not running. Start Ollama, then try again.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient() -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return OllamaClient(
            baseURL: URL(string: "http://localhost:11434")!,
            session: URLSession(configuration: configuration)
        )
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
