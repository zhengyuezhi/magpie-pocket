import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GatewayClientError: Error, LocalizedError, Equatable {
    case invalidBaseURL
    case invalidResponse
    case httpStatus(Int)
    case unexpectedContentType
    case remoteFailure(String)
    case incompleteResponse
    case unexpectedEOF
    case protocolError
    case responseTooLarge
    case bufferOverflow

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter a valid HTTPS gateway URL."
        case .invalidResponse:
            return "The gateway returned an invalid response."
        case .httpStatus(let status):
            return "The gateway request failed (HTTP \(status)). Check the endpoint and API key."
        case .unexpectedContentType:
            return "The gateway did not return a streaming response."
        case .remoteFailure(let message):
            return message
        case .incompleteResponse:
            return "The gateway stopped before completing the response."
        case .unexpectedEOF:
            return "The connection ended before the response completed. Please try again."
        case .protocolError:
            return "The gateway returned an invalid streaming event."
        case .responseTooLarge:
            return "The response is too large for this device."
        case .bufferOverflow:
            return "The response arrived faster than it could be displayed."
        }
    }
}

struct GatewayModelList: Decodable {
    let data: [GatewayModel]
}

public final class GatewayClient {
    static let maximumBufferedEvents = 256
    static let maximumResponseTextBytes = 4 * 1024 * 1024
    static let byteBatchSize = 4 * 1024

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 15 * 60
        session = URLSession(configuration: configuration, delegate: RedirectDenyingDelegate(), delegateQueue: nil)
    }

    /// Internal seam for URLProtocol-backed checks. Production callers use `init()`.
    init(session: URLSession) {
        self.session = session
    }

    deinit { session.invalidateAndCancel() }

    public static func validatedBaseURL(_ raw: String) throws -> URL {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw GatewayClientError.invalidBaseURL
        }

        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty || path == "/" {
            path = "/v1"
        } else if path != "/v1" {
            throw GatewayClientError.invalidBaseURL
        }
        components.path = path
        guard let url = components.url, url.host != nil else {
            throw GatewayClientError.invalidBaseURL
        }
        return url
    }

    public func models(configuration: GatewayConfiguration) async throws -> [GatewayModel] {
        do {
            let url = try Self.validatedBaseURL(configuration.baseURL).appendingPathComponent("models")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            Self.applyHeaders(to: &request, configuration: configuration, accept: "application/json")

            let (data, response) = try await session.data(for: request)
            try Self.validateStatus(response)
            return try Self.decodeModels(data)
        } catch {
            throw Self.safeError(error, apiKey: configuration.apiKey)
        }
    }

    public func stream(configuration: GatewayConfiguration, model: String, effort: String?,
                       messages: [ChatMessage]) -> AsyncThrowingStream<GatewayEvent, Error> {
        AsyncThrowingStream(
            GatewayEvent.self,
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedEvents)
        ) { continuation in
            let task = Task {
                do {
                    let request = try Self.makeStreamRequest(
                        configuration: configuration,
                        model: model,
                        effort: effort,
                        messages: messages
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validateStatus(response)
                    guard self.contentTypeIsSSE(response) else {
                        throw GatewayClientError.unexpectedContentType
                    }
                    if let route = Self.routedModel(from: response, apiKey: configuration.apiKey) {
                        try Self.enqueue(.route(route), into: continuation)
                    }
                    try await Self.consume(bytes: bytes, apiKey: configuration.apiKey) { event in
                        try Self.enqueue(event, into: continuation)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: Self.safeError(error, apiKey: configuration.apiKey))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func checkStatus(_ response: URLResponse) throws {
        try Self.validateStatus(response)
    }

    func contentTypeIsSSE(_ response: URLResponse) -> Bool {
        response.mimeType?.lowercased() == "text/event-stream"
    }

    static func routedModel(from response: URLResponse, apiKey: String) -> String? {
        guard let raw = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "X-Magpie-Model") else { return nil }
        let route = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !route.isEmpty, route.utf8.count <= 256,
              apiKey.isEmpty || !route.contains(apiKey),
              route.rangeOfCharacter(from: .controlCharacters) == nil,
              route.range(of: #"https?://|Bearer\s"#, options: .regularExpression) == nil else {
            return nil
        }
        return route
    }

    static func makeStreamRequest(configuration: GatewayConfiguration, model: String, effort: String?,
                                  messages: [ChatMessage]) throws -> URLRequest {
        let url = try validatedBaseURL(configuration.baseURL).appendingPathComponent("responses")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request, configuration: configuration, accept: "text/event-stream")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let input: [[String: String]] = messages.compactMap { message in
            guard message.role == .user || (message.role == .assistant && message.status == .complete) else {
                return nil
            }
            return ["role": message.role.rawValue, "content": message.text]
        }
        var body: [String: Any] = ["model": model, "input": input, "stream": true, "store": false]
        if let effort, !effort.isEmpty {
            body["reasoning"] = ["effort": effort]
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw GatewayClientError.invalidResponse
        }
        return request
    }

    private static func applyHeaders(to request: inout URLRequest, configuration: GatewayConfiguration,
                                     accept: String) {
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        request.setValue(accept, forHTTPHeaderField: "Accept")
    }

    private static func validateStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw GatewayClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayClientError.httpStatus(http.statusCode)
        }
    }

    static func decodeModels(_ data: Data) throws -> [GatewayModel] {
        do {
            let envelope = try JSONDecoder().decode(GatewayModelList.self, from: data)
            return envelope.data
        } catch {
            throw GatewayClientError.invalidResponse
        }
    }

    static func consume<S: AsyncSequence>(
        bytes: S,
        apiKey: String,
        maximumTextBytes: Int = GatewayClient.maximumResponseTextBytes,
        emit: (GatewayEvent) throws -> Void
    ) async throws where S.Element == UInt8 {
        var parser = SSEParser()
        var state = StreamState(maximumTextBytes: max(1, maximumTextBytes))
        var batch: [UInt8] = []
        batch.reserveCapacity(byteBatchSize)

        func handle(_ frames: [SSEFrame]) throws -> Bool {
            for frame in frames {
                if try process(frame: frame, apiKey: apiKey, state: &state, emit: emit) {
                    return true
                }
            }
            return false
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            batch.append(byte)
            if batch.count == byteBatchSize || byte == 0x0A {
                if try handle(parser.append(batch)) { return }
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty, try handle(parser.append(batch)) { return }
        if try handle(parser.finish()) { return }
        guard state.didComplete else { throw GatewayClientError.unexpectedEOF }
    }

    /// Returns true only for the authoritative `response.completed` terminal event.
    static func process(frame: SSEFrame, apiKey: String, state: inout StreamState,
                        emit: (GatewayEvent) throws -> Void) throws -> Bool {
        guard let data = frame.data else { return false }
        guard !state.didComplete else { return false }
        if data == "[DONE]" { return false }

        guard let json = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let type = object["type"] as? String else {
            throw GatewayClientError.protocolError
        }

        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = object["delta"] as? String else {
                throw GatewayClientError.protocolError
            }
            try state.appendDelta(delta, emit: emit)

        case "response.completed":
            let response = object["response"] as? [String: Any]
            guard response?["status"] as? String == "completed" else {
                throw GatewayClientError.incompleteResponse
            }
            let finalText = finalOutputText(response?["output"])
            let fallback = try state.completionText(finalText)
            try emit(.completed(text: fallback))
            state.didComplete = true
            return true

        case "response.failed":
            let response = object["response"] as? [String: Any]
            let message = (response?["error"] as? [String: Any])?["message"] as? String
            throw GatewayClientError.remoteFailure(safeRemoteMessage(message, apiKey: apiKey))

        case "response.incomplete":
            throw GatewayClientError.incompleteResponse

        case "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String
                ?? object["message"] as? String
            throw GatewayClientError.remoteFailure(safeRemoteMessage(message, apiKey: apiKey))

        default:
            break
        }
        return false
    }

    static func enqueue(_ event: GatewayEvent,
                        into continuation: AsyncThrowingStream<GatewayEvent, Error>.Continuation) throws {
        switch continuation.yield(event) {
        case .enqueued:
            return
        case .dropped:
            throw GatewayClientError.bufferOverflow
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw GatewayClientError.bufferOverflow
        }
    }

    private static func finalOutputText(_ output: Any?) -> String? {
        guard let items = output as? [[String: Any]] else { return nil }
        let text = items.flatMap { item -> [String] in
            if item["type"] as? String == "refusal", let refusal = item["refusal"] as? String {
                return [refusal]
            }
            guard item["type"] as? String == "message",
                  let content = item["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { part in
                switch part["type"] as? String {
                case "output_text":
                    return part["text"] as? String
                case "refusal":
                    return part["refusal"] as? String
                default:
                    return nil
                }
            }
        }.joined()
        return text.isEmpty ? nil : text
    }

    private static func safeRemoteMessage(_ message: String?, apiKey: String) -> String {
        _ = message
        _ = apiKey
        return "The gateway could not complete the response."
    }

    static func safeError(_ error: Error, apiKey: String) -> Error {
        if error is CancellationError { return CancellationError() }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return CancellationError()
        }
        if let gatewayError = error as? GatewayClientError {
            if case .remoteFailure = gatewayError {
                return GatewayClientError.remoteFailure(safeRemoteMessage(nil, apiKey: apiKey))
            }
            return gatewayError
        }
        if let parserError = error as? SSEParserError {
            switch parserError {
            case .remoteFailure:
                return GatewayClientError.remoteFailure(safeRemoteMessage(nil, apiKey: apiKey))
            case .incompleteResponse:
                return GatewayClientError.incompleteResponse
            case .unexpectedEOF:
                return GatewayClientError.unexpectedEOF
            case .frameTooLarge:
                return GatewayClientError.responseTooLarge
            case .invalidUTF8, .invalidEvent:
                return GatewayClientError.protocolError
            }
        }
        return GatewayClientError.invalidResponse
    }
}

struct StreamState {
    let maximumTextBytes: Int
    var didComplete = false
    private(set) var deltaText = ""
    private(set) var acceptedTextBytes = 0

    mutating func appendDelta(_ delta: String, emit: (GatewayEvent) throws -> Void) throws {
        let bytes = delta.utf8.count
        guard acceptedTextBytes <= maximumTextBytes - bytes else {
            throw GatewayClientError.responseTooLarge
        }
        acceptedTextBytes += bytes
        deltaText += delta
        try emit(.delta(delta))
    }

    mutating func completionText(_ finalText: String?) throws -> String? {
        guard let finalText, !finalText.isEmpty, finalText != deltaText else {
            return nil
        }
        let bytes = finalText.utf8.count
        guard acceptedTextBytes <= maximumTextBytes - bytes else {
            throw GatewayClientError.responseTooLarge
        }
        acceptedTextBytes += bytes
        return finalText
    }
}

private final class RedirectDenyingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
