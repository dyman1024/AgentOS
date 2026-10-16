import AgentOSCore
import AgentOSRuntime
import SwiftUI
import WebKit

enum Palette {
  static let ink = Color(red: 8 / 255, green: 8 / 255, blue: 10 / 255),
    panel = Color(red: 14 / 255, green: 14 / 255, blue: 18 / 255),
    card = Color(red: 21 / 255, green: 21 / 255, blue: 27 / 255)
  static let paper = Color(red: 242 / 255, green: 239 / 255, blue: 233 / 255),
    muted = Color(red: 138 / 255, green: 134 / 255, blue: 126 / 255),
    ember = Color(red: 1, green: 91 / 255, blue: 46 / 255),
    mint = Color(red: 110 / 255, green: 242 / 255, blue: 194 / 255),
    amber = Color(red: 245 / 255, green: 184 / 255, blue: 61 / 255)
}
struct ShellView: View {
  @Bindable var model: AppModel
  var body: some View {
    VStack(spacing: 0) {
      topBar
      Divider()
      HSplitView {
        workspace.frame(minWidth: 600)
        if model.showChat { chat.frame(minWidth: 320, idealWidth: 370, maxWidth: 470) }
      }
    }
    .background(Palette.ink).foregroundStyle(Palette.paper).tint(Palette.ember)
    .sheet(isPresented: $model.showSettings) { SettingsPanel(model: model) }
    .sheet(isPresented: $model.showActivity) { activity }
    .sheet(isPresented: $model.showVersions) { versions }
    .sheet(isPresented: $model.safeMode) {
      RecoveryPanel(model: model).interactiveDismissDisabled()
    }
    .sheet(isPresented: $model.showNotifications) { NotificationPanel(model: model) }
    .alert(
      "需要处理",
      isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    ) {
      Button("知道了") { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
  }
  private var topBar: some View {
    HStack(spacing: 18) {
      Image(systemName: "square.inset.filled").foregroundStyle(Palette.ember)
      Text("AgentOS").font(.system(size: 15, weight: .semibold))
      Spacer()
      Circle().fill(model.busy ? Palette.ember : Palette.mint).frame(width: 5, height: 5)
      Text(model.status).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
        .lineLimit(1)
      Picker("权限模式", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
        Text("谨慎").tag(PermissionMode.careful)
        Text("自动").tag(PermissionMode.auto)
        Text("完全信任").tag(PermissionMode.trust)
      }.labelsHidden().frame(width: 108)
      Button {
        model.showNotifications = true
      } label: {
        Image(systemName: "bell")
      }.help("通知中心")
      Button {
        model.showActivity = true
      } label: {
        Image(systemName: "clock.arrow.circlepath")
      }.help("活动与撤销").accessibilityLabel("活动与撤销")
      Button {
        model.showChat.toggle()
      } label: {
        Image(systemName: "sidebar.right")
      }.help("对话面板").accessibilityLabel("对话面板")
      Button {
        model.showSettings = true
      } label: {
        Image(systemName: "gearshape")
      }.help("设置").accessibilityLabel("设置")
    }.buttonStyle(.plain).padding(.horizontal, 22).padding(.vertical, 14).padding(.leading, 58)
      .background(Palette.panel)
  }
  private var workspace: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Button {
          model.home()
        } label: {
          Label("启动台", systemImage: "square.grid.2x2")
        }.padding(10).background(
          model.selected == nil ? Palette.card : .clear, in: RoundedRectangle(cornerRadius: 8))
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 4) {
            ForEach(model.tabs, id: \.self) { id in
              if let app = model.apps.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                  Button(app.title) { Task { await model.open(id) } }
                  Button {
                    model.close(id)
                  } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                  }
                  .help("关闭 " + app.title).accessibilityLabel("关闭 " + app.title)
                }.padding(10).background(
                  model.selected == id ? Palette.card : .clear,
                  in: RoundedRectangle(cornerRadius: 8))
              }
            }
          }
        }
        if model.selected != nil {
          Button {
            model.versions()
          } label: {
            Image(systemName: "clock")
          }
          .help("版本时间线").accessibilityLabel("版本时间线")
          Button {
            model.popOut()
          } label: {
            Image(systemName: "arrow.up.right.square")
          }
          .help("在独立窗口中打开").accessibilityLabel("在独立窗口中打开")
          Button {
            model.reload()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .help("重新加载应用").accessibilityLabel("重新加载应用")
        }
      }.buttonStyle(.plain).font(.system(size: 12)).padding(10).background(Palette.panel)
      Divider()
      ZStack {
        if let instance = model.currentView {
          WebPane(instance: instance, canAttach: { model.currentView === instance })
        } else if let id = model.selected, let window = model.windows[id] {
          VStack(spacing: 18) {
            Image(systemName: "macwindow.on.rectangle").font(.system(size: 36))
              .foregroundStyle(Palette.ember)
            Text("应用使用独立窗口").font(.title2)
            HStack {
              Button("显示独立窗口") { window.makeKeyAndOrderFront(nil) }
              Button("返回工作区") { Task { await model.open(id) } }
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let id = model.selected,
          model.apps.first(where: { $0.id == id })?.manifest["runtime"]?["kind"] == "macos-native"
        {
          VStack(spacing: 18) {
            Text("原生应用使用独立窗口").font(.title2)
            Button("打开原生窗口") { Task { await model.open(id) } }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.selected != nil {
          VStack(spacing: 18) {
            Image(systemName: "sparkle").font(.system(size: 36)).foregroundStyle(Palette.ember)
            Text("正在生长").font(.custom("Songti SC", size: 36))
            Text("源码和接口通过验证后，应用将在这里打开。").foregroundStyle(Palette.muted)
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          launcher
        }
      }
      busStrip
    }
  }
  private var launcher: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        HStack {
          Text("你的空间").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(3)
            .foregroundStyle(Palette.muted)
          Spacer()
          Text("\(model.apps.count) 个应用").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Text(model.apps.isEmpty ? "从一句话，\n开始生长。" : "让想法，\n成为日常。").font(
          .custom("Songti SC", size: 55)
        ).lineSpacing(2)
        Text("应用为你而生，数据始终属于你。").font(.system(size: 14)).foregroundStyle(Palette.muted)
        if model.apps.isEmpty {
          HStack(spacing: 10) {
            suggestion("做一个笔记应用", icon: "note.text")
            suggestion("做一个贪吃蛇", icon: "gamecontroller")
            suggestion("管理我的待办", icon: "checklist")
          }.padding(.top, 12)
        } else {
          TextField("搜索应用", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
            ForEach(
              model.apps.filter {
                model.search.isEmpty || $0.title.localizedCaseInsensitiveContains(model.search)
              }
            ) { app in
              Button {
                Task { await model.open(app.id) }
              } label: {
                VStack(alignment: .leading, spacing: 22) {
                  Image(systemName: app.icon.contains(".") ? app.icon : "app").font(
                    .system(size: 27)
                  ).foregroundStyle(Palette.ember)
                  VStack(alignment: .leading, spacing: 6) {
                    Text(app.title).font(.system(size: 14, weight: .medium))
                    Text(app.version == "draft" ? "构建中" : app.namespace).font(
                      .system(size: 10, design: .monospaced)
                    ).foregroundStyle(Palette.muted)
                  }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(22).background(
                  Palette.card, in: RoundedRectangle(cornerRadius: 15))
              }.buttonStyle(.plain).contextMenu {
                Button("修改这个应用") {
                  Task {
                    await model.open(app.id)
                    model.role = "builder"
                  }
                }
                Button("卸载应用，保留数据", role: .destructive) { model.remove(app.id) }
                Button("签名导出应用…") { model.exportApp(app.id) }
              }
            }
          }
        }
        Spacer(minLength: 70)
        HStack(spacing: 20) {
          Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Palette.mint)
          Text("每个应用都能连接你的其他应用。\n告诉 Agent 你想完成什么。").font(.system(size: 12)).lineSpacing(5)
            .foregroundStyle(Palette.muted)
        }
      }.padding(44).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func suggestion(_ text: String, icon: String) -> some View {
    Button {
      model.send(text)
    } label: {
      Label(text, systemImage: icon).font(.system(size: 11)).padding(12).background(
        Palette.card, in: Capsule())
    }.buttonStyle(.plain).disabled(model.busy)
  }
  private var busStrip: some View {
    HStack(spacing: 12) {
      Circle().fill(Palette.mint).frame(width: 5, height: 5)
      Text("EVENT BUS").font(.system(size: 9, design: .monospaced)).tracking(1.5)
      Divider().frame(height: 12)
      if let last = model.events.last?["event"] {
        Text(last["type"]?.string ?? "").font(.system(size: 10, design: .monospaced))
        Text(last["subject"]?.string ?? "").font(.system(size: 10)).lineLimit(1).foregroundStyle(
          Palette.muted)
      } else {
        Text("等待第一条事件").font(.system(size: 10)).foregroundStyle(Palette.muted)
      }
      Spacer()
      Text("\(model.events.count)").font(.system(size: 10, design: .monospaced))
    }.foregroundStyle(Palette.mint).padding(.horizontal, 18).frame(height: 36).background(
      Palette.panel)
  }
  private var chat: some View {
    VStack(spacing: 0) {
      HStack {
        Text("AGENT").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2)
        Spacer()
        Picker("角色", selection: $model.role) {
          Text("全局对话").tag("operator")
          Text("修改应用").tag("builder")
        }.labelsHidden().frame(width: 130)
      }.padding(20)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 22) {
            if model.messages.isEmpty {
              VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "sparkles").foregroundStyle(Palette.ember)
                Text("想做什么，直接说。").font(.system(size: 18, weight: .medium))
                Text("创建一个应用，整理一份资料，或把几个应用连起来。").font(.system(size: 13)).foregroundStyle(
                  Palette.muted
                ).lineSpacing(6)
              }.padding(.top, 35)
            }
            ForEach(model.messages) { message in
              VStack(alignment: .leading, spacing: 8) {
                Text(message.role == "user" ? "你" : message.role == "error" ? "需要处理" : "Agent")
                  .font(.system(size: 10, weight: .semibold)).foregroundStyle(
                    message.role == "user" ? Palette.muted : Palette.ember)
                Text(message.text.isEmpty ? "正在思考…" : message.text).font(.system(size: 13))
                  .lineSpacing(5).textSelection(.enabled)
                if let detail = message.detail {
                  Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(
                    Palette.muted)
                }
              }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(
                message.role == "user" ? Palette.card : .clear,
                in: RoundedRectangle(cornerRadius: 12)
              ).id(message.id)
            }
            Color.clear.frame(height: 1).id("end")
          }.padding(18)
        }.onChange(of: model.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
      }
      if model.busy {
        HStack(spacing: 8) {
          ProgressView().controlSize(.mini)
          Text(model.status).font(.system(size: 10, design: .monospaced))
          Spacer()
          Button("停止") { model.cancel() }
        }.padding(.horizontal, 20).padding(.bottom, 12).foregroundStyle(Palette.ember)
      }
      VStack(alignment: .leading, spacing: 10) {
        TextField("说说你想做什么…", text: $model.input, axis: .vertical).textFieldStyle(.plain).lineLimit(
          2...7
        ).font(.system(size: 13)).onSubmit { model.send() }
        HStack {
          Text(model.role == "builder" ? "Builder · 构建与验证" : "Operator · 连接你的应用").font(
            .system(size: 9)
          ).foregroundStyle(Palette.muted)
          Spacer()
          Button {
            model.send()
          } label: {
            Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).padding(8)
              .background(Palette.ember, in: Circle()).foregroundStyle(.white)
          }.buttonStyle(.plain).disabled(
            model.busy || model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }.padding(15).background(Palette.card, in: RoundedRectangle(cornerRadius: 15)).padding(16)
    }.background(Palette.panel)
  }
  private var activity: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("活动与撤销").font(.title2)
        Spacer()
        Button("完成") { model.showActivity = false }
      }
      Text("每次写入都留下记录。撤销保留之后的独立修改。").foregroundStyle(Palette.muted)
      if model.activities.isEmpty {
        ContentUnavailableView(
          "暂无活动", systemImage: "clock.arrow.circlepath",
          description: Text("应用写入数据或执行操作后，可以在这里查看详情和撤销。"))
      } else {
        List(model.activities) { item in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              VStack(alignment: .leading, spacing: 6) {
                Text(item.action).font(.system(.body, design: .monospaced))
                Text(item.target).font(.caption).foregroundStyle(Palette.muted)
                Text(item.at).font(.caption2).foregroundStyle(Palette.muted)
              }
              Spacer()
              if item.effect == .irreversible {
                Text("不可撤销").foregroundStyle(Palette.amber)
              } else if item.state == "applied"
                || (item.action.hasPrefix("files.") && ["done", "unknown"].contains(item.state))
                || (item.action == "calendar.create" && item.state == "done")
              {
                Button(item.undoOf == nil ? "撤销" : "撤销此操作") { model.undo(item) }
              } else {
                Text(
                  [
                    "done": "已完成", "failed": "失败", "unknown": "结果待核实", "pending": "等待确认",
                    "ready": "待执行", "executing": "执行中", "compensated": "已补偿", "undone": "已撤销",
                  ][item.state] ?? item.state
                ).foregroundStyle(Palette.muted)
              }
            }
            ActivityDetail(model: model, item: item)
          }.accessibilityElement(children: .contain)
        }
      }
    }.padding(24).frame(width: 730, height: 560)
  }
  private var versions: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("版本时间线").font(.title2)
      Text("回滚代码会保留用户数据和存档。").foregroundStyle(Palette.muted)
      List(model.versionList, id: \.self) { version in
        HStack {
          Text(version).font(.system(.body, design: .monospaced))
          Spacer()
          Button("回滚到此版本") { model.rollback(version) }
        }.accessibilityElement(children: .contain)
      }
      Button("完成") { model.showVersions = false }
    }.padding(24).frame(width: 540, height: 430)
  }

}
struct WebPane: NSViewRepresentable {
  let instance: WebInstance
  let canAttach: () -> Bool
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    install(in: view)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { install(in: view) }
  private func install(in view: NSView) {
    guard canAttach(), instance.webView.superview !== view else { return }
    for subview in view.subviews { subview.removeFromSuperview() }
    let web = instance.webView
    web.removeFromSuperview()
    web.frame = view.bounds
    web.autoresizingMask = [.width, .height]
    view.addSubview(web)
  }
}
