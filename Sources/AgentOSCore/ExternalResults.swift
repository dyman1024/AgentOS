import Foundation

extension Kernel {
  /// Trusted host adapters use this for compensation. The original owning principal is checked again.
  public func externalResult(_ id: String, action: String, context: RequestContext) throws -> Value
  {
    try require(context, capability: "service", scope: action)
    guard
      let row = try db.query(
        "SELECT * FROM sink_operations WHERE id=? AND action=? AND state='done'",
        [.string(id), .string(action)]
      ).first, let raw = row["result"]?.string
    else { throw HostError("conflict", "No completed operation to compensate") }
    try requireEffectOwner(row["context"]!.string!, context: context)
    return try Value.parse(raw)
  }
  func requireEffectOwner(_ serialized: String, context: RequestContext) throws {
    let bound = try Value.parse(serialized)["request"]!.decode(RequestContext.self)
    var owner = bound.principal
    if case .run(let id) = owner,
      let raw = try db.query("SELECT initiator FROM runs WHERE id=?", [.string(id)]).first?[
        "initiator"]?.string
    {
      owner = try Value.parse(raw).decode(Principal.self)
    }
    let requester = try initiator(of: context)
    guard requester == .user || requester == .service("cli") || requester == owner else {
      throw HostError("denied", "Cannot compensate another application's operation")
    }
  }
}
