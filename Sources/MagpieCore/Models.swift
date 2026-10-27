import Foundation

public struct GatewayModel: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String?
    public let reasoningLevels: [String]?
    public var name: String { displayName ?? id }
    public var isGroup: Bool { id.hasPrefix("group/") || id.hasPrefix("auto/") }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case reasoningLevels = "reasoning_levels"
    }

    public init(id: String, displayName: String? = nil, reasoningLevels: [String]? = nil) {
        self.id = id
        self.displayName = displayName
        self.reasoningLevels = reasoningLevels
    }

    public static let presets: [GatewayModel] = [
        .init(id: "group/layered-plan", displayName: "Layered Plan", reasoningLevels: ["high"]),
        .init(id: "group/layered-execute", displayName: "Layered Execute", reasoningLevels: ["low"])
    ]
}

public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public enum Status: String, Codable, Sendable { case complete, streaming, stopped, failed }
    public var id: UUID
    public var role: Role
    public var text: String
    public var status: Status
    public var createdAt: Date
    public var routedModel: String?

    public init(id: UUID = UUID(), role: Role, text: String, status: Status = .complete,
                createdAt: Date = Date(), routedModel: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.status = status
        self.createdAt = createdAt
        self.routedModel = routedModel
    }
}

public struct Conversation: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var modelID: String
    public var effort: String?
    public var messages: [ChatMessage]
    public var updatedAt: Date
    public var gatewayEndpoint: String?

    public init(id: UUID = UUID(), title: String = "New conversation",
                modelID: String = "group/layered-execute", effort: String? = "low",
                messages: [ChatMessage] = [], updatedAt: Date = Date(), gatewayEndpoint: String? = nil) {
        self.id = id
        self.title = title
        self.modelID = modelID
        self.effort = effort
        self.messages = messages
        self.updatedAt = updatedAt
        self.gatewayEndpoint = gatewayEndpoint
    }
}

public struct GatewayConfiguration: Sendable {
    public let baseURL: String
    public let apiKey: String
    public init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

public enum GatewayEvent: Equatable, Sendable {
    case delta(String)
    case route(String)
    case completed(text: String?)
}
