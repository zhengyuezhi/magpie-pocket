import SwiftUI
import MagpieCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    let availableModels: [GatewayModel]
    let onCatalog: ([GatewayModel], String) -> Void

    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var models: [GatewayModel] = []
    @State private var isTesting = false
    @State private var localError: String?
    @State private var testSucceeded = false

    private var canDismiss: Bool { !isTesting }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://gateway.example.com/v1", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .disabled(isTesting)
                    SecureField("新 API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isTesting)
                    Text(settings.hasKey
                         ? "已保存密钥。留空可保留同一端点的密钥；更换端点时需输入新密钥。"
                         : "密钥仅保存在设备钥匙串中。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("模型网关")
                } footer: {
                    Text("应用不会自动连接或探测网关。只有你主动测试连接时才会请求模型列表。")
                }

                Section {
                    Button {
                        Task { await saveSettings() }
                    } label: {
                        Label("保存设置", systemImage: "checkmark.circle")
                    }
                    .disabled(isTesting)

                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Label("保存并测试连接", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(isTesting)

                    Button("使用已保存设置测试") {
                        Task { await testSavedConnection() }
                    }
                    .disabled(isTesting || !settings.hasKey)

                    if testSucceeded {
                        Label("连接成功 · \(models.count) 个模型", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    if !models.isEmpty {
                        ForEach(models.prefix(6)) { model in
                            Text(model.name)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("连接检查")
                } footer: {
                    Text("模型目录只在测试成功后更新。端点或密钥变化后，旧目录不会继续展示。")
                }

                if !availableModels.isEmpty {
                    Section("当前已验证模型") {
                        ForEach(availableModels.prefix(8)) { model in
                            Text(model.name).font(.footnote)
                        }
                    }
                }

                if settings.hasKey {
                    Section {
                        Button("移除已保存密钥", role: .destructive) {
                            guard !isTesting else { return }
                            do {
                                try settings.removeKey()
                                resetCatalog()
                            } catch {
                                localError = ChatState.userFacingMessage(for: error)
                            }
                        }
                        .disabled(isTesting)
                    }
                }

                if let error = localError ?? settings.errorMessage {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("连接设置")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(!canDismiss)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .disabled(!canDismiss)
                }
            }
            .onAppear {
                endpoint = settings.baseURL
                models = availableModels
                testSucceeded = !availableModels.isEmpty
            }
            .onChange(of: endpoint) { _, _ in
                resetCatalog()
            }
            .onChange(of: apiKey) { _, _ in
                resetCatalog()
            }
            .onChange(of: settings.baseURL) { _, newValue in
                endpoint = newValue
                resetCatalog()
            }
        }
    }

    @MainActor
    private func saveSettings() async {
        guard !isTesting else { return }
        do {
            try settings.save(baseURL: endpoint, apiKey: apiKey)
            apiKey = ""
            localError = nil
            resetCatalog()
        } catch {
            localError = ChatState.userFacingMessage(for: error)
        }
    }

    @MainActor
    private func testConnection() async {
        guard !isTesting else { return }
        isTesting = true
        resetCatalog()
        defer { isTesting = false }

        do {
            try settings.save(baseURL: endpoint, apiKey: apiKey)
            apiKey = ""
            let configuration = try settings.configuration()
            let fetched = try await GatewayClient().models(configuration: configuration)
            guard let current = try? settings.configuration(),
                  current.baseURL == configuration.baseURL,
                  current.apiKey == configuration.apiKey else {
                return
            }
            publish(fetched, endpoint: configuration.baseURL)
        } catch {
            testSucceeded = false
            models = []
            localError = ChatState.userFacingMessage(for: error)
        }
    }

    @MainActor
    private func testSavedConnection() async {
        guard !isTesting else { return }
        isTesting = true
        resetCatalog()
        defer { isTesting = false }

        do {
            let configuration = try settings.configuration()
            let fetched = try await GatewayClient().models(configuration: configuration)
            guard let current = try? settings.configuration(),
                  current.baseURL == configuration.baseURL,
                  current.apiKey == configuration.apiKey else {
                return
            }
            publish(fetched, endpoint: configuration.baseURL)
        } catch {
            testSucceeded = false
            models = []
            localError = ChatState.userFacingMessage(for: error)
        }
    }

    @MainActor
    private func publish(_ fetched: [GatewayModel], endpoint: String) {
        var seen = Set<String>()
        let unique = fetched.filter { seen.insert($0.id).inserted }
        models = unique
        testSucceeded = true
        localError = nil
        onCatalog(unique, endpoint)
    }

    @MainActor
    private func resetCatalog() {
        models = []
        testSucceeded = false
        localError = nil
        onCatalog([], "")
    }
}
