import Foundation

enum SSEParserError: Error, Equatable {
    case frameTooLarge
    case invalidUTF8
    case invalidEvent
    case remoteFailure(String)
    case incompleteResponse
    case unexpectedEOF
}

struct SSEFrame: Equatable {
    var event: String?
    var data: String?
}

/// Incrementally decodes UTF-8 SSE frames without rescanning an incomplete line.
struct SSEParser {
    static let defaultMaximumFrameBytes = 4 * 1024 * 1024

    private let maximumFrameBytes: Int
    private var pendingBytes: [UInt8] = []
    private var scanIndex = 0
    private var frameByteCount = 0
    private var dataLines: [String] = []
    private var eventName: String?

    init(maximumFrameBytes: Int = SSEParser.defaultMaximumFrameBytes) {
        self.maximumFrameBytes = max(1, maximumFrameBytes)
    }

    mutating func append(_ bytes: [UInt8]) throws -> [SSEFrame] {
        guard !bytes.isEmpty else { return [] }

        var frames: [SSEFrame] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 64 * 1024, bytes.count)
            pendingBytes.append(contentsOf: bytes[offset..<end])
            frames.append(contentsOf: try drainCompleteLines())
            offset = end
        }
        return frames
    }

    mutating func finish() throws -> [SSEFrame] {
        var frames = try drainCompleteLines()

        if !pendingBytes.isEmpty {
            var lineBytes = pendingBytes[...]
            pendingBytes.removeAll(keepingCapacity: true)
            scanIndex = 0
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            guard let line = String(bytes: lineBytes, encoding: .utf8) else {
                throw SSEParserError.invalidUTF8
            }
            if let frame = try process(line: line) { frames.append(frame) }
        }

        if let frame = dispatchFrame() { frames.append(frame) }
        frameByteCount = 0
        return frames
    }

    private mutating func drainCompleteLines() throws -> [SSEFrame] {
        var frames: [SSEFrame] = []
        var lineStart = 0

        while scanIndex < pendingBytes.count {
            let byte = pendingBytes[scanIndex]
            frameByteCount += 1
            guard frameByteCount <= maximumFrameBytes else {
                throw SSEParserError.frameTooLarge
            }

            if byte == 0x0A {
                var lineBytes = pendingBytes[lineStart..<scanIndex]
                if lineBytes.last == 0x0D { lineBytes.removeLast() }
                guard let line = String(bytes: lineBytes, encoding: .utf8) else {
                    throw SSEParserError.invalidUTF8
                }
                if let frame = try process(line: line) { frames.append(frame) }
                lineStart = scanIndex + 1
            }
            scanIndex += 1
        }

        if lineStart > 0 {
            pendingBytes.removeFirst(lineStart)
            scanIndex = pendingBytes.count
        }
        return frames
    }

    private mutating func process(line: String) throws -> SSEFrame? {
        if line.isEmpty {
            return dispatchFrame()
        }
        guard !line.hasPrefix(":") else { return nil }

        let separator = line.firstIndex(of: ":")
        let field = separator.map { String(line[..<$0]) } ?? line
        var value = separator.map { String(line[line.index(after: $0)...]) } ?? ""
        if value.first == " " { value.removeFirst() }

        switch field {
        case "data":
            dataLines.append(value)
        case "event":
            eventName = value
        default:
            break
        }
        return nil
    }

    private mutating func dispatchFrame() -> SSEFrame? {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
            frameByteCount = 0
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEFrame(event: eventName, data: dataLines.joined(separator: "\n"))
    }
}
