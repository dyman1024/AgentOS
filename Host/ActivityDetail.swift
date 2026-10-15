import AgentOSCore
import SwiftUI

struct ActivityDetail: View {
  let model: AppModel
  let item: Activity
  @State private var expanded = false
  @State private var detail = ""
  var body: some View {
    DisclosureGroup("原因、参数与变更", isExpanded: $expanded) {
      Text(detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
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
