import AgentOSCore
import SwiftUI

struct SettingsPanel: View {
  @Bindable var model: AppModel
  @Bindable var settings: ModelSettings
  init(model: AppModel) {
    self.model = model
    self.settings = model.settings
  }
  @State private var showRestore = false
  @State private var key = ""
  @State private var notice = ""
  @State private var credentialStatus = ""
  @State private var connectionNotice = ""
  @State private var validatingConnection = false
  @State private var savingKey = false
  @State private var validationTask: Task<Void, Never>?
  @State private var serviceName = "brave"
  @State private var serviceKey = ""
  @State private var mailUsername = ""
  @State private var mailIMAP = ""
  @State private var mailSMTP = ""
  @State private var mailPassword = ""
  @State private var driverName = ""
  @State private var driverURL = ""
  @State private var driverToken = ""
  @State private var ruleAction = ""
  @State private var ruleParameters = "{}"
  @State private var imageURL = ""
  @State private var imageKey = ""
  @State private var installingImage = false
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("设置").font(.title2)
        Spacer()
        Button("完成") { model.showSettings = false }
      }
      TabView {
        Form {
          Picker("服务商", selection: $settings.provider) {
            Text("Anthropic").tag("anthropic")
            Text("OpenRouter").tag("openrouter")
          }.disabled(model.busy || validatingConnection || savingKey)
            .onChange(of: settings.provider) { _, provider in
              settings.model =
                provider == "anthropic" ? "claude-opus-5-5" : "anthropic/claude-opus-5.5"
              key = ""
              connectionNotice = ""
              refreshCredentialStatus()
            }
          TextField("模型 ID", text: $settings.model)
            .disabled(model.busy || validatingConnection || savingKey)
            .onChange(of: settings.model) { _, _ in connectionNotice = "" }
          SecureField("API Key（已保存的 Key 不会回显）", text: $key)
            .disabled(model.busy || validatingConnection || savingKey)
            .onChange(of: key) { _, _ in connectionNotice = "" }
          Text(credentialStatus).font(.caption).textSelection(.enabled)
          HStack {
            Button(savingKey ? "正在保存…" : "保存到钥匙串") {
              connectionNotice = ""
              savingKey = true
              let value = key
              Task {
                defer { savingKey = false }
                do {
                  try await settings.saveKey(value)
                  key = ""
                  credentialStatus = "已保存到钥匙串并通过读取校验；尚未验证连接。"
                } catch { credentialStatus = error.localizedDescription }
              }
            }.disabled(
              key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy
                || validatingConnection || savingKey)
            Button(validatingConnection ? "正在验证…" : "验证已保存配置") { validateConnection() }
              .disabled(
                validatingConnection || savingKey || model.busy
                  || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if validatingConnection {
              ProgressView().controlSize(.small)
              Button("取消验证") { validationTask?.cancel() }
            }
          }
          if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("新 Key 尚未保存，请先保存再验证。").font(.caption).foregroundStyle(Palette.muted)
          }
          if !connectionNotice.isEmpty {
            Text(connectionNotice).font(.caption).textSelection(.enabled)
          }
          Text("验证只查询凭据与模型信息，不执行模型生成，也不发送对话内容。").font(.caption).foregroundStyle(Palette.muted)
          Picker("思考强度", selection: $settings.effort) {
            Text("低").tag("low")
            Text("中").tag("medium")
            Text("高").tag("high")
          }
          Stepper(
            "单次预算 $\(model.settings.budget,specifier:"%.1f")", value: $settings.budget,
            in: 0.1...50, step: 0.5)
          Text("私人数据不会交付给实验性模型。模型费用由你自己的账户结算。").font(.caption).foregroundStyle(Palette.muted)
        }.formStyle(.grouped).tabItem { Text("模型") }
          .onAppear { refreshCredentialStatus() }
          .onDisappear { validationTask?.cancel() }
        Form {
          Picker("服务", selection: $serviceName) {
            Text("Brave Search").tag("brave")
            Text("GitHub 发布").tag("github")
          }
          SecureField("服务凭据", text: $serviceKey)
          Button("保存到钥匙串") {
            do {
              try settings.saveCredential(serviceName, value: serviceKey)
              serviceKey = ""
              notice = "已保存"
            } catch { notice = error.localizedDescription }
          }
          Text(notice).font(.caption)
          Section("工作间") {
            TextField("镜像清单 HTTPS 地址", text: $imageURL)
            TextField("发行者 Ed25519 公钥", text: $imageKey)
            Button(installingImage ? "正在下载并校验…" : "下载或更新基础镜像") {
              installingImage = true
              Task {
                defer { installingImage = false }
                do {
                  notice = try await model.services.workbench.downloadImage(
                    manifestURL: imageURL, publicKey: imageKey, confirm: model.confirm)
                } catch { notice = error.localizedDescription }
              }
            }.disabled(installingImage || imageURL.isEmpty || imageKey.isEmpty)
            Button("开发：选择本地内核与磁盘…") {
              do {
                try model.services.workbench.install()
                notice = "镜像已安装"
              } catch { notice = error.localizedDescription }
            }.disabled(installingImage)
            Text("镜像在本机虚拟机中运行，不配置直通网卡，也不默认共享宿主文件夹。").font(.caption)
            Text("基础镜像更新用于新建的临时工作间与后端。已有工作间继续使用原磁盘，避免覆盖工具和数据。").font(.caption)
          }
          Section("系统账户") {
            Button("授权日历") {
              Task {
                do {
                  notice = try await model.services.personal.authorizeCalendar() ? "日历已授权" : "日历未授权"
                } catch { notice = error.localizedDescription }
              }
            }
            Button("授权通讯录") {
              Task {
                do {
                  notice =
                    try await model.services.personal.authorizeContacts() ? "通讯录已授权" : "通讯录未授权"
                } catch { notice = error.localizedDescription }
              }
            }
          }
          Section("邮箱") {
            TextField("邮箱地址", text: $mailUsername)
            TextField("IMAP 主机（TLS 993）", text: $mailIMAP)
            TextField("SMTP 主机（TLS 465）", text: $mailSMTP)
            SecureField("应用专用密码", text: $mailPassword)
            Button("连接邮箱") {
              do {
                try model.services.mail.save(
                  username: mailUsername, imap: mailIMAP, smtp: mailSMTP, password: mailPassword)
                mailPassword = ""
                notice = "已保存账户，开始只读同步"
              } catch { notice = error.localizedDescription }
            }
            Text(model.services.mail.status).font(.caption)
            Text("每 5 分钟读取最近 100 封中的未同步邮件，每轮最多 5 封；只保存本地摘要。完整邮件按需读取，读取不会标为已读。").font(.caption)
            ForEach(model.services.mail.accounts, id: \.id) { account in
              HStack {
                Text(account.username)
                Spacer()
                Button("断开") {
                  do { try model.services.mail.remove(account.id) } catch {
                    notice = error.localizedDescription
                  }
                }
              }
            }
          }
          Section("MCP 驱动") {
            TextField("驱动短名", text: $driverName)
            TextField("HTTPS MCP 地址", text: $driverURL)
            SecureField("Bearer Token（可空）", text: $driverToken)
            Button("连接 MCP") {
              Task {
                do {
                  try await model.services.mcp.connect(
                    name: driverName, endpoint: driverURL, token: driverToken)
                  driverToken = ""
                } catch { notice = error.localizedDescription }
              }
            }
            Text(model.services.mcp.status).font(.caption)
            ForEach(model.services.mcp.drivers) { driver in
              HStack {
                Text(driver.name)
                Spacer()
                Button("断开") {
                  do { try model.services.mcp.remove(driver.id) } catch {
                    notice = error.localizedDescription
                  }
                }
              }
            }
          }
          Section("文件夹") {
            Button("授权文件夹…") { model.authorizeFolder() }
            ForEach(model.folderList.indices, id: \.self) { i in
              let item = model.folderList[i]
              HStack {
                VStack(alignment: .leading) {
                  Text(item["title"]?.string ?? "")
                  Text(item["id"]?.string ?? "").font(.caption.monospaced())
                }
                Spacer()
                Button("撤销") {
                  Task {
                    try? await model.kernel.revokeFolder(item["id"]!.string!)
                    await model.refresh()
                  }
                }
              }
            }
          }
        }.formStyle(.grouped).tabItem { Text("系统服务") }
        Group {
          if model.grants.isEmpty {
            ContentUnavailableView(
              "暂无应用授权", systemImage: "checkmark.shield",
              description: Text("安装应用并授予能力后，可以在这里查看和撤销。"))
          } else {
            List {
              ForEach(model.grants.indices, id: \.self) { i in
                let grant = model.grants[i]
                HStack {
                  VStack(alignment: .leading) {
                    Text(grant["holder"]?.string ?? "").font(.caption)
                    Text(
                      (grant["capability"]?.string ?? "") + " · " + (grant["scope"]?.string ?? "")
                    )
                    .font(.system(size: 12, design: .monospaced))
                  }
                  Spacer()
                  Button("撤销") { if let id = grant["id"]?.string { model.revoke(id) } }
                }.accessibilityElement(children: .contain)
              }
            }
          }
        }.tabItem { Text("应用授权") }
        Form {
          Text("放行规则只影响出口确认，不授予应用新的能力。只对指定动作和参数生效，撤销后下一次调用重新判断。").font(.caption)
          TextField("动作，例如 mail.send", text: $ruleAction)
          TextField("必须精确匹配的参数（JSON 对象）", text: $ruleParameters, axis: .vertical).font(
            .system(.body, design: .monospaced))
          Button("检查并添加规则") {
            Task {
              do {
                let values = try Value.parse(ruleParameters)
                guard
                  await model.confirm(
                    "以后自动放行符合条件的操作", ["action": .string(ruleAction), "equals": values])
                else { return }
                _ = try await model.kernel.addRule(action: ruleAction, equals: values)
                await model.refresh()
              } catch { notice = error.localizedDescription }
            }
          }
          Text(notice).font(.caption)
          ForEach(model.exitRules, id: \.self) { rule in
            HStack {
              VStack(alignment: .leading) {
                Text(rule["action"]?.string ?? "")
                Text(rule["parameters"]?.string ?? "").font(.caption.monospaced()).textSelection(
                  .enabled)
              }
              Spacer()
              Button("撤销") {
                Task {
                  do {
                    try await model.kernel.removeRule(rule["id"]!.string!)
                    await model.refresh()
                  } catch { notice = error.localizedDescription }
                }
              }
            }
          }
        }.formStyle(.grouped).tabItem { Text("出口规则") }
        Form {
          Section("固定自动化") {
            Button("启用登录后后台运行") {
              do {
                try BackgroundHost.enable()
                notice = "已请求后台运行；如系统要求，请在登录项设置中允许"
              } catch { notice = error.localizedDescription }
            }
            Button("停用后台运行") {
              Task {
                do {
                  try await BackgroundHost.disable()
                  notice = "已停用后台运行"
                } catch { notice = error.localizedDescription }
              }
            }
            Text("启用后，主 App 退出仍可同步邮件和执行固定计划。需要确认的操作会留下通知。前台与后台通过排他租约共用数据。").font(.caption)
            ForEach(model.automationList, id: \.self) { item in
              HStack {
                VStack(alignment: .leading) {
                  Text(item["definition"]?["name"]?.string ?? "")
                  Text("今日运行 \(item["runsToday"]?.int ?? 0) 次").font(.caption)
                }
                Spacer()
                Button(item["enabled"] == true ? "暂停" : "继续") {
                  Task {
                    do {
                      _ = try await model.runtime.route(
                        item["enabled"] == true ? "automation.pause" : "automation.resume",
                        args: ["id": item["id"]!], context: RequestContext(.user))
                      await model.refresh()
                    } catch { notice = error.localizedDescription }
                  }
                }
              }
            }
            if model.automationList.isEmpty { Text("让 Agent 把一组工具调用保存为固定计划。") }
          }
          Section("桌面外壳") {
            Button("使用系统启动台") { Task { await model.selectShell(nil) } }
            ForEach(
              model.apps.filter {
                $0.version != "draft" && $0.manifest["runtime"]?["kind"] == "web"
              }
            ) { app in
              Button("使用「\(app.title)」作为桌面") { Task { await model.selectShell(app.id) } }
            }
            Button("进入恢复模式") {
              model.showSettings = false
              model.safeMode = true
            }
          }
        }.formStyle(.grouped).tabItem { Text("自动化与桌面") }
        VStack(alignment: .leading, spacing: 20) {
          Text("数据长存，应用可抛。").font(.title3)
          Text("卸载或回滚应用不删除共享数据。导出包含集合、schema 和来源标签。").foregroundStyle(Palette.muted)
          Button("导出全部数据…") { model.exportData() }
          Button("导入数据备份…") { model.importData() }
          Button("备份、分组恢复与联合更新…") { showRestore = true }
          Button("导入签名应用包…") { model.importApp() }
          Button("检查 AgentOS 更新") { Updates.shared.check() }.disabled(!Updates.shared.configured)
          if !Updates.shared.configured { Text("开发构建尚未配置签名更新源。").font(.caption) }
          Button("在 Finder 中查看数据目录") { NSWorkspace.shared.open(model.root) }
          Spacer()
        }.padding(24).tabItem { Text("数据") }
      }
    }.padding(24).frame(width: 720, height: 540).preferredColorScheme(.dark)
      .sheet(isPresented: $showRestore) { DataRecoveryPanel(model: model) }
  }
  private func refreshCredentialStatus() {
    let provider = settings.provider
    credentialStatus = "正在检查保存状态…"
    Task {
      let status = await settings.credentialStatus()
      if provider == settings.provider { credentialStatus = status }
    }
  }
  private func validateConnection() {
    connectionNotice = "正在读取已保存的凭据…"
    validatingConnection = true
    validationTask = Task {
      defer {
        validatingConnection = false
        validationTask = nil
      }
      do {
        let connection = try await settings.connection()
        credentialStatus = "已读取当前配置的 API Key。"
        connectionNotice = "正在验证服务商与模型…"
        connectionNotice = try await connection.validate()
      } catch is CancellationError {
        connectionNotice = "验证已取消。"
      } catch {
        connectionNotice = error.localizedDescription
      }
    }
  }
}
