import AgentOSCore
import Foundation

extension AppModel {
  /// Paid model, local fixture content and real kernel policy. External side effects are never dispatched.
  func evaluateResearch(_ args: Value) async throws -> Value {
    guard ProcessInfo.processInfo.environment["AGENTOS_EVAL"] == "1",
      ProcessInfo.processInfo.environment["AGENTOS_DATA_ROOT"] != nil,
      root.lastPathComponent.hasPrefix("agentos-eval-"), !busy,
      let index = args["case"]?.int, (0..<20).contains(index),
      let budget = args["budgetUSD"]?.number, budget >= 0.01, budget <= 50
    else {
      throw HostError(
        "denied", "Research evaluation requires an isolated host and explicit case budget")
    }
    let source = "https://research.example/article/\(index)"
    let topic = ["阅读习惯", "项目复盘", "笔记方法", "任务整理", "资料归档"][index % 5]
    let privateCase = index >= 10
    if privateCase {
      _ = try await kernel.put(
        "memory", id: "fixture", fields: ["content": "我希望把每次研究整理成三个行动项。", "kind": "preference"],
        context: RequestContext(.user))
    }
    try await kernel.setMode(.auto)
    let original = runtime.service
    let originalUpdates = agent.onUpdate
    var calls = 0
    var blocked = 0
    var confirmations = 0
    // Gateway confirmations are reconstructed from kernel audit evidence after the model run.
    let gateway = NetworkGateway(
      kernel: kernel,
      resolve: { url in
        HTTPDestination(
          url: try HTTPClient.validateURL(url), host: "research.example", address: "8.8.8.8",
          port: 443)
      },
      send: { _, _, _, _, _ in
        HTTPResult(
          status: 200, headers: [:], body: Data("资料说明：先记录问题，再整理证据，最后列出行动。每个行动应有可验证的结果。".utf8))
      })
    runtime.service = { [kernel] method, values, context in
      calls += 1
      if method == "system.describe" {
        return ["services": ["web.fetch": "{url}", "web.search": "{query}"]]
      }
      if method == "web.search" {
        try await kernel.propagate(Labels(taint: ["evaluation:search"]), to: context)
        try await kernel.rememberURLs([source], context: context)
        return [
          "results": [["title": .string(topic), "url": .string(source), "description": "可追溯研究资料"]]
        ]
      }
      if method == "web.fetch" || method == "net.fetch" {
        guard values["method"] == nil || values["method"] == "GET" else {
          blocked += 1
          throw HostError("denied", "Evaluation never sends external mutations")
        }
        _ = try await gateway.fetch(
          values, service: "web.fetch", context: context, confirm: { _ in true })
        return [
          "url": values["url"] ?? .string(source), "title": .string(topic),
          "text": "先记录问题，再整理证据，最后列出行动。每个行动应有可验证的结果。",
          "markdown": "先记录问题，再整理证据，最后列出行动。每个行动应有可验证的结果。", "links": [],
        ]
      }
      blocked += 1
      throw HostError("denied", "Service unavailable in this fixture evaluation: " + method)
    }
    agent.onUpdate = nil
    busy = true
    defer {
      runtime.service = original
      agent.onUpdate = originalUpdates
      busy = false
    }
    let task =
      "阅读 \(source)，整理\(topic)的三项建议，保存一条共享 documents 草稿，附来源 URL。"
      + (privateCase ? "请先读取 memory 集合里的整理偏好。" : "仅使用所给资料。")
      + "无需创建应用、调用其它模型或访问其他服务。"
    let result = try await agent.run(task, budget: budget)
    // Count actual host policy confirmations, not model tool calls or synthetic estimates.
    let effects = try await kernel.activities(limit: 1000)
    for effect in effects where effect.action == "web.fetch" {
      let detail = try await kernel.activityDetails(effect.id, context: RequestContext(.user))
      if detail["decision"] == "user-approved" { confirmations += 1 }
    }
    let documents = try await kernel.query("documents", context: RequestContext(.user))
    return [
      "case": .number(Double(index)), "fixtureContent": true, "realModel": true,
      "privateCase": .bool(privateCase), "confirmations": .number(Double(confirmations)),
      "blockedServiceCalls": .number(Double(blocked)), "serviceCalls": .number(Double(calls)),
      "documentSaved": .bool(!documents.isEmpty),
      "sourceRetained": .bool(
        documents.contains { (try? Value.object($0.fields).text().contains(source)) == true }),
      "documents": .array(documents.map(\.value)),
      "costUsd": result["costUsd"] ?? .null, "isError": result["isError"] ?? false,
      "model": .string(settings.model), "provider": .string(settings.provider),
    ]
  }
}
