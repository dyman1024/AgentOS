import AgentOSCore
import SwiftUI

struct NotificationPanel: View {
  @Bindable var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("通知中心").font(.title2)
        Spacer()
        Button("完成") { model.showNotifications = false }
      }
      if model.notifications.isEmpty {
        ContentUnavailableView("暂无通知", systemImage: "bell")
      } else {
        List(model.notifications, id: \.self) { notification in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(notification["title"]?.string ?? "").fontWeight(.medium)
              Spacer()
              if notification["read"]?.int == 0 {
                Button("标为已读") {
                  Task {
                    try? await model.kernel.markNotificationRead(notification["id"]!.string!)
                    await model.refresh()
                  }
                }
              }
            }
            Text(notification["body"]?.string ?? "").textSelection(.enabled)
            Text(
              (notification["source"]?.string ?? "") + " · " + (notification["at"]?.string ?? "")
            ).font(.caption).foregroundStyle(.secondary)
          }.padding(.vertical, 8)
        }
      }
    }.padding(24).frame(width: 680, height: 480)
  }
}
