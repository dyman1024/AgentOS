import AgentOSCore
import AppKit
import SwiftUI

struct AgentOSApplication: App {
  @NSApplicationDelegateAdaptor(HostLifecycle.self) private var lifecycle
  @State private var model: AppModel?
  @State private var startupError: String?
  init() {
    do {
      _model = State(initialValue: try AppModel())
      _startupError = State(initialValue: nil)
    } catch {
      _model = State(initialValue: nil)
      _startupError = State(initialValue: error.localizedDescription)
    }
  }
  var body: some Scene {
    WindowGroup("AgentOS") {
      Group {
        if let model {
          ShellView(model: model)
        } else {
          VStack(alignment: .leading, spacing: 20) {
            Text("AgentOS 未能打开数据").font(.title)
            Text(startupError ?? "未知启动错误").textSelection(.enabled)
            Text("原数据会保留。确认其他宿主已退出或恢复数据目录后，可以重试。")
            Button("重试") {
              do {
                model = try AppModel()
                startupError = nil
              } catch { startupError = error.localizedDescription }
            }
          }.padding(40)
        }
      }.frame(minWidth: 1000, minHeight: 680).preferredColorScheme(.dark)
    }
    .defaultSize(width: 1320, height: 840).windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("启动台") { model?.home() }.keyboardShortcut("n")
        Button("重新加载应用") { model?.reload() }.keyboardShortcut("r")
      }
      CommandGroup(replacing: .appSettings) {
        Button("设置…") { model?.showSettings = true }.keyboardShortcut(",")
      }
    }
  }
}
