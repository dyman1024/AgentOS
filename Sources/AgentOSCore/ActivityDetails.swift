import Foundation

extension Kernel {
  public func activityDetails(_ id: String, context: RequestContext) throws -> Value {
    try require(context, capability: "activity.read", scope: "*")
    guard let effect = try db.query("SELECT * FROM effects WHERE id=?", [.string(id)]).first else {
      throw HostError("not_found", "Activity no longer exists")
    }
    var details = effect
    var labels = Labels(isPrivate: true)
    if let run = effect["run_id"]?.string {
      details["run"] = try db.query(
        "SELECT summary,role,status,budget,spent FROM runs WHERE id=?", [.string(run)]
      ).first.map(Value.object)
    }
    if let sink = try db.query(
      "SELECT args,decision,result,context FROM sink_operations WHERE id=?", [.string(id)]
    ).first {
      details["arguments"] = try sink["args"]?.string.map(Value.parse)
      details["decision"] = sink["decision"]
      details["result"] = try sink["result"]?.string.map(Value.parse)
      if let serialized = sink["context"]?.string {
        details["labels"] = try Value.parse(serialized)["labels"]
        if let raw = details["labels"] { labels = labels.union(try raw.decode(Labels.self)) }
      }
    }
    if let entry = try db.query(
      "SELECT before,after,changed FROM history WHERE effect_id=?", [.string(id)]
    ).first {
      for key in ["before", "after"] {
        if let raw = entry[key]?.string {
          labels = labels.union(try Value.parse(raw).decode(Record.self).labels)
        }
      }
      details["before"] = try entry["before"]?.string.map(Value.parse) ?? .null
      details["after"] = try entry["after"]?.string.map(Value.parse)
      details["changedFields"] = try entry["changed"]?.string.map(Value.parse)
    }
    try propagate(labels, to: context)
    try audit("activity.inspected", context: context, detail: ["id": .string(id)])
    return .object(details)
  }
}
