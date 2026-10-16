import AgentOSCore
import SwiftUI

struct GroupRecoveryPanel: View {
  let model: AppModel
  var initialRun: String? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var kind = "app"
  @State private var id = ""
  @State private var groups: Value = [:]
  @State private var after = false
  @State private var date = Date()
  @State private var preview: PreparedGroupRecovery?
  @State private var showRecords = false
  @State private var working = false
  @State private var notice = ""
  var body: some View {
    Form {
      Text("按应用或运行恢复").font(.title2)
      Text("只恢复所选来源的共享数据写入，保留其他来源的独立字段。后续修改冲突时整组停止；文件、发送与发布等操作列为排除项。恢复前自动备份。").font(.caption)
      Picker("分组方式", selection: $kind) {
        Text("应用").tag("app")
        Text("运行").tag("run")
      }.pickerStyle(.segmented)
      Picker(kind == "app" ? "应用" : "运行", selection: $id) {
        Text("请选择").tag("")
        ForEach(groups[kind == "app" ? "apps" : "runs"]?.array ?? [], id: \.self) { item in
          Text(
            (item["title"]?.string ?? item["summary"]?.string ?? "") + " · "
              + String((item["id"]?.string ?? "").prefix(8))
          )
          .tag(item["id"]?.string ?? "")
        }
      }
      Toggle("仅恢复指定时间之后的写入", isOn: $after)
      if after { DatePicker("恢复到", selection: $date, in: ...Date()) }
      Button("预览分组恢复") {
        working = true
        Task {
          defer { working = false }
          do {
            var selection: Value = ["kind": .string(kind), "id": .string(id)]
            if after {
              var values = selection.object!
              values["after"] = .string(ISO8601DateFormatter().string(from: date))
              selection = .object(values)
            }
            preview = try await model.kernel.prepareGroupRecovery(
              selection, context: RequestContext(.user))
            notice = ""
          } catch {
            notice = error.localizedDescription
            preview = nil
          }
        }
      }.disabled(id.isEmpty || working)
      if let preview {
        Text(
          "涉及 \(preview.summary["effects"]?.int ?? 0) 次写入、\(preview.summary["records"]?.array?.count ?? 0) 条记录"
        )
        ForEach(preview.summary["conflicts"]?.array ?? [], id: \.self) { item in
          Text(
            "冲突：\(item["collection"]?.string ?? "")/\(item["id"]?.string ?? "") · \(item["fields"]?.array?.compactMap(\.string).joined(separator: "、") ?? "")"
          ).foregroundStyle(.red)
        }
        ForEach(preview.summary["excluded"]?.array ?? [], id: \.self) { item in
          Text("\(item["action"]?.string ?? "")：\(item["reason"]?.string ?? "")").font(.caption)
        }
        Button(showRecords ? "收起记录变更" : "查看记录变更") { showRecords.toggle() }
        if showRecords {
          ForEach(preview.summary["records"]?.array ?? [], id: \.self) { record in
            VStack(alignment: .leading) {
              Text((record["collection"]?.string ?? "") + "/" + (record["id"]?.string ?? "")).font(
                .headline)
              Text("当前：" + ((try? record["before"]?.text()) ?? ""))
              Text(
                record["deletedAfter"] == true
                  ? "恢复后：删除此记录" : "恢复后：" + ((try? record["after"]?.text()) ?? ""))
            }.font(.caption).textSelection(.enabled)
          }
        }
        Button("确认分组恢复") {
          working = true
          Task {
            defer { working = false }
            guard await model.confirm("恢复所选数据写入，保留历史和操作前备份", preview.summary) else { return }
            do {
              _ = try await model.kernel.applyGroupRecovery(
                preview, approved: true, context: RequestContext(.user))
              self.preview = nil
              notice = "分组恢复完成；操作前备份已保存"
              await model.refresh()
            } catch { notice = error.localizedDescription }
          }
        }.disabled(working || preview.summary["canApply"] != true)
      }
      Text(notice).font(.caption).textSelection(.enabled)
      Button("完成") { dismiss() }
    }.formStyle(.grouped).frame(minWidth: 650, minHeight: 520)
      .onChange(of: kind) {
        preview = nil
        if kind == "run", let initialRun { id = initialRun } else { id = "" }
      }
      .onChange(of: id) { preview = nil }
      .onChange(of: after) { preview = nil }
      .onChange(of: date) { preview = nil }
      .task {
        do { groups = try await model.kernel.recoveryGroups(context: RequestContext(.user)) } catch
        { notice = error.localizedDescription }
        if let initialRun {
          kind = "run"
          id = initialRun
        }
      }
  }
}
