import Foundation

public enum Schema {
  private static let keys: Set<String> = [
    "type", "properties", "required", "enum", "items", "default", "minimum", "maximum", "maxLength",
    "format", "$ref", "description", "title", "additionalProperties",
  ]
  public static func lint(_ schema: Value, depth: Int = 0) throws {
    guard depth < 24, let object = schema.object else {
      throw HostError("invalid_schema", "Schema must be a bounded object")
    }
    guard Set(object.keys).isSubset(of: keys) else {
      throw HostError("invalid_schema", "Unsupported schema keyword")
    }
    if let raw = schema["type"] {
      guard let type = raw.string,
        ["object", "array", "string", "number", "integer", "boolean", "null"].contains(type)
      else { throw HostError("invalid_schema", "Unknown or malformed type") }
    }
    if let options = schema["enum"] {
      guard let values = options.array, !values.isEmpty, Set(values).count == values.count else {
        throw HostError("invalid_schema", "enum must be a nonempty array of distinct values")
      }
    }
    for key in ["minimum", "maximum"] {
      if let value = schema[key] {
        guard value.number?.isFinite == true else {
          throw HostError("invalid_schema", "\(key) must be a finite number")
        }
      }
    }
    if let minimum = schema["minimum"]?.number, let maximum = schema["maximum"]?.number,
      maximum < minimum
    {
      throw HostError("invalid_schema", "Contradictory bounds")
    }
    if let length = schema["maxLength"] {
      guard let value = length.int, value >= 0 else {
        throw HostError("invalid_schema", "maxLength must be a nonnegative integer")
      }
    }
    if let value = schema["additionalProperties"], value.bool == nil {
      throw HostError("invalid_schema", "additionalProperties must be boolean")
    }
    if let value = schema["format"], value.string == nil {
      throw HostError("invalid_schema", "format must be a string")
    }
    for key in ["description", "title"] {
      if let value = schema[key], value.string == nil {
        throw HostError("invalid_schema", "\(key) must be a string")
      }
    }
    if let properties = schema["properties"] {
      guard let p = properties.object else {
        throw HostError("invalid_schema", "properties must be an object")
      }
      for s in p.values { try lint(s, depth: depth + 1) }
    }
    if let items = schema["items"] { try lint(items, depth: depth + 1) }
    if let required = schema["required"] {
      guard let fields = required.array, fields.allSatisfy({ $0.string != nil }) else {
        throw HostError("invalid_schema", "required must contain strings")
      }
    }
    if let ref = schema["$ref"] {
      guard ref.string != nil else { throw HostError("invalid_schema", "$ref must be a string") }
    }
  }
  public static func validate(
    _ value: Value, against schema: Value, references: [String: Value] = [:], path: String = "$",
    depth: Int = 0
  ) throws {
    guard depth < 32 else { throw HostError("invalid_args", "Schema recursion exceeded") }
    if let ref = schema["$ref"]?.string {
      guard let target = references[ref] else {
        throw HostError("invalid_schema", "Unknown reference \(ref)")
      }
      try validate(value, against: target, references: references, path: path, depth: depth + 1)
    }
    func invalid(_ text: String) -> HostError { HostError("invalid_args", "\(path): \(text)") }
    if let options = schema["enum"]?.array, !options.contains(value) {
      throw invalid("Not an allowed value")
    }
    if let type = schema["type"]?.string {
      let matches: Bool
      switch (type, value) {
      case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool),
        ("null", .null):
        matches = true
      case ("number", .number(let n)): matches = n.isFinite
      case ("integer", .number(let n)): matches = n.isFinite && n.rounded() == n
      default: matches = false
      }
      guard matches else { throw invalid("Expected \(type)") }
    }
    if let fields = value.object {
      for field in schema["required"]?.array ?? [] {
        guard let key = field.string, fields[key] != nil else {
          throw invalid("Missing \(field.string ?? "field")")
        }
      }
      let properties = schema["properties"]?.object ?? [:]
      if schema["additionalProperties"]?.bool == false,
        !Set(fields.keys).isSubset(of: Set(properties.keys))
      {
        throw invalid("Unknown field")
      }
      for (key, v) in fields {
        if let s = properties[key] {
          try validate(
            v, against: s, references: references, path: "\(path).\(key)", depth: depth + 1)
        }
      }
    }
    if let list = value.array, let s = schema["items"] {
      for (i, v) in list.enumerated() {
        try validate(v, against: s, references: references, path: "\(path)[\(i)]", depth: depth + 1)
      }
    }
    if let n = value.number {
      if let min = schema["minimum"]?.number, n < min { throw invalid("Below minimum") }
      if let max = schema["maximum"]?.number, n > max { throw invalid("Above maximum") }
    }
    if let text = value.string {
      if let max = schema["maxLength"]?.int, text.count > max { throw invalid("Text too long") }
      if let format = schema["format"]?.string {
        switch format {
        case "date-time":
          guard ISO8601DateFormatter().date(from: text) != nil else {
            throw invalid("Invalid date-time")
          }
        case "uri": guard URL(string: text)?.scheme != nil else { throw invalid("Invalid URI") }
        case "email":
          guard text.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil
          else { throw invalid("Invalid email") }
        default: throw HostError("invalid_schema", "Unsupported format \(format)")
        }
      }
    }
  }
}
