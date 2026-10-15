import AgentOSCore
import Foundation

extension AppModel {
  /// Available only on the authenticated user CLI of an explicitly isolated evaluation launch.
  func evaluate(_ args: Value) async throws -> Value {
    guard ProcessInfo.processInfo.environment["AGENTOS_EVAL"] == "1",
      ProcessInfo.processInfo.environment["AGENTOS_DATA_ROOT"] != nil,
      root.lastPathComponent.hasPrefix("agentos-eval-"), !busy
    else { throw HostError("denied", "Evaluation requires an isolated evaluation host") }
    let task = try args.requiredString("task")
    let kind = try args.requiredString("kind")
    guard ["notes", "tasks", "bookmarks", "expenses"].contains(kind) else {
      throw HostError("invalid_args", "Unknown generation acceptance suite")
    }
    let budget = args["budgetUSD"]?.number ?? 0
    guard budget >= 0.01, budget <= 50 else {
      throw HostError("invalid_args", "Specify an evaluation run budget of $0.01–50")
    }
    let app = try await kernel.createApp(
      title: "Generation evaluation", namespace: "evaluation", context: RequestContext(.user))
    busy = true
    let previous = agent.onUpdate
    let previousCreated = agent.onAppCreated
    var outcomes: [Bool] = []
    agent.onAppCreated = nil
    agent.onUpdate = { _, event in
      if event["name"] == "apps.commit" {
        if event["kind"] == "host_error" { outcomes.append(false) }
        if event["kind"] == "host_result" {
          outcomes.append(true)
        }
      }
    }
    defer {
      agent.onUpdate = previous
      agent.onAppCreated = previousCreated
      busy = false
    }
    let result = try await agent.run(task, role: "builder", app: app.id, budget: budget)
    let installed = try await kernel.app(app.id)
    let acceptance =
      installed.version != "draft"
      ? await generationAcceptance(installed, kind: kind) : ["coverage": 0, "tasks": []]
    return [
      "app": .string(app.id), "activated": .bool(installed.version != "draft"),
      "commitAttempts": .number(Double(outcomes.count)),
      "firstCommitPassed": .bool(outcomes.first == true),
      "interfaceCoverage": acceptance["coverage"]!,
      "acceptance": acceptance,
      "costUsd": result["costUsd"] ?? .null,
      "model": .string(settings.model), "provider": .string(settings.provider),
      "isError": result["isError"] ?? false,
    ]
  }
}
