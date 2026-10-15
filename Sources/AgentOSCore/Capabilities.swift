import Foundation

public struct CapabilityRequest: Sendable, Equatable {
  public let capability: String
  public let scope: String
  public init(_ capability: String, _ scope: String) {
    self.capability = capability
    self.scope = scope
  }
}
extension AppInterface {
  public func capabilities(manifest: Value) throws -> [CapabilityRequest] {
    var result = data.flatMap { collection, access in
      [CapabilityRequest("data.read", collection)]
        + (access == "rw" ? [CapabilityRequest("data.write", collection)] : [])
    }
    result += calls.map { CapabilityRequest("call", $0) }
    result += subscriptions.map { CapabilityRequest("subscribe", $0) }
    for (field, capability) in [("network", "net"), ("services", "service"), ("files", "files")] {
      guard let values = (manifest["permissions"]?[field] ?? []).array, values.count <= 100 else {
        throw HostError("invalid_package", "Permissions must be bounded string arrays")
      }
      for value in values {
        guard let scope = value.string, !scope.isEmpty, scope.count <= 255 else {
          throw HostError("invalid_package", "Invalid permission scope")
        }
        if field == "network" {
          guard
            scope.range(of: "^(\\*\\.)?[a-z0-9][a-z0-9.-]*[a-z0-9]$", options: .regularExpression)
              != nil, !scope.contains("..")
          else {
            throw HostError(
              "invalid_package", "Use a domain, not a URL or unrestricted network wildcard")
          }
        }
        if field == "files" {
          guard UUID(uuidString: scope) != nil else {
            throw HostError(
              "invalid_package", "Files permissions reference a host-authorized folder ID")
          }
        }
        result.append(CapabilityRequest(capability, scope))
      }
    }
    for event in raw["emits"]?.array ?? [] {
      guard let name = event.string, name.hasPrefix(namespace + "."), !name.contains("*") else {
        throw HostError("invalid_interface", "Custom events must use the application's namespace")
      }
      result.append(CapabilityRequest("emit", name))
    }
    return result
  }
}
extension Kernel {
  public func emit(_ type: String, data: Value, context: RequestContext) throws -> Value {
    try require(context, capability: "emit", scope: type)
    let reserved =
      try db.query("SELECT type FROM schemas").compactMap { $0["type"]?.string } + [
        "app", "mail", "system",
      ]
    guard !reserved.contains(where: { type.hasPrefix($0 + ".") }),
      let id = context.principal.appID, let item = try? app(id),
      type.hasPrefix(item.namespace + "."), try data.encoded().count <= 4096
    else { throw HostError("denied", "Invalid custom event") }
    let cutoff = Date().timeIntervalSince1970 - 1
    let recent =
      try db.query(
        "SELECT COUNT(*) AS n FROM events WHERE created>? AND type=?",
        [.number(cutoff), .string(type)]
      ).first?["n"]?.int ?? 0
    guard recent < 20 else { throw HostError("rate_limited", "Event rate exceeded") }
    let event = DomainEvent(
      id: UUID().uuidString.lowercased(), type: type, source: "agentos://app/" + id,
      subject: item.namespace, time: Self.now(), labels: try labels(for: context),
      depth: context.depth, runID: context.runID, data: data)
    try db.transaction {
      try appendEvent(event)
      try audit(
        "event.emitted", context: context, detail: ["type": .string(type), "id": .string(event.id)])
    }
    return ["id": .string(event.id)]
  }
  public func authorizeNetwork(_ host: String, context: RequestContext) throws {
    try validateContext(context)
    let principal = try initiator(of: context)
    switch principal {
    case .user, .service: return
    case .ui: throw HostError("denied", "UI cannot call network services")
    case .core:
      let rows = try db.query(
        "SELECT scope FROM grants WHERE holder=? AND capability='net' AND revoked=0 AND (expires IS NULL OR expires>?)",
        [.string(principal.id), .number(Date().timeIntervalSince1970)])
      guard
        rows.contains(where: { row in
          guard let scope = row["scope"]?.string else { return false }
          return scope == host
            || (scope.hasPrefix("*.") && host.hasSuffix(String(scope.dropFirst()))
              && host != String(scope.dropFirst(2)))
        })
      else { throw HostError("denied", "Domain is not authorized: \(host)") }
    case .run: throw HostError("denied", "Unresolved network caller")
    }
  }
}
