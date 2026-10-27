import Foundation
import XCTest
@testable import MagpieCore

final class GatewayTests: XCTestCase {
    func testURLValidationNormalizesRootAndVersion() throws {
        XCTAssertEqual(try GatewayClient.validatedBaseURL("https://example.test").absoluteString,
                       "https://example.test/v1")
        XCTAssertEqual(try GatewayClient.validatedBaseURL("https://example.test/v1/").absoluteString,
                       "https://example.test/v1")
    }

    func testURLValidationRejectsUnsafeComponents() {
        for value in [
            "http://example.test",
            "https://user:pass@example.test",
            "https://example.test/v1?x=1",
            "https://example.test/v1#fragment",
            "https://example.test/other"
        ] {
            XCTAssertThrowsError(try GatewayClient.validatedBaseURL(value), value)
        }
    }

    func testParserHandlesChunkSplitsUnicodeCRLFMultilineAndComments() throws {
        var parser = SSEParser()
        let wire = ": keepalive\r\nevent: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"你好🌿\"}\r\n\r\n"
        let bytes = Array(wire.utf8)
        var frames: [SSEFrame] = []
        for byte in bytes {
            frames += try parser.append([byte])
        }
        XCTAssertEqual(frames, [
            SSEFrame(
                event: "response.output_text.delta",
                data: "{\"type\":\"response.output_text.delta\",\n\"delta\":\"你好🌿\"}"
            )
        ])
    }

    func testParserLimitsCumulativeFrameBytes() {
        var parser = SSEParser(maximumFrameBytes: 25)
        let bytes = Array(String(repeating: "data: 1234\n", count: 3).utf8)
        XCTAssertThrowsError(try parser.append(bytes)) { error in
            XCTAssertEqual(error as? SSEParserError, .frameTooLarge)
        }
    }

    func testParserFinishesFinalUnterminatedFrame() throws {
        var parser = SSEParser()
        XCTAssertTrue(try parser.append(Array("data: final".utf8)).isEmpty)
        XCTAssertEqual(try parser.finish(), [SSEFrame(event: nil, data: "final")])
    }

    func testStreamRequestBodyAndHistoryFiltering() throws {
        let messages = [
            ChatMessage(role: .user, text: "hi"),
            ChatMessage(role: .assistant, text: "done", status: .complete),
            ChatMessage(role: .assistant, text: "partial", status: .streaming),
            ChatMessage(role: .assistant, text: "stopped", status: .stopped)
        ]
        let configuration = GatewayConfiguration(baseURL: "https://example.test", apiKey: "secret-test-key")
        let withEffort = try GatewayClient.makeStreamRequest(
            configuration: configuration,
            model: "deepseek-reasoner",
            effort: "high",
            messages: messages
        )
        XCTAssertEqual(withEffort.url?.absoluteString, "https://example.test/v1/responses")
        XCTAssertEqual(withEffort.httpMethod, "POST")
        XCTAssertEqual(withEffort.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test-key")
        XCTAssertEqual(withEffort.value(forHTTPHeaderField: "ngrok-skip-browser-warning"), "true")
        XCTAssertEqual(withEffort.value(forHTTPHeaderField: "Accept"), "text/event-stream")

        let body = try XCTUnwrap(withEffort.httpBody).jsonObject()
        XCTAssertEqual(body["model"] as? String, "deepseek-reasoner")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        let input = try XCTUnwrap(body["input"] as? [[String: String]])
        XCTAssertEqual(input, [
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": "done"]
        ])
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "high")

        let noEffort = try GatewayClient.makeStreamRequest(
            configuration: configuration,
            model: "deepseek-chat",
            effort: "",
            messages: []
        )
        let noEffortBody = try XCTUnwrap(noEffort.httpBody).jsonObject()
        XCTAssertNil(noEffortBody["reasoning"])
    }

    func testModelsDecodesEnvelopeAndRejectsBareArray() throws {
        let envelope = Data(#"""
        {"object":"list","data":[{"id":"deepseek-reasoner","display_name":"DeepSeek Reasoner","reasoning_levels":["high"]}]}
        """#.utf8)
        XCTAssertEqual(try GatewayClient.decodeModels(envelope), [
            GatewayModel(id: "deepseek-reasoner", displayName: "DeepSeek Reasoner", reasoningLevels: ["high"])
        ])

        let bare = Data(#"[{"id":"deepseek-reasoner"}]"#.utf8)
        XCTAssertThrowsError(try GatewayClient.decodeModels(bare)) {
            XCTAssertEqual($0 as? GatewayClientError, .invalidResponse)
        }
    }

    func testCompletedIsAuthoritativeAndAvoidsDuplicateDeltas() throws {
        var state = StreamState(maximumTextBytes: 1_024)
        var emitted: [GatewayEvent] = []
        let delta = SSEFrame(data: #"{"type":"response.output_text.delta","delta":"final"}"#)
        XCTAssertFalse(try GatewayClient.process(frame: delta, apiKey: "key", state: &state) {
            emitted.append($0)
        })

        let completedFrame = SSEFrame(
            data: #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"final"}]}]}}"#
        )
        XCTAssertTrue(try GatewayClient.process(frame: completedFrame, apiKey: "key", state: &state) {
            emitted.append($0)
        })
        XCTAssertEqual(emitted, [.delta("final"), .completed(text: nil)])
        XCTAssertTrue(state.didComplete)
    }

    func testDoneAloneDoesNotCompleteResponsesStream() async {
        let bytes = AsyncThrowingStream<UInt8, Error>(
            UInt8.self,
            bufferingPolicy: .unbounded
        ) { continuation in
            for byte in "data: [DONE]\n\n".utf8 { continuation.yield(byte) }
            continuation.finish()
        }
        do {
            try await GatewayClient.consume(bytes: bytes, apiKey: "key") { _ in }
            XCTFail("[DONE] alone must not be successful")
        } catch {
            XCTAssertEqual(error as? GatewayClientError, .unexpectedEOF)
        }
    }

    func testShortCompleteFrameEmitsBeforeEOF() async throws {
        let (bytes, source) = AsyncThrowingStream<UInt8, Error>.makeStream()
        let emissions = LockedEventBox()
        let collected = Task {
            try await GatewayClient.consume(bytes: bytes, apiKey: "key") { event in
                emissions.append(event)
            }
        }

        let wire = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"early\"}\n\n"
        for byte in wire.utf8 { source.yield(byte) }

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if emissions.hasEvents { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(emissions.hasEvents, "Delta must be emitted before EOF or a 4096-byte batch")

        source.finish()
        do {
            _ = try await collected.value
            XCTFail("A delta without response.completed must end with unexpectedEOF")
        } catch {
            XCTAssertEqual(error as? GatewayClientError, .unexpectedEOF)
        }
    }

    func testRoutedModelHeaderIsValidated() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/v1/responses"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-Magpie-Model": "deepseek-reasoner"]
        ))
        XCTAssertEqual(GatewayClient.routedModel(from: response, apiKey: "key"), "deepseek-reasoner")

        let unsafe = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-Magpie-Model": "https://upstream.test"]
        ))
        XCTAssertNil(GatewayClient.routedModel(from: unsafe, apiKey: "key"))
    }

    func testMalformedEventAndTerminalFailuresAreSanitized() throws {
        var state = StreamState(maximumTextBytes: 1_024)
        XCTAssertThrowsError(try GatewayClient.process(
            frame: SSEFrame(data: "{not-json"),
            apiKey: "secret-key",
            state: &state
        ) { _ in }) {
            XCTAssertEqual($0 as? GatewayClientError, .protocolError)
        }

        let failed = SSEFrame(
            data: #"{"type":"response.failed","response":{"error":{"message":"secret-key https://upstream.test"}}}"#
        )
        XCTAssertThrowsError(try GatewayClient.process(
            frame: failed,
            apiKey: "secret-key",
            state: &state
        ) { _ in }) {
            guard case .remoteFailure(let message) = $0 as? GatewayClientError else {
                return XCTFail("Expected sanitized remote failure")
            }
            XCTAssertFalse(message.contains("secret-key"))
            XCTAssertFalse(message.contains("upstream.test"))
        }

        let incomplete = SSEFrame(data: #"{"type":"response.incomplete"}"#)
        XCTAssertThrowsError(try GatewayClient.process(
            frame: incomplete,
            apiKey: "secret-key",
            state: &state
        ) { _ in }) {
            XCTAssertEqual($0 as? GatewayClientError, .incompleteResponse)
        }
    }

    func testEOFWithoutTerminalCompletionIsNotSuccessful() async {
        let bytes = AsyncThrowingStream<UInt8, Error>(
            UInt8.self,
            bufferingPolicy: .unbounded
        ) { continuation in
            for byte in "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".utf8 {
                continuation.yield(byte)
            }
            continuation.finish()
        }
        do {
            try await GatewayClient.consume(bytes: bytes, apiKey: "key") { _ in }
            XCTFail("EOF must not be treated as successful completion")
        } catch {
            XCTAssertEqual(error as? GatewayClientError, .unexpectedEOF)
        }
    }

    func testRefusalOutputSuppliesCompletionFallback() throws {
        var state = StreamState(maximumTextBytes: 1_024)
        var emitted: [GatewayEvent] = []
        let completed = SSEFrame(
            data: #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"refusal","refusal":"I cannot help with that."}]}}"#
        )
        XCTAssertTrue(try GatewayClient.process(
            frame: completed,
            apiKey: "key",
            state: &state
        ) { emitted.append($0) })
        XCTAssertEqual(emitted, [.completed(text: "I cannot help with that.")])
    }

    func testHTTPStatusAndContentTypeValidation() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/v1/responses"))
        let unauthorized = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        ))
        let client = GatewayClient()
        XCTAssertThrowsError(try client.checkStatus(unauthorized)) {
            XCTAssertEqual($0 as? GatewayClientError, .httpStatus(401))
        }

        let streaming = URLResponse(
            url: url,
            mimeType: "text/event-stream",
            expectedContentLength: -1,
            textEncodingName: "utf-8"
        )
        let json = URLResponse(
            url: url,
            mimeType: "application/json",
            expectedContentLength: -1,
            textEncodingName: "utf-8"
        )
        XCTAssertTrue(client.contentTypeIsSSE(streaming))
        XCTAssertFalse(client.contentTypeIsSSE(json))
    }
}

private extension Data {
    func jsonObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any])
    }
}

private final class LockedEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [GatewayEvent] = []

    var hasEvents: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !events.isEmpty
    }

    func append(_ event: GatewayEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}
