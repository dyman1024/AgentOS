import AgentOSCore
import SwiftUI

struct JointUpdatePanel: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var selected: Set<String> = []
  @State private var working = false
  @State private var notice = ""
  var body: some View {
    Form {
      Text("应用联合更新").font(.title2)
      Text("选择已准备好新版本源码的应用。涉及共享 schema 迁移时，必须包含所有已安装消费者。每个应用的契约在独立测试环境中运行，全部通过后由宿主确认并一次提交。").font(
        .caption)
      ForEach(model.apps) { app in
        Toggle(
          app.title + " · " + app.version,
          isOn: Binding(
            get: { selected.contains(app.id) },
            set: { if $0 { selected.insert(app.id) } else { selected.remove(app.id) } }))
      }.disabled(working)
      Button(working ? "正在预检和测试…" : "预检、测试并提交联合更新") {
        working = true
        Task {
          defer { working = false }
          do {
            _ = try await model.runtime.commitGroup(
              selected.sorted(), context: RequestContext(.user))
            notice = "全部应用已更新"
            await model.refresh()
          } catch { notice = error.localizedDescription }
        }
      }.disabled(selected.isEmpty || working)
      Text(notice).font(.caption).textSelection(.enabled)
      Button("完成") { dismiss() }.disabled(working)
    }.formStyle(.grouped).frame(minWidth: 650, minHeight: 520)
  }
}
