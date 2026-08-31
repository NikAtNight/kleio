import Foundation
import XCTest
@testable import Scribe

final class TranscriptCleanerTests: XCTestCase {
    func testValidationFallsBackForEmptyOutput() {
        XCTAssertEqual(TranscriptCleaner.validated("  \n", raw: "hello there"), "hello there")
    }

    func testValidationFallsBackForLengthBlowup() {
        let raw = "short transcript"
        XCTAssertEqual(TranscriptCleaner.validated(String(repeating: "x", count: 200), raw: raw), raw)
    }

    func testValidationFallsBackForInstructionEcho() {
        let raw = "schedule the meeting"
        XCTAssertEqual(
            TranscriptCleaner.validated("You clean up raw speech-to-text transcripts.", raw: raw),
            raw
        )
    }

    func testS1MiniRequestUsesControlLine() async throws {
        URLProtocolStub.handler = { request in
            let body = try XCTUnwrap(self.requestBody(for: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "s1-mini")
            XCTAssertEqual(json["system"] as? String, S1MiniCleanup.systemPrompt)
            XCTAssertEqual(
                json["prompt"] as? String,
                "[Styling: semi-formal] [Structure: prose] [Context: general]\nhello um there"
            )
            return self.response("Hello there.", for: request)
        }

        let result = try await TranscriptCleaner(ollama: makeClient())
            .cleanWithOllama("hello um there", model: "s1-mini")

        XCTAssertEqual(result, "Hello there.")
    }

    func testOtherOllamaModelsUsePlainPrompt() async throws {
        URLProtocolStub.handler = { request in
            let body = try XCTUnwrap(self.requestBody(for: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["prompt"] as? String, "hello there")
            XCTAssertEqual(json["system"] as? String, TranscriptCleaner.systemPrompt)
            return self.response("Hello there.", for: request)
        }

        _ = try await TranscriptCleaner(ollama: makeClient())
            .cleanWithOllama("hello there", model: "llama3.2")
    }

    func testBackendSelectionUsesAppleIntelligenceOnlyWhenAvailable() {
        XCTAssertEqual(
            TranscriptCleaner.selectedBackend(preference: .appleIntelligence, appleIntelligenceAvailable: true),
            .appleIntelligence
        )
        XCTAssertEqual(
            TranscriptCleaner.selectedBackend(preference: .appleIntelligence, appleIntelligenceAvailable: false),
            .ollama
        )
        XCTAssertEqual(
            TranscriptCleaner.selectedBackend(preference: .ollama, appleIntelligenceAvailable: true),
            .ollama
        )
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    private func makeClient() -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return OllamaClient(
            baseURL: URL(string: "http://localhost:11434")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func response(_ text: String, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let json = "{\"response\":\"\(text)\",\"done\":true}"
        return (
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data(json.utf8)
        )
    }

    private func requestBody(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1_024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
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
