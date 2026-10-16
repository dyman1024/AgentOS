import AgentOSCore
import SwiftUI

struct DataRecoveryPanel: View {
  let model: AppModel
  var body: some View {
    TabView {
      CollectionRecoveryPanel(model: model).tabItem { Text("集合恢复") }
      GroupRecoveryPanel(model: model).tabItem { Text("分组恢复") }
      JointUpdatePanel(model: model).tabItem { Text("联合更新") }
    }.frame(width: 720, height: 620)
  }
}

struct CollectionRecoveryPanel: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var collections: [String] = []
  @State private var backups: [Value] = []
  @State private var collection = "notes"
  @State private var backup = ""
  @State private var date = Date()
  @State private var timepoint = false
  @State private var working = false
  @State private var notice = ""
  var body: some View {
    Form {
      Text("备份与集合恢复").font(.title2)
      Text("恢复会生成新的历史版本。预览后如果数据发生变化，操作会停止；每次恢复前也会保存完整备份。应用代码需要单独回滚。").font(.caption)
      Button("立即备份全部集合") {
        Task {
          do {
            let id = try await model.kernel.backupData()
            notice = "已备份：" + id
            await load()
          } catch { notice = error.localizedDescription }
        }
      }.disabled(working)
      Picker("恢复集合", selection: $collection) {
        ForEach(collections, id: \.self) { Text($0).tag($0) }
      }
      Toggle("按历史时间恢复", isOn: $timepoint)
      if timepoint {
        DatePicker("恢复到", selection: $date, in: ...Date())
        Text("使用当前 schema 验证历史记录；跨 schema 变更请选完整备份。时间精度为秒。").font(.caption)
      } else {
        Picker("备份", selection: $backup) {
          Text("选择备份").tag("")
          ForEach(backups, id: \.self) { item in
            Text((item["at"]?.string ?? "") + " · " + String((item["id"]?.string ?? "").prefix(8)))
              .tag(item["id"]?.string ?? "")
          }
        }
      }
      Button("预检并确认恢复") {
        working = true
        Task {
          defer { working = false }
          do {
            let change =
              timepoint
              ? try await model.kernel.prepareTimepointRestore(
                collection, at: ISO8601DateFormatter().string(from: date),
                context: RequestContext(.user))
              : try await model.kernel.prepareCollectionRestore(
                collection, backupID: backup, context: RequestContext(.user))
            guard await model.confirm("恢复整个集合，将替换当前内容并保留历史", change.summary) else { return }
            _ = try await model.kernel.applyDataChange(
              change, approved: true, context: RequestContext(.user))
            notice = "集合已恢复；已保存操作前备份"
            await model.refresh()
            await load()
          } catch { notice = error.localizedDescription }
        }
      }.disabled(working || collection.isEmpty || (!timepoint && backup.isEmpty))
      Text(notice).font(.caption).textSelection(.enabled)
      Button("完成") { dismiss() }
    }.formStyle(.grouped).frame(width: 650, height: 480).task { await load() }
  }
  private func load() async {
    do {
      collections =
        try await model.kernel.schemas().array?.compactMap { $0["collection"]?.string } ?? []
      backups = try await model.kernel.dataBackups().array ?? []
    } catch { notice = error.localizedDescription }
  }
}
