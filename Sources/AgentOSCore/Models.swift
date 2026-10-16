import Foundation

public enum Principal: Codable, Sendable, Hashable {
  case user
  case run(String)
  case core(String)
  case ui(String)
  case service(String)
  public var id: String {
    switch self {
    case .user: "user"
    case .run(let id): "run:\(id)"
    case .core(let id): "app:\(id)/core"
    case .ui(let id): "app:\(id)/ui"
    case .service(let id): "service:\(id)"
    }
  }
  public var appID: String? {
    switch self {
    case .core(let id), .ui(let id): id
    default: nil
    }
  }
}
public struct Labels: Codable, Sendable, Equatable {
  public var taint: Set<String>
  public var isPrivate: Bool
  public var isUntrusted: Bool { !taint.isEmpty }
  public init(taint: Set<String> = [], isPrivate: Bool = false) {
    self.taint = taint
    self.isPrivate = isPrivate
  }
  public func union(_ other: Labels) -> Labels {
    Labels(taint: taint.union(other.taint), isPrivate: isPrivate || other.isPrivate)
  }
  // Sort sets before encoding so audit hashes remain stable across launches.
  enum CodingKeys: String, CodingKey { case taint, isPrivate }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(taint.sorted(), forKey: .taint)
    try c.encode(isPrivate, forKey: .isPrivate)
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    taint = Set(try c.decode([String].self, forKey: .taint))
    isPrivate = try c.decode(Bool.self, forKey: .isPrivate)
  }
}
public struct RequestContext: Codable, Sendable {
  public let principal: Principal
  public let runID: String?
  public let instanceID: String?
  public let depth: Int
  public init(
    _ principal: Principal, runID: String? = nil, instanceID: String? = nil, depth: Int = 0
  ) {
    self.principal = principal
    self.runID = runID
    self.instanceID = instanceID
    self.depth = depth
  }
}
public enum PermissionMode: String, Codable, CaseIterable, Sendable { case careful, auto, trust }
public enum EffectClass: String, Codable, Sendable {
  case read, write, fetch, external, irreversible
}
public enum PolicyDecision: Sendable, Equatable {
  case allow
  case deny(String)
  case confirm(String)
}
public enum ExitPolicy {
  public static func evaluate(
    mode: PermissionMode, effect: EffectClass, labels: Labels, knownURL: Bool = false,
    persistentAccess: Bool = false
  ) -> PolicyDecision {
    if mode == .trust { return .allow }
    if persistentAccess { return .confirm("这项授权会影响未来的操作") }
    if effect == .irreversible && (mode == .careful || labels.isUntrusted) {
      return .confirm("不可撤销的操作需要确认来源与参数")
    }
    if effect == .fetch && labels.isUntrusted && labels.isPrivate && !knownURL {
      return .confirm("外部内容与私人数据可能被发送到新的地址")
    }
    return .allow
  }
}
public struct Record: Codable, Sendable, Equatable {
  public let collection: String
  public let id: String
  public let rev: Int
  public let fields: [String: Value]
  public let labels: Labels
  public let deleted: Bool
  public var createdBy: String?
  public var createdAt: String?
  public var updatedBy: String?
  public var updatedAt: String?
  public var value: Value {
    var result = fields
    result["_id"] = .string(id)
    result["_rev"] = .number(Double(rev))
    result["_labels"] = try? Value.from(labels)
    result["_createdBy"] = createdBy.map(Value.string)
    result["_createdAt"] = createdAt.map(Value.string)
    result["_updatedBy"] = updatedBy.map(Value.string)
    result["_updatedAt"] = updatedAt.map(Value.string)
    return .object(result)
  }
}
public struct Mutation: Sendable {
  public let collection: String
  public let id: String?
  public let fields: [String: Value]
  public let expectedRevision: Int?
  public let delete: Bool
  public init(
    _ collection: String, id: String? = nil, fields: [String: Value] = [:],
    expectedRevision: Int? = nil, delete: Bool = false
  ) {
    self.collection = collection
    self.id = id
    self.fields = fields
    self.expectedRevision = expectedRevision
    self.delete = delete
  }
}
public struct MutationResult: Codable, Sendable {
  public let record: Record
  public let effectID: String
}
public struct DomainEvent: Codable, Sendable, Equatable {
  public let id: String
  public let type: String
  public let source: String
  public let subject: String
  public let time: String
  public let labels: Labels
  public let depth: Int
  public let runID: String?
  public let data: Value
  public var specversion: String = "1.0"
}
public struct Activity: Codable, Sendable, Identifiable {
  public let id: String
  public let runID: String?
  public let action: String
  public let target: String
  public let state: String
  public let effect: EffectClass
  public let at: String
  public let undoOf: String?
}
public func matchesPattern(_ pattern: String, _ value: String) -> Bool {
  if pattern == "*" { return true }
  if pattern.hasSuffix(".*") { return value.hasPrefix(String(pattern.dropLast())) }
  return pattern == value
}
