import AgentOSCore
import AppKit
import SwiftUI

/// A separate host-owned panel remains above generated content and Settings sheets.
@MainActor final class ApprovalPresenter: NSObject, NSWindowDelegate {
  weak var model: AppModel?
  private var panel: NSPanel?
  init(model: AppModel) { self.model = model }
  func show() {
    guard let model else { return }
    if panel == nil {
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 440), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      panel.title = "AgentOS · 系统确认"
      panel.level = .modalPanel
      panel.isFloatingPanel = true
      panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false
      panel.delegate = self
      panel.contentView = NSHostingView(rootView: ApprovalContent(model: model))
      panel.center()
      self.panel = panel
    }
    panel?.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
  func close() {
    panel?.delegate = nil
    panel?.close()
    panel = nil
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    model?.approve(false)
    return false
  }
}

private struct ApprovalContent: View {
  @Bindable var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if let request = model.approvals.first {
        Label(request.title, systemImage: "hand.raised").font(.title2).foregroundStyle(
          Palette.amber)
        ScrollView {
          Text((try? request.arguments.text()) ?? "").font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        Text("由 AgentOS 宿主请求确认。批准仅适用于展示的参数。").font(.caption).foregroundStyle(Palette.muted)
        HStack {
          Button("拒绝") { model.approve(false) }.keyboardShortcut(.cancelAction)
          Spacer()
          Button("只这一次") { model.approve(true) }.buttonStyle(.borderedProminent)
        }
      }
    }.padding(28).frame(width: 640, height: 440).background(Palette.panel).foregroundStyle(
      Palette.paper
    ).tint(Palette.ember).preferredColorScheme(.dark)
  }
}
