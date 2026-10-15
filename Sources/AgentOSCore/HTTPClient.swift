import Darwin
import Foundation

public struct HTTPDestination: Sendable {
  public let url: URL
  public let host: String
  public let address: String
  public let port: Int
  public init(url: URL, host: String, address: String, port: Int) {
    self.url = url
    self.host = host
    self.address = address
    self.port = port
  }
}
public struct HTTPResult: Sendable {
  public let status: Int
  public let headers: [String: String]
  public let body: Data
  public init(status: Int, headers: [String: String], body: Data) {
    self.status = status
    self.headers = headers
    self.body = body
  }
}
public enum HTTPClient {
  public static func validateURL(_ value: String) throws -> URL {
    guard value.utf8.count <= 16384, let url = URL(string: value), url.scheme == "https",
      let host = url.host?.lowercased(), url.user == nil, url.password == nil,
      host.range(of: "^[a-z0-9][a-z0-9.-]*[a-z0-9]$", options: .regularExpression) != nil,
      !host.contains(".."), (url.port ?? 443) > 0, (url.port ?? 443) <= 65535
    else { throw HostError("invalid_args", "Use an HTTPS URL without embedded credentials") }
    return url
  }
  public static func isPublicIPv4(_ text: String) -> Bool {
    let a = text.split(separator: ".").compactMap { Int($0) }
    guard a.count == 4, a.allSatisfy({ 0...255 ~= $0 }) else { return false }
    return
      !(a[0] == 0 || a[0] == 10 || a[0] == 127 || a[0] >= 224 || (a[0] == 169 && a[1] == 254)
      || (a[0] == 172 && 16...31 ~= a[1])
      || (a[0] == 192 && (a[1] == 168 || a[1] == 0 || a[1] == 2))
      || (a[0] == 100 && 64...127 ~= a[1])
      || (a[0] == 198 && (a[1] == 18 || a[1] == 19 || a[1] == 51))
      || (a[0] == 203 && a[1] == 0 && a[2] == 113))
  }
  public static func resolve(_ value: String) async throws -> HTTPDestination {
    let url = try validateURL(value)
    let host = url.host!.lowercased()
    var addresses = try await Task.detached {
      var hints = addrinfo()
      hints.ai_family = AF_INET
      hints.ai_socktype = SOCK_STREAM
      var result: UnsafeMutablePointer<addrinfo>?
      guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
        throw HostError("unavailable", "DNS lookup failed")
      }
      defer { freeaddrinfo(first) }
      var current: UnsafeMutablePointer<addrinfo>? = first
      var addresses: Set<String> = []
      while let item = current {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(
          item.pointee.ai_addr, item.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0,
          NI_NUMERICHOST) == 0
        {
          addresses.insert(
            String(
              decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
              as: UTF8.self))
        }
        current = item.pointee.ai_next
      }
      return addresses
    }.value
    // VPN Fake-IP resolvers reserve 198.18.0.0/15. Resolve those names through a pinned
    // public DoH endpoint instead of treating a synthetic address as a trusted destination.
    if !addresses.isEmpty,
      addresses.allSatisfy({ $0.hasPrefix("198.18.") || $0.hasPrefix("198.19.") }),
      host.contains(where: { $0.isLetter })
    {
      var query = URLComponents(string: "https://cloudflare-dns.com/dns-query")!
      query.queryItems = [
        URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A"),
      ]
      let response = try await send(
        HTTPDestination(url: query.url!, host: "cloudflare-dns.com", address: "1.1.1.1", port: 443),
        headers: ["Accept": "application/dns-json"], maximumBytes: 100000)
      guard response.status == 200 else {
        throw HostError("unavailable", "Public DNS lookup failed")
      }
      addresses = try publicDNSAnswers(Value.parse(String(decoding: response.body, as: UTF8.self)))
    }
    guard !addresses.isEmpty, addresses.allSatisfy(isPublicIPv4) else {
      throw HostError("denied", "Private, local and reserved addresses are blocked")
    }
    return HTTPDestination(
      url: url, host: host, address: addresses.sorted()[0], port: url.port ?? 443)
  }
  static func publicDNSAnswers(_ response: Value) throws -> Set<String> {
    guard response["Status"] == 0 else {
      throw HostError("unavailable", "Public DNS lookup failed")
    }
    let addresses = Set(
      (response["Answer"]?.array ?? []).filter { $0["type"] == 1 }.compactMap { $0["data"]?.string }
    )
    guard !addresses.isEmpty, addresses.allSatisfy(isPublicIPv4) else {
      throw HostError("denied", "Public DNS returned a non-public destination")
    }
    return addresses
  }
  public static func validateRequest(
    method: String, headers: [String: String], body: Data?, maximumBytes: Int
  ) throws {
    guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(method), maximumBytes > 0,
      maximumBytes <= 20_000_000, (body?.count ?? 0) <= 2_000_000, headers.count <= 40
    else { throw HostError("invalid_args", "Request exceeds limits") }
    let forbidden: Set<String> = [
      "host", "connection", "content-length", "transfer-encoding", "proxy-authorization",
      "proxy-connection",
    ]
    for (key, value) in headers {
      guard !forbidden.contains(key.lowercased()),
        key.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
        !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
        value.utf8.count <= 8000
      else { throw HostError("invalid_args", "Invalid HTTP header") }
    }
  }
  public static func send(
    _ destination: HTTPDestination, method: String = "GET", headers: [String: String] = [:],
    body: Data? = nil, maximumBytes: Int = 2_000_000
  ) async throws -> HTTPResult {
    try validateRequest(method: method, headers: headers, body: body, maximumBytes: maximumBytes)
    return try await Task.detached {
      let fm = FileManager.default
      let folder = fm.temporaryDirectory.appendingPathComponent("agentos-http-" + UUID().uuidString)
      try fm.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? fm.removeItem(at: folder) }
      func quoted(_ v: String) -> String {
        "\""
          + v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
            of: "\"", with: "\\\""
          ).replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
          + "\""
      }
      var config = "url = " + quoted(destination.url.absoluteString) + "\n"
      for (k, v) in headers { config += "header = " + quoted(k + ": " + v) + "\n" }
      let configFile = folder.appendingPathComponent("request.cfg")
      let bodyFile = folder.appendingPathComponent("body")
      let responseFile = folder.appendingPathComponent("response")
      let headerFile = folder.appendingPathComponent("headers")
      try Data(config.utf8).write(to: configFile)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
      if let body { try body.write(to: bodyFile) }
      let process = Process()
      let out = Pipe()
      let err = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
      var arguments = [
        "--disable", "--silent", "--show-error", "--config", configFile.path, "--proto", "=https",
        "--noproxy", "*", "--resolve",
        "\(destination.host):\(destination.port):\(destination.address)", "--max-time", "30",
        "--connect-timeout", "10", "--max-filesize", String(maximumBytes), "--max-redirs", "0",
        "--request", method, "--output", responseFile.path, "--dump-header", headerFile.path,
        "--write-out", "%{http_code}",
      ]
      if body != nil { arguments += ["--data-binary", "@" + bodyFile.path] }
      if method == "HEAD" { arguments.append("--head") }
      process.arguments = arguments
      process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path]
      process.standardOutput = out
      process.standardError = err
      try process.run()
      let status = out.fileHandleForReading.readDataToEndOfFile()
      let diagnostic = err.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw HostError(
          "network_error", "HTTPS request failed (curl \(process.terminationStatus))",
          details: ["diagnostic": .string(String(decoding: diagnostic.prefix(500), as: UTF8.self))])
      }
      let bytes = (try? Data(contentsOf: responseFile)) ?? Data()
      guard bytes.count <= maximumBytes else {
        throw HostError("too_large", "Response exceeded the size limit")
      }
      let raw = try String(contentsOf: headerFile, encoding: .utf8)
      let blocks = raw.components(separatedBy: "\r\n\r\n")
      let block = blocks.last(where: { $0.hasPrefix("HTTP/") }) ?? raw
      var fields: [String: String] = [:]
      for line in block.components(separatedBy: "\r\n").dropFirst() {
        if let colon = line.firstIndex(of: ":") {
          fields[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
        }
      }
      return HTTPResult(
        status: Int(String(decoding: status, as: UTF8.self)) ?? 0, headers: fields, body: bytes)
    }.value
  }
}
