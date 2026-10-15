import AgentOSCore
import Foundation

extension RuntimeCoordinator {
  public func pumpAutomations() async {
    guard let definitions = try? await kernel.automations().array else { return }
    for row in definitions {
      guard let id = row["id"]?.string, automationTasks[id] == nil else { continue }
      do {
        guard let job = try await kernel.nextAutomation(id) else { continue }
        automationTasks[id] = Task { [weak self] in
          guard let self else { return }
          defer { self.automationTasks[id] = nil }
          do {
            let context = RequestContext(
              .run(job.runID), runID: job.runID, depth: job.event?["depth"]?.int ?? 0)
            for step in job.definition["steps"]?.array ?? [] {
              try Task.checkCancellation()
              let args = Self.eventArguments(step["args"] ?? [:], event: job.event ?? .null)
              _ = try await self.call(step.requiredString("tool"), args: args, caller: context)
            }
            try await self.kernel.finishAutomation(job)
          } catch {
            try? await self.kernel.finishAutomation(job, error: error.localizedDescription)
          }
        }
      } catch { continue }
    }
  }
  static func eventArguments(_ value: Value, event: Value) -> Value {
    if let path = value["$event"]?.string {
      return path.split(separator: ".").reduce(event) { $0[String($1)] ?? .null }
    }
    if let object = value.object {
      return .object(object.mapValues { eventArguments($0, event: event) })
    }
    if let array = value.array { return .array(array.map { eventArguments($0, event: event) }) }
    return value
  }
}
