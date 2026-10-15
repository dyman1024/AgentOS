import CryptoKit
import Foundation

/// The interchange ZIP profile uses stored entries only. No decompressor, links or executable attributes.
public enum PackageArchive {
  private static let crcTable: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    return crc
  }
  private static func crc(_ data: Data) -> UInt32 {
    var value = UInt32.max
    for byte in data { value = crcTable[Int((value ^ UInt32(byte)) & 255)] ^ (value >> 8) }
    return value ^ UInt32.max
  }
  private static func word(_ n: UInt32, _ length: Int = 4) -> Data {
    Data((0..<length).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) })
  }
  private static func number(_ data: Data, _ offset: Int, _ length: Int = 4) throws -> UInt32 {
    guard offset >= 0, offset + length <= data.count else {
      throw HostError("invalid_package", "Truncated ZIP")
    }
    return (0..<length).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
  }
  private static func validPath(_ name: String) -> Bool {
    let parts = name.split(separator: "/", omittingEmptySubsequences: false)
    return !parts.isEmpty && name.utf8.count < 2048 && !name.contains("\\")
      && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
      && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }
  }
  public static func zip(_ files: [String: Data]) throws -> Data {
    guard files.count <= 10000, files.values.reduce(0, { $0 + $1.count }) <= 200_000_000 else {
      throw HostError("too_large", "Package exceeds limits")
    }
    var output = Data()
    var central = Data()
    var names = Set<String>()
    for name in files.keys.sorted() {
      guard validPath(name),
        names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted
      else { throw HostError("invalid_package", "Invalid or duplicate package path") }
      let content = files[name]!
      let bytes = Data(name.utf8)
      let checksum = crc(content)
      let size = UInt32(content.count)
      let offset = UInt32(output.count)
      output += word(0x0403_4b50)
      output += word(20, 2)
      output += word(0x800, 2)
      output += word(0, 2)
      output += word(0)
      output += word(checksum)
      output += word(size)
      output += word(size)
      output += word(UInt32(bytes.count), 2)
      output += word(0, 2)
      output += bytes
      output += content
      central += word(0x0201_4b50)
      central += word(20, 2)
      central += word(20, 2)
      central += word(0x800, 2)
      central += word(0, 2)
      central += word(0)
      central += word(checksum)
      central += word(size)
      central += word(size)
      central += word(UInt32(bytes.count), 2)
      central += word(0, 2)
      central += word(0, 2)
      central += word(0, 2)
      central += word(0, 2)
      central += word(0)
      central += word(offset)
      central += bytes
    }
    let offset = UInt32(output.count)
    output += central
    output += word(0x0605_4b50)
    output += word(0, 2)
    output += word(0, 2)
    output += word(UInt32(files.count), 2)
    output += word(UInt32(files.count), 2)
    output += word(UInt32(central.count))
    output += word(offset)
    output += word(0, 2)
    return output
  }
  public static func unzip(_ data: Data) throws -> [String: Data] {
    guard data.count >= 22, data.count <= 225_000_000 else {
      throw HostError("too_large", "Invalid package size")
    }
    let end = data.count - 22
    guard try number(data, end) == 0x0605_4b50, try number(data, end + 4) == 0,
      try number(data, end + 20, 2) == 0
    else { throw HostError("invalid_package", "Unsupported ZIP profile") }
    let count = Int(try number(data, end + 10, 2))
    let centralSize = Int(try number(data, end + 12))
    let centralOffset = Int(try number(data, end + 16))
    guard count <= 10000, try number(data, end + 8, 2) == count, centralOffset + centralSize == end
    else { throw HostError("invalid_package", "Invalid ZIP directory") }
    var result: [String: Data] = [:]
    var names = Set<String>()
    var cursor = centralOffset
    var localEnd = 0
    var total = 0
    for _ in 0..<count {
      guard try number(data, cursor) == 0x0201_4b50, try number(data, cursor + 8, 2) == 0x800,
        try number(data, cursor + 10, 2) == 0, try number(data, cursor + 30, 2) == 0,
        try number(data, cursor + 32, 2) == 0, try number(data, cursor + 34, 2) == 0,
        try number(data, cursor + 38) == 0
      else {
        throw HostError(
          "invalid_package", "Compressed, linked or extended ZIP entries are not accepted")
      }
      let size = Int(try number(data, cursor + 20))
      let length = Int(try number(data, cursor + 28, 2))
      let offset = Int(try number(data, cursor + 42))
      let checksum = try number(data, cursor + 16)
      guard size == Int(try number(data, cursor + 24)), cursor + 46 + length <= end,
        offset == localEnd, length > 0
      else { throw HostError("invalid_package", "Overlapping or invalid ZIP entry") }
      guard let name = String(data: data[(cursor + 46)..<(cursor + 46 + length)], encoding: .utf8),
        validPath(name),
        names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted
      else { throw HostError("invalid_package", "Invalid package path") }
      guard try number(data, offset) == 0x0403_4b50, try number(data, offset + 6, 2) == 0x800,
        try number(data, offset + 8, 2) == 0, try number(data, offset + 14) == checksum,
        try number(data, offset + 18) == size, try number(data, offset + 22) == size,
        try number(data, offset + 26, 2) == length, try number(data, offset + 28, 2) == 0
      else { throw HostError("invalid_package", "ZIP headers disagree") }
      let start = offset + 30 + length
      total += size
      guard start + size <= centralOffset, total <= 200_000_000,
        Data(data[(offset + 30)..<start]) == Data(name.utf8)
      else { throw HostError("invalid_package", "Invalid ZIP payload") }
      let content = Data(data[start..<(start + size)])
      guard crc(content) == checksum else {
        throw HostError("invalid_package", "ZIP checksum mismatch")
      }
      result[name] = content
      localEnd = start + size
      cursor += 46 + length
    }
    guard cursor == end, localEnd == centralOffset else {
      throw HostError("invalid_package", "Unexpected ZIP content")
    }
    return result
  }
  public static func sign(files: [String: Data], key: Curve25519.Signing.PrivateKey) throws -> Data
  {
    guard !files.isEmpty else { throw HostError("invalid_package", "Empty package") }
    let hashes = files.mapValues { Value.string(Kernel.digest($0)) }
    let descriptor: Value = [
      "schema": "agentos.archive/1", "files": .object(hashes),
      "publicKey": .string(key.publicKey.rawRepresentation.base64EncodedString()),
    ]
    let canonical = try descriptor.encoded()
    var entries = files.mapKeys { "payload/" + $0 }
    entries["manifest.json"] = canonical
    entries["signature.ed25519"] = try key.signature(for: canonical)
    return try zip(entries)
  }
  public static func verify(_ bytes: Data) throws -> (files: [String: Data], fingerprint: String) {
    let entries = try unzip(bytes)
    guard let raw = entries["manifest.json"], let signature = entries["signature.ed25519"] else {
      throw HostError("invalid_package", "Package is unsigned")
    }
    let descriptor = try Value.parse(String(decoding: raw, as: UTF8.self))
    guard descriptor["schema"] == "agentos.archive/1", let hashes = descriptor["files"]?.object,
      let encoded = descriptor["publicKey"]?.string, let data = Data(base64Encoded: encoded)
    else { throw HostError("invalid_package", "Invalid signed descriptor") }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: data)
    guard key.isValidSignature(signature, for: try descriptor.encoded()),
      entries.count == hashes.count + 2
    else { throw HostError("invalid_package", "Package signature mismatch") }
    var files: [String: Data] = [:]
    for (name, hash) in hashes {
      guard validPath(name), let content = entries["payload/" + name],
        hash.string == Kernel.digest(content)
      else { throw HostError("invalid_package", "Package payload was modified") }
      files[name] = content
    }
    return (files, Kernel.digest(data))
  }
}
extension Dictionary where Key == String {
  fileprivate func mapKeys(_ transform: (String) -> String) -> [String: Value] {
    Dictionary(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
  }
}
