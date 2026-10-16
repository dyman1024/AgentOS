import AgentOSCore
import SwiftUI

struct ActivityDetail: View {
  let model: AppModel
  let item: Activity
  @State private var expanded = false
  @State private var detail = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        expanded.toggle()
      } label: {
        Label(
          expanded ? "收起原因、参数与变更" : "查看原因、参数与变更",
          systemImage: expanded ? "chevron.down" : "chevron.right")
      }.buttonStyle(.borderless)
      if expanded {
        Text(detail.isEmpty ? "正在读取详情…" : detail)
          .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }.font(.caption).onChange(of: expanded) { _, open in
      if open {
        Task {
          do {
            let value = try await model.kernel.activityDetails(
              item.id, context: RequestContext(.user))
            let object = try JSONSerialization.jsonObject(with: value.encoded())
            detail = String(
              decoding: try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
          } catch { detail = error.localizedDescription }
        }
      }
    }
  }
}
