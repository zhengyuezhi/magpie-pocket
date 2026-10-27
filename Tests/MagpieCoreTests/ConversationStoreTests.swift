import Foundation
import XCTest
@testable import MagpieCore

final class ConversationStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testRoundTripPersistsConversationFields() throws {
        let store = ConversationStore(directory: temporaryDirectory)
        let message = ChatMessage(
            role: .assistant,
            text: "Answer",
            status: .complete,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            routedModel: "model-a"
        )
        let conversation = Conversation(
            title: "A conversation",
            modelID: "group/layered-execute",
            effort: "low",
            messages: [message],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        try store.save([conversation])

        XCTAssertEqual(try store.load(), [conversation])
        let json = try String(contentsOf: temporaryDirectory.appendingPathComponent("conversations.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("schemaVersion"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("gatewayconfiguration"))
    }

    func testMissingFileLoadsEmptyArray() throws {
        XCTAssertEqual(try ConversationStore(directory: temporaryDirectory).load(), [])
    }

    func testCorruptFileThrowsAndIsNotOverwritten() throws {
        let fileURL = temporaryDirectory.appendingPathComponent("conversations.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: fileURL)

        XCTAssertThrowsError(try ConversationStore(directory: temporaryDirectory).load())
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    }

    func testUnknownSchemaVersionThrowsAndIsNotOverwritten() throws {
        let fileURL = temporaryDirectory.appendingPathComponent("conversations.json")
        let futureSchema = Data(#"{"schemaVersion":99,"conversations":[]}"#.utf8)
        try futureSchema.write(to: fileURL)

        XCTAssertThrowsError(try ConversationStore(directory: temporaryDirectory).load()) { error in
            XCTAssertEqual(error as? ConversationStoreError, .unsupportedSchemaVersion(99))
            XCTAssertEqual(
                error.localizedDescription,
                "Unsupported conversation history schema version 99. Update Magpie Pocket and try again."
            )
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), futureSchema)
    }

    func testLoadStopsInterruptedStreamingMessagesAndPreservesPartialText() throws {
        let store = ConversationStore(directory: temporaryDirectory)
        let conversation = Conversation(messages: [
            ChatMessage(role: .assistant, text: "partial output", status: .streaming)
        ])
        try store.save([conversation])

        let loaded = try store.load()

        XCTAssertEqual(loaded[0].messages[0].text, "partial output")
        XCTAssertEqual(loaded[0].messages[0].status, .stopped)
    }

    func testAtomicOverwriteLeavesOnlyLatestCompleteDocument() throws {
        let store = ConversationStore(directory: temporaryDirectory)
        let previous = Conversation(title: "previous")
        let latest = Conversation(title: "latest", messages: [
            ChatMessage(role: .user, text: "complete replacement")
        ])

        try store.save([previous])
        try store.save([latest])

        XCTAssertEqual(try store.load(), [latest])
        let files = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        XCTAssertEqual(files, ["conversations.json"])
    }
}
