import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct CoreChecks {
    @MainActor
    static func main() async {
        await Harness.shared.run("URL normalization and safety") {
            try expectEqual(
                try GatewayClient.validatedBaseURL("https://example.test").absoluteString,
                "https://example.test/v1"
            )
            try expectEqual(
                try GatewayClient.validatedBaseURL("  https://example.test/v1/  ").absoluteString,
                "https://example.test/v1"
            )
            for invalid in [
                "http://example.test",
                "https://user:pass@example.test",
                "https://example.test/v1?query=1",
                "https://example.test/v1#fragment",
                "https://example.test/not-v1"
            ] {
                try expectGatewayError(.invalidBaseURL) {
                    _ = try GatewayClient.validatedBaseURL(invalid)
                }
            }
        }

        await Harness.shared.run("DeepSeek Responses request construction") {
            let key = "secret-check-key"
            let messages = [
                ChatMessage(role: .user, text: "hello"),
                ChatMessage(role: .assistant, text: "complete", status: .complete),
                ChatMessage(role: .assistant, text: "streaming", status: .streaming),
                ChatMessage(role: .assistant, text: "failed", status: .failed)
            ]
            let request = try GatewayClient.makeStreamRequest(
                configuration: GatewayConfiguration(baseURL: "https://example.test", apiKey: key),
                model: "deepseek-reasoner",
                effort: "high",
                messages: messages
            )
            try expectEqual(request.url?.absoluteString, "https://example.test/v1/responses")
            try expectEqual(request.httpMethod, "POST")
            try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
            try expectEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            try expectEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let bodyData = try expectNotNil(request.httpBody)
            let body = try expectNotNil(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            try expectEqual(body["model"] as? String, "deepseek-reasoner")
            try expectEqual(body["stream"] as? Bool, true)
            try expectEqual(body["store"] as? Bool, false)
            try expectEqual(
                body["input"] as? [[String: String]],
                [["role": "user", "content": "hello"], ["role": "assistant", "content": "complete"]]
            )
            try expectEqual((body["reasoning"] as? [String: String])?["effort"], "high")
            let bodyText = try expectNotNil(String(data: bodyData, encoding: .utf8))
            try expect(!bodyText.contains(key), "API key must not be copied into the request body")
        }

        await Harness.shared.run("SSE parser CRLF, split UTF-8, multiline, comments") {
            var parser = SSEParser()
            let wire = ": keepalive\r\nevent: delta\r\ndata: {\"text\":\r\ndata: \"你好🌿\"}\r\n\r\n"
            var frames: [SSEFrame] = []
            for byte in wire.utf8 {
                frames.append(contentsOf: try parser.append([byte]))
            }
            try expectEqual(
                frames,
                [SSEFrame(event: "delta", data: "{\"text\":\n\"你好🌿\"}")]
            )
        }

        await Harness.shared.run("SSE parser cumulative frame limit") {
            var parser = SSEParser(maximumFrameBytes: 25)
            do {
                _ = try parser.append(Array(String(repeating: "data: 1234\n", count: 3).utf8))
                throw CheckFailure("Expected a cumulative frame-size failure")
            } catch SSEParserError.frameTooLarge {
            }
        }

        await Harness.shared.run("SSE parser final unterminated frame") {
            var parser = SSEParser()
            let frames = try parser.append(Array("data: final".utf8))
            try expect(frames.isEmpty, "Frame should wait for EOF")
            try expectEqual(try parser.finish(), [SSEFrame(event: nil, data: "final")])
        }

        await Harness.shared.run("SSE parser rejects malformed UTF-8") {
            var parser = SSEParser()
            do {
                _ = try parser.append([0xFF, 0x0A])
                throw CheckFailure("Expected invalid UTF-8")
            } catch SSEParserError.invalidUTF8 {
            }
        }

        await Harness.shared.run("completion fallback avoids duplicate deltas") {
            var state = StreamState(maximumTextBytes: 1_024)
            var events: [GatewayEvent] = []
            let delta = SSEFrame(data: #"{"type":"response.output_text.delta","delta":"final"}"#)
            _ = try GatewayClient.process(frame: delta, apiKey: "key", state: &state) {
                events.append($0)
            }
            let completed = SSEFrame(
                data: #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"final"}]}]}}"#
            )
            let terminal = try GatewayClient.process(
                frame: completed,
                apiKey: "key",
                state: &state
            ) { events.append($0) }
            try expect(terminal, "response.completed must be terminal")
            try expectEqual(events, [.delta("final"), .completed(text: nil)])
            try expect(state.didComplete, "Completion state must be recorded")
        }

        await Harness.shared.run("completion supplies authoritative final text when needed") {
            var state = StreamState(maximumTextBytes: 1_024)
            var events: [GatewayEvent] = []
            let completed = SSEFrame(
                data: #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"full text"}]}]}}"#
            )
            _ = try GatewayClient.process(frame: completed, apiKey: "key", state: &state) {
                events.append($0)
            }
            try expectEqual(events, [.completed(text: "full text")])
        }

        await Harness.shared.run("[DONE] alone is not successful for Responses") {
            let bytes = AsyncThrowingStream<UInt8, Error>(
                UInt8.self,
                bufferingPolicy: .unbounded
            ) { continuation in
                for byte in "data: [DONE]\n\n".utf8 { continuation.yield(byte) }
                continuation.finish()
            }
            do {
                try await GatewayClient.consume(bytes: bytes, apiKey: "key") { _ in }
                throw CheckFailure("Expected unexpectedEOF")
            } catch GatewayClientError.unexpectedEOF {
            }
        }

        await Harness.shared.run("premature EOF is an error") {
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
                throw CheckFailure("Expected unexpectedEOF")
            } catch GatewayClientError.unexpectedEOF {
            }
        }

        await Harness.shared.run("malformed JSON is a protocol error") {
            var state = StreamState(maximumTextBytes: 1_024)
            do {
                _ = try GatewayClient.process(
                    frame: SSEFrame(data: "{not-json"),
                    apiKey: "key",
                    state: &state
                ) { _ in }
                throw CheckFailure("Expected protocolError")
            } catch GatewayClientError.protocolError {
            }
        }

        await Harness.shared.run("failed, incomplete, and error events throw") {
            let cases: [(String, GatewayClientError)] = [
                (
                    #"{"type":"response.failed","response":{"error":{"message":"secret https://upstream.test"}}}"#,
                    .remoteFailure("The gateway could not complete the response.")
                ),
                (#"{"type":"response.incomplete"}"#, .incompleteResponse),
                (
                    #"{"type":"error","error":{"message":"secret https://upstream.test"}}"#,
                    .remoteFailure("The gateway could not complete the response.")
                )
            ]
            for (json, expected) in cases {
                var state = StreamState(maximumTextBytes: 1_024)
                do {
                    _ = try GatewayClient.process(
                        frame: SSEFrame(data: json),
                        apiKey: "secret",
                        state: &state
                    ) { _ in }
                    throw CheckFailure("Expected \(expected)")
                } catch let error as GatewayClientError {
                    try expectEqual(error, expected)
                    try expect(!error.localizedDescription.contains("secret"),
                               "Error must not expose the API key")
                    try expect(!error.localizedDescription.contains("upstream.test"),
                               "Error must not expose the upstream URL")
                }
            }
        }

        await Harness.shared.run("total streamed text is bounded") {
            var state = StreamState(maximumTextBytes: 4)
            do {
                try state.appendDelta("你好") { _ in }
                throw CheckFailure("Expected responseTooLarge")
            } catch GatewayClientError.responseTooLarge {
            }
        }

        await Harness.shared.run("buffer overflow throws instead of dropping text") {
            let stream = AsyncThrowingStream<GatewayEvent, Error>(
                GatewayEvent.self,
                bufferingPolicy: .bufferingOldest(1)
            ) { continuation in
                do {
                    try GatewayClient.enqueue(.delta("first"), into: continuation)
                    do {
                        try GatewayClient.enqueue(.delta("second"), into: continuation)
                        throw CheckFailure("Expected bufferOverflow")
                    } catch GatewayClientError.bufferOverflow {
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
                continuation.finish()
            }
            _ = stream
        }

        await Harness.shared.run("consumer cancellation propagates") {
            let task = Task {
                try await GatewayClient.consume(bytes: CancellationByteSequence(), apiKey: "key") { _ in }
            }
            try await Task.sleep(nanoseconds: 30_000_000)
            task.cancel()
            do {
                try await task.value
                throw CheckFailure("Expected cancellation")
            } catch is CancellationError {
            }
        }

        await Harness.shared.run("URLProtocol integration: models decoding") {
            let session = makeSession(ModelsSuccessURLProtocol.self)
            let models = try await GatewayClient(session: session).models(
                configuration: GatewayConfiguration(baseURL: "https://example.test", apiKey: "key")
            )
            try expectEqual(models, [
                GatewayModel(id: "deepseek-reasoner", displayName: "DeepSeek Reasoner", reasoningLevels: ["high"])
            ])
        }

        await Harness.shared.run("models envelope rejects bare arrays") {
            let bare = Data(#"[{"id":"deepseek-reasoner"}]"#.utf8)
            do {
                _ = try GatewayClient.decodeModels(bare)
                throw CheckFailure("Expected invalidResponse")
            } catch GatewayClientError.invalidResponse {
            }
        }

        await Harness.shared.run("URLProtocol integration: HTTP non-2xx") {
            let session = makeSession(HTTPFailureURLProtocol.self)
            do {
                _ = try await GatewayClient(session: session).models(
                    configuration: GatewayConfiguration(baseURL: "https://example.test", apiKey: "key")
                )
                throw CheckFailure("Expected httpStatus(503)")
            } catch GatewayClientError.httpStatus(let status) {
                try expectEqual(status, 503)
            }
        }

        await Harness.shared.run("URLProtocol integration: non-SSE content type") {
            let session = makeSession(JSONStreamURLProtocol.self)
            let client = GatewayClient(session: session)
            do {
                for try await _ in client.stream(
                    configuration: GatewayConfiguration(baseURL: "https://example.test", apiKey: "key"),
                    model: "deepseek-reasoner",
                    effort: nil,
                    messages: [ChatMessage(role: .user, text: "hello")]
                ) {
                    throw CheckFailure("No event should be emitted")
                }
                throw CheckFailure("Expected unexpectedContentType")
            } catch GatewayClientError.unexpectedContentType {
            }
        }

        await Harness.shared.run("URLProtocol integration: complete SSE stream") {
            let session = makeSession(SSESuccessURLProtocol.self)
            let client = GatewayClient(session: session)
            var events: [GatewayEvent] = []
            for try await event in client.stream(
                configuration: GatewayConfiguration(baseURL: "https://example.test", apiKey: "key"),
                model: "deepseek-reasoner",
                effort: "high",
                messages: [ChatMessage(role: .user, text: "hello")]
            ) {
                events.append(event)
            }
            try expectEqual(events, [.route("deepseek-reasoner"), .delta("Hello"), .completed(text: nil)])
        }

        await Harness.shared.run("delta emits before EOF or full byte batch") {
            let (bytes, source) = AsyncThrowingStream<UInt8, Error>.makeStream()
            let emissions = EventBox()
            let task = Task {
                try await GatewayClient.consume(bytes: bytes, apiKey: "key") {
                    emissions.append($0)
                }
            }
            for byte in "data: {\"type\":\"response.output_text.delta\",\"delta\":\"early\"}\n\n".utf8 {
                source.yield(byte)
            }

            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline && !emissions.hasEvents {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try expect(emissions.hasEvents, "Delta must be emitted before EOF")
            source.finish()
            do {
                try await task.value
                throw CheckFailure("Expected unexpectedEOF")
            } catch GatewayClientError.unexpectedEOF {
            }
        }

        await Harness.shared.run("route header is emitted and sanitized") {
            let session = makeSession(SSESuccessURLProtocol.self)
            let client = GatewayClient(session: session)
            var events: [GatewayEvent] = []
            for try await event in client.stream(
                configuration: GatewayConfiguration(baseURL: "https://example.test", apiKey: "key"),
                model: "group/layered-plan",
                effort: nil,
                messages: [ChatMessage(role: .user, text: "hello")]
            ) {
                events.append(event)
            }
            try expectEqual(events, [.route("deepseek-reasoner"), .delta("Hello"), .completed(text: nil)])

            let unsafe = try expectNotNil(HTTPURLResponse(
                url: try expectNotNil(URL(string: "https://example.test/v1/responses")),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Magpie-Model": "https://upstream.test"]
            ))
            try expectEqual(GatewayClient.routedModel(from: unsafe, apiKey: "key"), nil)
        }

        await Harness.shared.run("refusal output is a completion fallback") {
            var state = StreamState(maximumTextBytes: 1_024)
            var events: [GatewayEvent] = []
            let completed = SSEFrame(
                data: #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"refusal","refusal":"I cannot help with that."}]}}"#
            )
            _ = try GatewayClient.process(frame: completed, apiKey: "key", state: &state) {
                events.append($0)
            }
            try expectEqual(events, [.completed(text: "I cannot help with that.")])
        }

        await Harness.shared.run("ConversationStore missing file") {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try expectEqual(try ConversationStore(directory: directory).load(), [])
        }

        await Harness.shared.run("ConversationStore round trip") {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let conversation = Conversation(
                title: "DeepSeek",
                modelID: "deepseek-reasoner",
                effort: "high",
                messages: [ChatMessage(role: .user, text: "hello")]
            )
            let store = ConversationStore(directory: directory)
            try store.save([conversation])
            try expectEqual(try store.load(), [conversation])
            let json = try String(
                contentsOf: directory.appendingPathComponent("conversations.json"),
                encoding: .utf8
            )
            try expect(!json.contains("apiKey"), "Persistence must not include API keys")
            try expect(!json.contains("secret"), "Persistence must not include credentials")
        }

        await Harness.shared.run("ConversationStore restores interrupted messages") {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ConversationStore(directory: directory)
            try store.save([
                Conversation(messages: [
                    ChatMessage(role: .assistant, text: "partial", status: .streaming)
                ])
            ])
            let loaded = try store.load()
            try expectEqual(loaded.first?.messages.first?.text, "partial")
            try expectEqual(loaded.first?.messages.first?.status, .stopped)
        }

        await Harness.shared.run("ConversationStore corrupt file remains untouched") {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("conversations.json")
            let corrupt = Data("{not-json".utf8)
            try corrupt.write(to: file)
            do {
                _ = try ConversationStore(directory: directory).load()
                throw CheckFailure("Expected a decode failure")
            } catch is DecodingError {
            }
            try expectEqual(try Data(contentsOf: file), corrupt)
        }

        Harness.shared.finish()
    }
}

@MainActor
private final class Harness {
    static let shared = Harness()
    private var passed = 0
    private var failed = 0

    func run(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("[PASS] \(name)")
        } catch {
            failed += 1
            print("[FAIL] \(name): \(error)")
        }
    }

    func finish() {
        print("CHECK_RESULT passed=\(passed) failed=\(failed) total=\(passed + failed)")
        if failed > 0 { exit(1) }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") throws {
    guard actual == expected else {
        throw CheckFailure(message.isEmpty ? "Expected \(expected), got \(actual)" : message)
    }
}

private func expectNotNil<T>(_ value: T?, _ message: String = "Expected a non-nil value") throws -> T {
    guard let value else { throw CheckFailure(message) }
    return value
}

private func expectGatewayError(_ expected: GatewayClientError,
                                _ body: () throws -> Void) throws {
    do {
        try body()
        throw CheckFailure("Expected \(expected)")
    } catch let error as GatewayClientError {
        try expectEqual(error, expected)
    }
}

private struct CancellationByteSequence: AsyncSequence {
    struct Iterator: AsyncIteratorProtocol {
        private var sentByte = false

        mutating func next() async throws -> UInt8? {
            if !sentByte {
                sentByte = true
                return 0x64
            }
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return nil
        }
    }

    func makeAsyncIterator() -> Iterator { Iterator() }
}

private func makeSession(_ protocolClass: URLProtocol.Type) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolClass]
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
}

private final class EventBox: @unchecked Sendable {
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

private class FakeURLProtocol: URLProtocol {
    class func response(for request: URLRequest) throws -> (Int, String, [String: String], Data) {
        fatalError("Subclass must provide a response")
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, contentType, headers, data) = try type(of: self).response(for: request)
            var fields = headers
            fields["Content-Type"] = contentType
            let response = try expectNotNil(HTTPURLResponse(
                url: try expectNotNil(request.url),
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: fields
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ModelsSuccessURLProtocol: FakeURLProtocol {
    override class func response(for request: URLRequest) throws -> (Int, String, [String: String], Data) {
        (
            200,
            "application/json",
            [:],
            Data(#"{"object":"list","data":[{"id":"deepseek-reasoner","display_name":"DeepSeek Reasoner","reasoning_levels":["high"]}]}"#.utf8)
        )
    }
}

private final class HTTPFailureURLProtocol: FakeURLProtocol {
    override class func response(for request: URLRequest) throws -> (Int, String, [String: String], Data) {
        (503, "application/json", [:], Data(#"{"error":"upstream"}"#.utf8))
    }
}

private final class JSONStreamURLProtocol: FakeURLProtocol {
    override class func response(for request: URLRequest) throws -> (Int, String, [String: String], Data) {
        (200, "application/json", [:], Data(#"{"error":"not streaming"}"#.utf8))
    }
}

private final class SSESuccessURLProtocol: FakeURLProtocol {
    override class func response(for request: URLRequest) throws -> (Int, String, [String: String], Data) {
        let wire = """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hello"}

        data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Hello"}]}]}}

        """
        return (
            200,
            "text/event-stream; charset=utf-8",
            ["X-Magpie-Model": "deepseek-reasoner"],
            Data(wire.utf8)
        )
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MagpieCoreChecks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
