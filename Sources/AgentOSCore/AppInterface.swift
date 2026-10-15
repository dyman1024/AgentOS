import Foundation

public struct ToolDefinition: Sendable, Equatable {
  public let name: String
  public let title: String
  public let description: String
  public let input: Value
  public let output: Value
  public let annotations: Value
  public let examples: [Value]
  public var interactive: Bool { annotations["interactive"]?.bool == true }
}
public struct AppInterface: Sendable, Equatable {
  public let raw: Value
  public let namespace: String
  public let version: String
  public let summary: String
  public let tools: [ToolDefinition]
  public let data: [String: String]
  public let calls: [String]
  public let subscriptions: [String]
  public init(_ raw: Value) throws {
    guard raw["schema"]?.string == "agentos.interface/1", let namespace = raw["id"]?.string,
      Kernel.validName(namespace),
      !["data", "apps", "events", "system", "automation", "vm", "ext"].contains(namespace),
      let version = raw["version"]?.string, Version(version) != nil,
      let declarations = raw["tools"]?.array
    else { throw HostError("invalid_interface", "Invalid interface header") }
    self.raw = raw
    self.namespace = namespace
    self.version = version
    summary = raw["summary"]?.string ?? ""
    var tools: [ToolDefinition] = []
    var names: Set<String> = []
    for item in declarations {
      guard let name = item["name"]?.string,
        name.range(of: "^[a-zA-Z][a-zA-Z0-9_]{0,63}$", options: .regularExpression) != nil,
        names.insert(name).inserted, let input = item["input"], let output = item["output"]
      else { throw HostError("invalid_interface", "Missing or duplicate tool definition") }
      try Schema.lint(input)
      try Schema.lint(output)
      let description = item["description"]?.string ?? ""
      let suspicious = [
        "ignore previous", "ignore all previous", "system prompt", "忽略之前", "忽略以上", "系统提示词",
      ]
      guard !suspicious.contains(where: { description.lowercased().contains($0) }) else {
        throw HostError("invalid_interface", "Tool description contains instruction-like text")
      }
      let examples = item["examples"]?.array ?? []
      guard !examples.isEmpty else {
        throw HostError("invalid_interface", "Every tool needs an input example")
      }
      tools.append(
        ToolDefinition(
          name: name, title: item["title"]?.string ?? name, description: description, input: input,
          output: output, annotations: item["annotations"] ?? [:], examples: examples))
    }
    self.tools = tools
    for key in ["data", "calls", "subscribes"] {
      guard raw[key] == nil || raw[key]?.array != nil else {
        throw HostError("invalid_interface", "\(key) must be an array")
      }
    }
    var data: [String: String] = [:]
    for item in raw["data"]?.array ?? [] {
      guard let collection = item["collection"]?.string, Kernel.validName(collection),
        let access = item["access"]?.string, ["r", "rw"].contains(access), data[collection] == nil
      else { throw HostError("invalid_interface", "Invalid data capability") }
      data[collection] = access
    }
    self.data = data
    let callValues = raw["calls"]?.array ?? []
    let subscriptionValues = raw["subscribes"]?.array ?? []
    guard
      callValues.allSatisfy({
        $0.string?.range(
          of: "^[a-z][a-z0-9_-]*\\.(\\*|[A-Za-z][A-Za-z0-9_.-]*)$", options: .regularExpression)
          != nil
      }),
      subscriptionValues.allSatisfy({
        $0["pattern"]?.string?.range(
          of: "^[a-z][A-Za-z0-9_.-]*(\\.\\*)?$", options: .regularExpression) != nil
      })
    else { throw HostError("invalid_interface", "Malformed call or subscription capability") }
    calls = callValues.compactMap(\.string)
    subscriptions = subscriptionValues.compactMap { $0["pattern"]?.string }
  }
  public func breakingChanges(from old: AppInterface) -> [String] {
    var changes: [String] = []
    for previous in old.tools {
      guard let next = tools.first(where: { $0.name == previous.name }) else {
        changes.append("删除工具 \(previous.name)")
        continue
      }
      let oldRequired = Set(previous.input["required"]?.array?.compactMap(\.string) ?? [])
      let newRequired = Set(next.input["required"]?.array?.compactMap(\.string) ?? [])
      if !newRequired.isSubset(of: oldRequired) { changes.append("\(next.name) 新增必填参数") }
      if Self.shapeChanged(previous.input, next.input, input: true) {
        changes.append("\(next.name) 输入不兼容")
      }
      if Self.shapeChanged(previous.output, next.output, input: false) {
        changes.append("\(next.name) 输出不兼容")
      }
    }
    return changes
  }
  private static func shapeChanged(_ old: Value, _ new: Value, input: Bool) -> Bool {
    if old["type"] != new["type"] || old["$ref"] != new["$ref"] { return true }
    if let a = old["enum"]?.array, let b = new["enum"]?.array {
      if input ? !Set(a).isSubset(of: Set(b)) : !Set(b).isSubset(of: Set(a)) { return true }
    } else if input && old["enum"] == nil && new["enum"] != nil {
      return true
    } else if !input && old["enum"] != nil && new["enum"] == nil {
      return true
    }
    if input && old["items"] == nil && new["items"] != nil { return true }
    if !input && old["items"] != nil && new["items"] == nil { return true }
    if let oldItems = old["items"], let newItems = new["items"],
      shapeChanged(oldItems, newItems, input: input)
    {
      return true
    }
    for (key, schema) in old["properties"]?.object ?? [:] {
      guard let other = new["properties"]?[key] else { return true }
      if shapeChanged(schema, other, input: input) { return true }
    }
    let a = Set(old["required"]?.array?.compactMap(\.string) ?? [])
    let b = Set(new["required"]?.array?.compactMap(\.string) ?? [])
    if input ? !b.isSubset(of: a) : !a.isSubset(of: b) { return true }
    if input {
      if let x = new["minimum"]?.number, x > (old["minimum"]?.number ?? -.infinity) { return true }
      if let x = new["maximum"]?.number, x < (old["maximum"]?.number ?? .infinity) { return true }
      if let x = new["maxLength"]?.number, x < (old["maxLength"]?.number ?? .infinity) {
        return true
      }
      if let x = new["minLength"]?.number, x > (old["minLength"]?.number ?? 0) { return true }
      if old["additionalProperties"] != false && new["additionalProperties"] == false {
        return true
      }
    } else {
      if let x = old["minimum"]?.number, (new["minimum"]?.number ?? -.infinity) < x { return true }
      if let x = old["maximum"]?.number, (new["maximum"]?.number ?? .infinity) > x { return true }
      if let x = old["maxLength"]?.number, (new["maxLength"]?.number ?? .infinity) > x {
        return true
      }
    }
    return false
  }
  public func mcpTools() -> Value {
    .array(
      tools.map {
        [
          "name": .string(namespace + "." + $0.name), "description": .string($0.description),
          "inputSchema": $0.input, "outputSchema": $0.output,
        ]
      })
  }
}
public struct Version: Sendable, Comparable {
  public let major: Int, minor: Int, patch: Int, build: Int
  public init?(_ value: String) {
    guard
      value.range(
        of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(\\+(0|[1-9][0-9]*))?$",
        options: .regularExpression) != nil
    else { return nil }
    let parts = value.split(separator: "+", omittingEmptySubsequences: false)
    guard parts.count <= 2 else { return nil }
    let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).compactMap {
      Int($0)
    }
    guard numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }),
      parts.count == 1 || Int(parts[1]) != nil
    else { return nil }
    major = numbers[0]
    minor = numbers[1]
    patch = numbers[2]
    build = parts.count == 2 ? Int(parts[1])! : 0
  }
  public static func < (a: Version, b: Version) -> Bool {
    (a.major, a.minor, a.patch, a.build) < (b.major, b.minor, b.patch, b.build)
  }
}
