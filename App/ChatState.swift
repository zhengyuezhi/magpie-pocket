import Foundation
import SwiftUI
import MagpieCore

@MainActor
final class ChatState: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published var selectedID: UUID?
    @Published private(set) var loadError: String?
    @Published private(set) var operationError: String?
    @Published private(set) var isGenerating = false
    @Published private(set) var availableModels: [GatewayModel] = []
    @Published private(set) var availableModelsEndpoint: String?
    @Published private(set) var generationToken: UUID?
    @Published private(set) var isSettingsPresented = false

    private struct GenerationContext: Sendable {
        let token: UUID
        let conversationID: UUID
        let messageID: UUID
    }

    private enum ConversationEndpointError: LocalizedError {
        case unknownLegacyEndpoint
        case changedEndpoint
        case modelUnavailable
        case modelCatalogUnavailable

        var errorDescription: String? {
            switch self {
            case .unknownLegacyEndpoint:
                return "此旧对话没有记录网关端点，无法安全续聊。请新建对话后继续。"
            case .changedEndpoint:
                return "此对话已绑定到另一个网关。为避免把历史记录发送到新端点，请新建对话后继续。"
            case .modelUnavailable:
                return "当前模型不在已验证的模型目录中。请先从模型菜单选择一个可用模型。"
            case .modelCatalogUnavailable:
                return "模型目录与当前网关不匹配。请重新测试连接后再试。"
            }
        }
    }

    private let store = ConversationStore()
    private var generationTask: Task<Void, Never>?
    private var activeGeneration: GenerationContext?
    private var lastCheckpointAt: Date?

    var canMutate: Bool { loadError == nil && !isGenerating && !isSettingsPresented }
    var current: Conversation? { conversations.first { $0.id == selectedID } }

    init() {
        do {
            conversations = try store.load()
            selectedID = conversations.first?.id
        } catch {
            loadError = "无法读取本地对话记录：\(error.localizedDescription)"
        }
        NotificationCenter.default.addObserver(forName: .magpieDidEnterBackground, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopGeneration() }
        }
    }

    func createConversation() {
        guard canMutate else { return }
        let previous = conversations
        let previousSelection = selectedID
        let conversation = Conversation(title: "新对话")
        conversations.insert(conversation, at: 0)
        selectedID = conversation.id
        do {
            try persistOrThrow()
        } catch {
            conversations = previous
            selectedID = previousSelection
            setPersistenceError(error)
        }
    }

    func rename(_ conversation: Conversation, to title: String) {
        guard canMutate, let index = index(of: conversation.id) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let previous = conversations[index]
        conversations[index].title = String(clean.prefix(80))
        conversations[index].updatedAt = Date()
        do {
            try persistOrThrow()
        } catch {
            conversations[index] = previous
            setPersistenceError(error)
        }
    }

    func delete(_ conversation: Conversation) {
        guard canMutate else { return }
        let previous = conversations
        let previousSelection = selectedID
        conversations.removeAll { $0.id == conversation.id }
        if selectedID == conversation.id { selectedID = conversations.first?.id }
        do {
            try persistOrThrow()
        } catch {
            conversations = previous
            selectedID = previousSelection
            setPersistenceError(error)
        }
    }

    func select(_ id: UUID?) {
        selectedID = id
    }

    func setSettingsPresented(_ presented: Bool) {
        isSettingsPresented = presented
    }

    func setModel(_ model: GatewayModel, effort: String?) {
        guard canMutate, let id = selectedID, let index = index(of: id) else { return }
        let previous = conversations[index]
        conversations[index].modelID = model.id
        conversations[index].effort = effort
        conversations[index].updatedAt = Date()
        do {
            try persistOrThrow()
        } catch {
            conversations[index] = previous
            setPersistenceError(error)
        }
    }

    func setAvailableModels(_ models: [GatewayModel], endpoint: String) {
        var seen = Set<String>()
        availableModels = models.filter { seen.insert($0.id).inserted }
        availableModelsEndpoint = endpoint
    }

    func clearAvailableModels() {
        availableModels = []
        availableModelsEndpoint = nil
    }

    func dismissOperationError() {
        operationError = nil
    }

    @discardableResult
    func send(_ text: String, settings: AppSettings) -> Bool {
        guard canMutate, let id = selectedID, let index = index(of: id) else { return false }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return false }

        do {
            let configuration = try settings.configuration()
            let prior = conversations[index]
            if !prior.messages.isEmpty {
                try validateEndpoint(prior.gatewayEndpoint, current: configuration.baseURL)
            }
            try validateSelectedModel(prior.modelID, endpoint: configuration.baseURL)

            let userMessage = ChatMessage(role: .user, text: content)
            let assistant = ChatMessage(role: .assistant, text: "", status: .streaming)
            if conversations[index].messages.isEmpty {
                conversations[index].gatewayEndpoint = configuration.baseURL
            }
            conversations[index].messages.append(contentsOf: [userMessage, assistant])
            if conversations[index].messages.filter({ $0.role == .user }).count == 1 {
                conversations[index].title = String(content.prefix(36))
            }
            conversations[index].updatedAt = Date()

            do {
                try persistOrThrow()
            } catch {
                conversations[index] = prior
                setPersistenceError(error)
                return false
            }

            operationError = nil
            beginGeneration(conversationID: id, assistantID: assistant.id, configuration: configuration)
            return true
        } catch {
            operationError = Self.userFacingMessage(for: error)
            return false
        }
    }

    @discardableResult
    func retry(_ assistantID: UUID, settings: AppSettings) -> Bool {
        guard canMutate, let id = selectedID, let index = index(of: id) else { return false }
        let messages = conversations[index].messages
        guard let messageIndex = messages.firstIndex(where: { $0.id == assistantID }),
              messages[messageIndex].role == .assistant,
              messages[messageIndex].status == .failed || messages[messageIndex].status == .stopped,
              messageIndex == messages.index(before: messages.endIndex),
              messages[..<messageIndex].contains(where: { $0.role == .user }) else {
            return false
        }

        do {
            let configuration = try settings.configuration()
            try validateEndpoint(conversations[index].gatewayEndpoint, current: configuration.baseURL)
            try validateSelectedModel(conversations[index].modelID, endpoint: configuration.baseURL)
            let original = conversations[index].messages[messageIndex]
            let replacement = ChatMessage(role: .assistant, text: "", status: .streaming)
            conversations[index].messages[messageIndex] = replacement
            conversations[index].updatedAt = Date()

            do {
                try persistOrThrow()
            } catch {
                conversations[index].messages[messageIndex] = original
                setPersistenceError(error)
                return false
            }

            operationError = nil
            beginGeneration(conversationID: id, assistantID: replacement.id, configuration: configuration)
            return true
        } catch {
            operationError = Self.userFacingMessage(for: error)
            return false
        }
    }

    func stopGeneration() {
        guard isGenerating, let context = activeGeneration else { return }
        generationTask?.cancel()
        // This invalidates the token synchronously; the cancelled task can no longer settle state.
        finishGeneration(context: context, status: .stopped, error: nil)
    }

    static func userFacingMessage(for error: Error) -> String {
        if let endpointError = error as? ConversationEndpointError {
            return endpointError.errorDescription ?? "此对话不能继续使用当前网关。"
        }
        if let credentialError = error as? CredentialError {
            switch credentialError {
            case .unavailable:
                return "无法访问钥匙串。请解锁设备后重试。"
            case .missing:
                return "请先在设置中填写 HTTPS 网关端点和 API Key。"
            case .endpointChanged:
                return "网关端点已更改，请为新端点输入对应的 API Key。"
            case .invalidKey:
                return "API Key 不能包含空白或控制字符。"
            }
        }
        if let gatewayError = error as? GatewayClientError {
            switch gatewayError {
            case .invalidBaseURL:
                return "网关地址无效，请填写完整的 HTTPS /v1 端点。"
            case .invalidResponse:
                return "网关返回了无法识别的响应。请检查连接设置后重试。"
            case .httpStatus(let status):
                return "网关请求失败（HTTP \(status)）。请检查端点、密钥和模型权限。"
            case .unexpectedContentType:
                return "网关没有返回流式响应。请确认端点兼容 Responses 流式接口。"
            case .remoteFailure:
                return "网关未能完成请求。请检查模型、密钥或端点后重试。"
            case .incompleteResponse:
                return "回复未完整生成。请重试。"
            case .unexpectedEOF:
                return "连接在回复完成前结束。请重试。"
            case .protocolError:
                return "网关流式协议异常。请检查端点兼容性后重试。"
            case .responseTooLarge:
                return "网关回复超过大小限制。请缩短输入或更换模型后重试。"
            case .bufferOverflow:
                return "网关响应缓冲区溢出。请重试。"
            @unknown default:
                return "网关返回了未处理的错误。请稍后重试。"
            }
        }
        return "操作失败，请检查网络和网关设置后重试。"
    }

    private func validateEndpoint(_ boundEndpoint: String?, current: String) throws {
        guard let boundEndpoint else { throw ConversationEndpointError.unknownLegacyEndpoint }
        guard boundEndpoint == current else { throw ConversationEndpointError.changedEndpoint }
    }

    private func validateSelectedModel(_ modelID: String, endpoint: String) throws {
        guard !availableModels.isEmpty else { return }
        guard availableModelsEndpoint == endpoint else {
            throw ConversationEndpointError.modelCatalogUnavailable
        }
        guard availableModels.contains(where: { $0.id == modelID }) else {
            throw ConversationEndpointError.modelUnavailable
        }
    }

    private func beginGeneration(conversationID: UUID, assistantID: UUID,
                                 configuration: GatewayConfiguration) {
        guard !isSettingsPresented,
              activeGeneration == nil,
              let conversation = conversations.first(where: { $0.id == conversationID }) else {
            operationError = "无法开始生成。请重新打开对话后再试。"
            return
        }

        let context = GenerationContext(token: UUID(), conversationID: conversationID, messageID: assistantID)
        activeGeneration = context
        generationToken = context.token
        isGenerating = true
        lastCheckpointAt = Date()
        operationError = nil

        let requestMessages = conversation.messages
        let model = conversation.modelID
        let effort = normalizedEffort(conversation.effort, modelID: model)
        let client = GatewayClient()

        generationTask = Task { [weak self] in
            do {
                for try await event in client.stream(configuration: configuration, model: model,
                                                      effort: effort, messages: requestMessages) {
                    try Task.checkCancellation()
                    guard let self, self.isCurrent(context) else { return }
                    switch event {
                    case .delta(let value):
                        self.append(value, context: context)
                    case .route(let value):
                        self.setRoute(value, context: context)
                    case .completed(let value):
                        if let value, !value.isEmpty {
                            self.replaceText(value, context: context)
                        }
                        self.finishGeneration(context: context, status: .complete, error: nil)
                        return
                    }
                }
                guard let self, self.isCurrent(context) else { return }
                self.finishGeneration(context: context, status: .failed,
                                      error: "连接已结束，回复未完整完成。请重试。")
            } catch is CancellationError {
                guard let self else { return }
                self.finishGeneration(context: context, status: .stopped, error: nil)
            } catch {
                guard let self else { return }
                self.finishGeneration(context: context, status: .failed,
                                      error: Self.userFacingMessage(for: error))
            }
        }
    }

    private func append(_ value: String, context: GenerationContext) {
        guard isCurrent(context), let index = index(of: context.conversationID),
              let message = conversations[index].messages.firstIndex(where: { $0.id == context.messageID }) else {
            return
        }
        conversations[index].messages[message].text += value
        checkpointIfNeeded(context: context)
    }

    private func replaceText(_ value: String, context: GenerationContext) {
        guard isCurrent(context), let index = index(of: context.conversationID),
              let message = conversations[index].messages.firstIndex(where: { $0.id == context.messageID }) else {
            return
        }
        conversations[index].messages[message].text = value
    }

    private func setRoute(_ route: String, context: GenerationContext) {
        guard isCurrent(context), let index = index(of: context.conversationID),
              let message = conversations[index].messages.firstIndex(where: { $0.id == context.messageID }) else {
            return
        }
        conversations[index].messages[message].routedModel = route
    }

    private func checkpointIfNeeded(context: GenerationContext) {
        guard isCurrent(context) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCheckpointAt ?? .distantPast) >= 2 else { return }
        lastCheckpointAt = now
        persist()
    }

    private func finishGeneration(context: GenerationContext, status: ChatMessage.Status, error: String?) {
        guard isCurrent(context) else { return }

        activeGeneration = nil
        generationToken = nil
        generationTask = nil
        lastCheckpointAt = nil
        isGenerating = false

        guard let index = index(of: context.conversationID),
              let message = conversations[index].messages.firstIndex(where: { $0.id == context.messageID }) else {
            if let error { operationError = error }
            return
        }

        conversations[index].messages[message].status = status
        conversations[index].updatedAt = Date()
        do {
            try persistOrThrow()
            if let error { operationError = error }
        } catch let persistenceError {
            let saveError = "本地保存失败：\(persistenceError.localizedDescription)"
            operationError = [error, saveError].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func isCurrent(_ context: GenerationContext) -> Bool {
        activeGeneration?.token == context.token
    }

    private func normalizedEffort(_ effort: String?, modelID: String) -> String? {
        guard let model = availableModels.first(where: { $0.id == modelID }),
              let levels = model.reasoningLevels,
              !levels.isEmpty else {
            return nil
        }
        guard let effort, levels.contains(effort) else {
            return levels.first
        }
        return effort
    }

    private func persist() {
        do {
            try persistOrThrow()
        } catch {
            setPersistenceError(error)
        }
    }

    private func setPersistenceError(_ error: Error) {
        operationError = "本地保存失败：\(error.localizedDescription)"
    }

    private func persistOrThrow() throws {
        try store.save(conversations)
    }

    private func index(of id: UUID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }
}
