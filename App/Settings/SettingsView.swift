import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""
    @State private var keyMessage: (provider: Provider, text: String, isError: Bool)?
    @State private var validating = false
    @State private var customModel = ""

    private var catalog: OpenRouterCatalog { .shared }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("服务商", selection: $settings.provider) {
                    ForEach(Provider.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.provider) {
                    keyDraft = ""
                    keyMessage = nil
                    model.resetEngine()
                }
            } footer: {
                if settings.provider == .openRouter {
                    Text("通过 OpenRouter 的 Anthropic 兼容接口调用，费用从 OpenRouter 余额扣除。")
                        .foregroundStyle(.secondary)
                }
            }

            keySection(settings.provider)

            Section("模型") {
                Picker("模型", selection: $settings.model) {
                    ForEach(settings.modelOptions) { Text($0.label).tag($0.id) }
                    if !settings.modelOptions.contains(where: { $0.id == settings.model }) {
                        Text("自定义：\(settings.model)").tag(settings.model)
                    }
                }
                if settings.provider == .openRouter {
                    customModelRow(settings)
                }
                Picker("思考强度", selection: $settings.effort) {
                    ForEach(AppSettings.efforts, id: \.id) { Text($0.label).tag($0.id) }
                }
                .disabled(!settings.isClaudeModel)
                .help(settings.isClaudeModel ? "" : "思考强度只对 Claude 模型生效")
                LabeledContent("单次请求预算上限") {
                    HStack {
                        TextField("", value: $settings.maxBudgetUsd, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("美元")
                    }
                }
            }

            if settings.provider == .openRouter && !settings.isClaudeModel {
                Section {
                    Label("Agent 引擎基于 Claude Code，针对 Claude 模型调优；其他模型可能出现工具调用异常或生成质量下降。", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    if !settings.modelSupportsVision {
                        Text("该模型不支持图像输入，Agent 的截图检查会被关闭。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
        .task(id: settings.provider) {
            if settings.provider == .openRouter { await catalog.loadIfNeeded() }
        }
    }

    private func keySection(_ provider: Provider) -> some View {
        let settings = model.settings
        let configured = settings.hasApiKey(for: provider)
        return Section {
            SecureField(provider.keyPlaceholder, text: $keyDraft)
            HStack {
                Button("验证并保存") { Task { await save(provider) } }
                    .disabled(validating || keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if configured {
                    Button("移除", role: .destructive) {
                        settings.setApiKey(nil, for: provider)
                        model.resetEngine()
                        keyMessage = nil
                    }
                }
                Spacer()
                if validating {
                    ProgressView().controlSize(.small)
                } else if let keyMessage, keyMessage.provider == provider {
                    Text(keyMessage.text)
                        .foregroundStyle(keyMessage.isError ? Color.red : Color.secondary)
                        .font(.caption)
                } else {
                    Text(configured ? "已配置" : "未配置")
                        .foregroundStyle(configured ? Color.secondary : Color.orange)
                        .font(.caption)
                }
            }
        } header: {
            Text("\(provider.label) API Key")
        } footer: {
            HStack(spacing: 4) {
                Text("Key 只保存在本机钥匙串中，生成的应用无法读取。")
                if provider == .openRouter {
                    Link("获取 Key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func save(_ provider: Provider) async {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        validating = true
        let outcome = await KeyValidator.validate(key, for: provider)
        validating = false
        switch outcome {
        case .invalid(let text):
            keyMessage = (provider, text, true)
            return
        case .valid(let text), .unknown(let text):
            model.settings.setApiKey(key, for: provider)
            model.resetEngine()
            keyDraft = ""
            keyMessage = (provider, text, false)
        }
    }

    private func customModelRow(_ settings: AppSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("自定义模型 ID，例如 openai/gpt-6.1-sol", text: $customModel)
                    .onSubmit { applyCustomModel(settings) }
                Button("使用") { applyCustomModel(settings) }
                    .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            customModelStatus
                .font(.caption)
            Link("浏览 OpenRouter 模型列表", destination: URL(string: "https://openrouter.ai/models")!)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var customModelStatus: some View {
        let id = customModel.trimmingCharacters(in: .whitespaces)
        if id.isEmpty {
            EmptyView()
        } else if catalog.isLoading {
            Text("正在加载 OpenRouter 模型列表…").foregroundStyle(.secondary)
        } else if let m = catalog.models[id] {
            Text("\(m.name)\(m.vision ? "" : " · 不支持图像")\(price(m))").foregroundStyle(.secondary)
        } else if catalog.isLoaded {
            Text("OpenRouter 上没有找到这个模型 ID").foregroundStyle(.orange)
        }
    }

    private func price(_ m: OpenRouterCatalog.Model) -> String {
        guard let i = m.inputPerMillion, let o = m.outputPerMillion else { return "" }
        return String(format: " · $%.2f / $%.2f 每百万 token", i, o)
    }

    private func applyCustomModel(_ settings: AppSettings) {
        let id = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        settings.openRouterModel = id
        customModel = ""
    }
}
