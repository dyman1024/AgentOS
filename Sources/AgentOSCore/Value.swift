import Foundation

public enum Value: Codable, Sendable, Equatable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([Value])
  case object([String: Value])
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([Value].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: Value].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
  public subscript(_ key: String) -> Value? { object?[key] }
  public var object: [String: Value]? {
    if case .object(let v) = self { return v }
    return nil
  }
  public var array: [Value]? {
    if case .array(let v) = self { return v }
    return nil
  }
  public var string: String? {
    if case .string(let v) = self { return v }
    return nil
  }
  public var number: Double? {
    if case .number(let v) = self { return v }
    return nil
  }
  public var bool: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }
  public var int: Int? {
    guard let n = number, n.isFinite, n.rounded() == n, n > Double(Int.min), n < Double(Int.max)
    else { return nil }
    return Int(n)
  }
  public func encoded() throws -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try e.encode(self)
  }
  public func text() throws -> String { String(decoding: try encoded(), as: UTF8.self) }
  public static func parse(_ string: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(string.utf8))
  }
  public static func from<T: Encodable>(_ object: T) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(object))
  }
  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: encoded())
  }
  public var foundation: Any {
    switch self {
    case .null: NSNull()
    case .bool(let v): v
    case .number(let v): v
    case .string(let v): v
    case .array(let v): v.map(\.foundation)
    case .object(let v): v.mapValues(\.foundation)
    }
  }
}
extension Value: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByStringLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(arrayLiteral elements: Value...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, Value)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
  }
}
public struct HostError: Error, Codable, Sendable, Equatable, LocalizedError {
  public let code: String
  public let message: String
  public let details: Value
  public init(_ code: String, _ message: String, details: Value = .null) {
    self.code = code
    self.message = message
    self.details = details
  }
  public var errorDescription: String? { "\(code): \(message)" }
}
