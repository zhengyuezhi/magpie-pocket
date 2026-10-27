import Foundation

public struct ConversationStore {
    private static let fileName = "conversations.json"
    private static let schemaVersion = 1

    private struct Envelope: Codable {
        let schemaVersion: Int
        let conversations: [Conversation]
    }

    private let directoryURL: URL
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let resolvedDirectory: URL
        if let directory {
            resolvedDirectory = directory
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            resolvedDirectory = applicationSupport.appendingPathComponent("MagpiePocket", isDirectory: true)
        }
        directoryURL = resolvedDirectory
        fileURL = resolvedDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    public func load() throws -> [Conversation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schemaVersion == Self.schemaVersion else {
            throw ConversationStoreError.unsupportedSchemaVersion(envelope.schemaVersion)
        }

        return envelope.conversations.map { conversation in
            var loaded = conversation
            loaded.messages = conversation.messages.map { message in
                var restored = message
                if restored.status == .streaming {
                    restored.status = .stopped
                }
                return restored
            }
            return loaded
        }
    }

    public func save(_ conversations: [Conversation]) throws {
        #if os(iOS)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directoryURL.path
        )
        #else
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        #endif
        try excludeFromBackup(directoryURL)

        let envelope = Envelope(schemaVersion: Self.schemaVersion, conversations: conversations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)

        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}

public enum ConversationStoreError: Error, LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported conversation history schema version \(version). Update Magpie Pocket and try again."
        }
    }
}
