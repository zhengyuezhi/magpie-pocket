import SwiftUI
import MagpieCore

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var state = ChatState()
    @State private var showingSettings = false
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @State private var draft = ""
    @State private var renameTarget: Conversation?
    @State private var renameText = ""
    @State private var deleteTarget: Conversation?
    @State private var retryTarget: ChatMessage?

    private let ink = Color(red: 0.18, green: 0.20, blue: 0.20)
    private let orange = Color(red: 0.86, green: 0.34, blue: 0.16)
    private let paper = Color(red: 0.96, green: 0.94, blue: 0.89)

    private var sortedAvailableModels: [GatewayModel] {
        state.availableModels.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var displayedModels: [GatewayModel] {
        sortedAvailableModels.isEmpty ? GatewayModel.presets : sortedAvailableModels
    }

    private var selectedModel: GatewayModel? {
        guard let conversation = state.current else { return nil }
        return displayedModels.first { $0.id == conversation.modelID }
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            sidebar
        } detail: {
            chat
        }
        .navigationSplitViewStyle(.balanced)
        .tint(orange)
        .background(paper)
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                availableModels: state.availableModels,
                onCatalog: { models, endpoint in
                    state.setAvailableModels(models, endpoint: endpoint)
                }
            )
            .environmentObject(settings)
            .presentationDetents([.medium, .large])
        }
        .onChange(of: showingSettings) { _, presented in
            state.setSettingsPresented(presented)
        }
        .alert("重命名对话", isPresented: renamePresented) {
            TextField("对话名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") {
                if let renameTarget { state.rename(renameTarget, to: renameText) }
                renameTarget = nil
            }
        }
        .confirmationDialog("删除此对话？", isPresented: deletePresented, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let deleteTarget { state.delete(deleteTarget) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("本地记录会一并删除，此操作无法撤销。")
        }
        .confirmationDialog("替换未完成的回复？", isPresented: retryPresented, titleVisibility: .visible) {
            Button("替换并重试", role: .destructive) {
                if let retryTarget { state.retry(retryTarget.id, settings: settings) }
                retryTarget = nil
            }
            Button("取消", role: .cancel) { retryTarget = nil }
        } message: {
            Text("重试会替换上一条未完成回复及其已保留的部分内容。你的消息不会重复添加。")
        }
        .onChange(of: state.isGenerating) { _, generating in
            if generating { showingSettings = false }
        }
        .onChange(of: showingSettings) { _, presented in
            if presented && state.isGenerating {
                showingSettings = false
            }
        }
        .onChange(of: settings.baseURL) { _, _ in
            state.clearAvailableModels()
        }
        .task {
            let screenshotMode = ProcessInfo.processInfo.arguments.contains("--screenshot-mode")
            if !settings.hasKey && !screenshotMode { showingSettings = true }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var retryPresented: Binding<Bool> {
        Binding(get: { retryTarget != nil }, set: { if !$0 { retryTarget = nil } })
    }

    private var sidebar: some View {
        List(selection: Binding(get: { state.selectedID }, set: { selectConversation($0) })) {
            Section {
                if !settings.hasKey {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("先连接你的网关").font(.headline)
                        Text("设置端点和 API Key 后即可开始。不会自动发起网络请求。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("打开设置") { showingSettings = true }
                            .disabled(state.isGenerating)
                    }
                    .padding(.vertical, 6)
                }
                if state.loadError != nil {
                    Label("本地历史不可用", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section("最近对话") {
                ForEach(state.conversations) { conversation in
                    Text(conversation.title)
                        .tag(conversation.id)
                        .contextMenu {
                            Button("重命名") {
                                renameTarget = conversation
                                renameText = conversation.title
                            }
                            .disabled(!state.canMutate)
                            Button("删除对话", role: .destructive) { deleteTarget = conversation }
                                .disabled(!state.canMutate)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { deleteTarget = conversation }
                                .disabled(!state.canMutate)
                        }
                }
            }
        }
        .navigationTitle("Magpie")
        .overlay {
            if state.conversations.isEmpty && state.loadError == nil {
                ContentUnavailableView(
                    "还没有对话",
                    systemImage: "text.bubble",
                    description: Text("新建对话，开始一段专注的思考。")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .disabled(state.isGenerating)
                .accessibilityLabel("连接设置")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { createConversation() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(!state.canMutate)
                .accessibilityLabel("新建对话")
            }
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            compactBackButton
            if let loadError = state.loadError {
                warningBanner(loadError, dismissible: false)
            }
            if let error = state.operationError {
                warningBanner(error, dismissible: true)
            }
            if let conversation = state.current {
                conversationHeader(conversation)
                messageList(conversation)
                composer
            } else {
                gettingStarted
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var gettingStarted: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("MAGPIE POCKET")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(orange)
                Text("一段清晰的\n思考旅程。")
                    .font(.system(size: 42, weight: .regular, design: .serif))
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(settings.hasKey
                     ? "选择模型，开始一段专注的对话。"
                     : "配置自己的模型网关，开始一段专注的对话。")
                    .foregroundStyle(.secondary)
                    .font(.body)
                Button { createConversation() } label: {
                    Label("开始新对话", systemImage: "arrow.up.right")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 13)
                        .background(orange)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .disabled(state.loadError != nil || state.isGenerating)
                if !settings.hasKey {
                    Button("配置网关与密钥") { showingSettings = true }
                        .font(.subheadline.weight(.semibold))
                        .disabled(state.isGenerating)
                }
            }
            .padding(30)
            .frame(maxWidth: 580, maxHeight: .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var compactBackButton: some View {
        if horizontalSizeClass == .compact {
            HStack {
                Button {
                    preferredCompactColumn = .sidebar
                } label: {
                    Label("对话列表", systemImage: "chevron.left")
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityHint("返回最近对话列表")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private func conversationHeader(_ conversation: Conversation) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.system(size: 19, weight: .regular, design: .serif))
                    .lineLimit(1)
                Text(selectedModel?.name ?? conversation.modelID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Picker("模型", selection: Binding(
                    get: { conversation.modelID },
                    set: { id in
                        if let model = displayedModels.first(where: { $0.id == id }) {
                            state.setModel(model, effort: defaultEffort(for: model))
                        }
                    }
                )) {
                    Section(state.availableModels.isEmpty ? "分层模型 · 预设，未验证" : "分层模型") {
                        ForEach(displayedModels.filter(\.isGroup)) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    Section("其他模型") {
                        ForEach(displayedModels.filter { !$0.isGroup }) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
                if let model = selectedModel,
                   let levels = model.reasoningLevels,
                   !levels.isEmpty {
                    Picker("推理强度", selection: Binding(
                        get: { conversation.effort ?? levels[0] },
                        set: { state.setModel(model, effort: $0) }
                    )) {
                        ForEach(levels, id: \.self) { level in
                            Text(effortLabel(level)).tag(level)
                        }
                    }
                }
                if state.availableModels.isEmpty {
                    Label("预设模型尚未验证", systemImage: "exclamationmark.circle")
                        .font(.caption)
                }
                Button("连接设置") { showingSettings = true }
                    .disabled(state.isGenerating)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.headline)
                    .padding(10)
                    .background(.white.opacity(0.8), in: Circle())
            }
            .disabled(state.isGenerating || state.loadError != nil)
            .accessibilityLabel("模型与推理设置")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(paper)
    }

    private func messageList(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if conversation.messages.isEmpty {
                        Text("今天想探索什么？")
                            .font(.system(size: 27, design: .serif))
                            .foregroundStyle(ink.opacity(0.72))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 90)
                    }
                    ForEach(conversation.messages) { message in
                        MessageView(
                            message: message,
                            onRetry: retryAction(for: message, in: conversation)
                        )
                        .id(message.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: conversation.messages.last?.text) { _, _ in
                if let last = conversation.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(paper)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !canSend {
                endpointHint
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("写下你的想法…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    .disabled(state.isGenerating || state.loadError != nil)
                    .onSubmit { sendDraft() }
                if state.isGenerating {
                    Button { state.stopGeneration() } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.white)
                            .padding(13)
                            .background(ink, in: Circle())
                    }
                    .accessibilityLabel("停止生成")
                } else {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(orange, in: Circle())
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("发送")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(paper)
    }

    private var canSend: Bool {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.hasKey,
              state.loadError == nil,
              !state.isGenerating,
              !state.isSettingsPresented,
              let conversation = state.current,
              selectedModelIsAvailable(conversation) else {
            return false
        }
        if conversation.messages.isEmpty { return true }
        return conversation.gatewayEndpoint == settings.baseURL
    }

    @ViewBuilder
    private var endpointHint: some View {
        if let conversation = state.current,
           !selectedModelIsAvailable(conversation) {
            Text("当前模型不在已验证的模型目录中。请从上方模型菜单选择一个可用模型。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let conversation = state.current,
           !conversation.messages.isEmpty,
           conversation.gatewayEndpoint == nil {
            Text("此旧对话未记录网关端点。为保护历史记录，请新建对话后继续。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let conversation = state.current,
                  !conversation.messages.isEmpty,
                  conversation.gatewayEndpoint != settings.baseURL {
            Text("此对话绑定到另一个网关。为避免发送历史到新端点，请新建对话后继续。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func warningBanner(_ message: String, dismissible: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
            Spacer()
            if dismissible {
                Button {
                    state.dismissOperationError()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("关闭错误提示")
            }
        }
        .font(.footnote)
        .foregroundStyle(.red)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.red.opacity(0.07))
    }

    private func sendDraft() {
        let value = draft
        if state.send(value, settings: settings) {
            draft = ""
        }
    }

    private func createConversation() {
        state.createConversation()
        showDetailIfCompact()
    }

    private func selectConversation(_ id: UUID?) {
        state.select(id)
        if id != nil { showDetailIfCompact() }
    }

    private func showDetailIfCompact() {
        if horizontalSizeClass == .compact {
            preferredCompactColumn = .detail
        }
    }

    private func retryAction(for message: ChatMessage, in conversation: Conversation) -> (() -> Void)? {
        guard message.role == .assistant,
              message.status == .failed || message.status == .stopped,
              conversation.messages.last?.id == message.id else {
            return nil
        }
        return { retryTarget = message }
    }

    private func selectedModelIsAvailable(_ conversation: Conversation) -> Bool {
        guard !state.availableModels.isEmpty else { return true }
        guard state.availableModelsEndpoint == settings.baseURL else { return false }
        return state.availableModels.contains { $0.id == conversation.modelID }
    }

    private func defaultEffort(for model: GatewayModel) -> String? {
        guard let levels = model.reasoningLevels, !levels.isEmpty else { return nil }
        if model.id == "group/layered-plan", levels.contains("high") { return "high" }
        if model.id == "group/layered-execute", levels.contains("low") { return "low" }
        return levels.first
    }

    private func effortLabel(_ level: String) -> String {
        switch level.lowercased() {
        case "minimal": return "极低"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh", "max": return "极高"
        default: return level
        }
    }
}
