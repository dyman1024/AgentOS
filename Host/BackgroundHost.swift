import AgentOSCore
import AppKit
import ServiceManagement

@MainActor enum BackgroundHost {
  static let service = SMAppService.agent(plistName: "dev.agentos.background.plist")
  static func enable() throws { try service.register() }
  static func disable() async throws { try await service.unregister() }
  static var enabled: Bool { service.status == .enabled }
  static func requestForegroundLease(root: URL) throws -> HostLease {
    do { return try HostLease(root: root) } catch {
      let role = try? String(
        contentsOf: root.appendingPathComponent("system/host-role"), encoding: .utf8)
      guard role == "background",
        let executable = Bundle.main.resourceURL?.appendingPathComponent("engine/aos"),
        FileManager.default.isExecutableFile(atPath: executable.path)
      else { throw error }
      let request = Process()
      request.executableURL = executable
      request.arguments = ["system", "release-background"]
      request.environment = ["PATH": "/usr/bin:/bin", "AGENTOS_DATA_ROOT": root.path]
      request.standardOutput = FileHandle.nullDevice
      request.standardError = FileHandle.nullDevice
      try request.run()
      let deadline = Date().addingTimeInterval(8)
      while request.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
      if request.isRunning {
        request.terminate()
        throw HostError("conflict", "后台正在完成任务，请稍后重试")
      }
      guard request.terminationStatus == 0 else { throw HostError("conflict", "后台正在完成任务，请稍后重试") }
      while Date() < deadline {
        if let lease = try? HostLease(root: root) { return lease }
        Thread.sleep(forTimeInterval: 0.05)
      }
      throw HostError("conflict", "后台尚未释放数据目录，请重试")
    }
  }
  static func run() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
      var model: AppModel?
      while !Task.isCancelled {
        if model == nil { model = try? AppModel(background: true) }
        if let current = model, current.shutdownRequested {
          await current.shutdownBackground()
          model = nil
          try? await Task.sleep(for: .seconds(10))
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
    application.run()
  }
}

@main enum AgentOSLauncher {
  @MainActor static func main() {
    if CommandLine.arguments.contains("--background") {
      BackgroundHost.run()
    } else {
      AgentOSApplication.main()
    }
  }
}
