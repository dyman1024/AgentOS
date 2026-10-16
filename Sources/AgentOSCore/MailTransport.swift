import Foundation

public struct MailAccount: Codable, Sendable, Identifiable {
  public let id: String, username: String, imapHost: String, smtpHost: String
  public let imapPort: Int, smtpPort: Int
  public init(
    id: String = UUID().uuidString.lowercased(), username: String, imapHost: String,
    smtpHost: String, imapPort: Int = 993, smtpPort: Int = 465
  ) throws {
    guard UUID(uuidString: id) != nil, Self.validAddress(username) else {
      throw HostError("invalid_args", "Use an email address as the account username")
    }
    _ = try HTTPClient.validateURL("https://\(imapHost):\(imapPort)")
    _ = try HTTPClient.validateURL("https://\(smtpHost):\(smtpPort)")
    self.id = id
    self.username = username
    self.imapHost = imapHost
    self.smtpHost = smtpHost
    self.imapPort = imapPort
    self.smtpPort = smtpPort
  }
  public static func validAddress(_ value: String) -> Bool {
    value.utf8.count <= 254
      && value.range(
        of: "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$",
        options: .regularExpression) != nil
  }
}
public enum MailTransport {
  public static func mime(from: String, to: [String], subject: String, body: String) throws
    -> String
  {
    guard MailAccount.validAddress(from), !to.isEmpty, to.count <= 20,
      to.allSatisfy(MailAccount.validAddress), subject.count <= 300, body.utf8.count <= 500000,
      !subject.unicodeScalars.contains(where: { $0.value < 32 })
    else { throw HostError("invalid_args", "Invalid mail recipients, subject or body") }
    var parts: [String] = []
    var chunk = ""
    for scalar in subject.unicodeScalars {
      let next = String(scalar)
      if chunk.utf8.count + next.utf8.count > 42 {
        parts.append("=?UTF-8?B?" + Data(chunk.utf8).base64EncodedString() + "?=")
        chunk = ""
      }
      chunk += next
    }
    if !chunk.isEmpty { parts.append("=?UTF-8?B?" + Data(chunk.utf8).base64EncodedString() + "?=") }
    let subjectHeader = parts.joined(separator: "\r\n ")
    let bytes = Data(body.utf8).base64EncodedString(options: [
      .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed,
    ])
    let date = DateFormatter()
    date.locale = Locale(identifier: "en_US_POSIX")
    date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    return
      "From: \(from)\r\nTo: \(to.joined(separator:", "))\r\nSubject: \(subjectHeader)\r\nDate: \(date.string(from:Date()))\r\nMessage-ID: <\(UUID().uuidString.lowercased())@agentos.local>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(bytes)\r\n"
  }
  public static func send(
    _ account: MailAccount, password: String, to: [String], subject: String, body: String,
    authorize: @escaping @Sendable () async throws -> Void = {}
  ) async throws {
    let data = try mime(from: account.username, to: to, subject: subject, body: body)
    var options = ["--mail-from", account.username]
    for recipient in to { options += ["--mail-rcpt", recipient] }
    _ = try await transfer(
      host: account.smtpHost, port: account.smtpPort,
      url: "smtps://\(account.smtpHost):\(account.smtpPort)/agentos.local",
      username: account.username, password: password, options: options, upload: data,
      authorize: authorize)
  }
  static func transfer(
    host: String, port: Int, url: String, username: String, password: String, options: [String],
    upload: String?, authorize: @escaping @Sendable () async throws -> Void
  ) async throws -> String {
    guard !password.isEmpty, !password.contains("\0") else {
      throw HostError("invalid_args", "Invalid account credential")
    }
    let target = try await HTTPClient.resolve("https://\(host):\(port)")
    try await authorize()
    return try await Task.detached {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "agentos-mail-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: folder) }
      func quoted(_ value: String) -> String {
        "\""
          + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
            of: "\"", with: "\\\""
          ).replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
          + "\""
      }
      let config = folder.appendingPathComponent("request.cfg")
      let message = folder.appendingPathComponent("message.eml")
      try Data(
        ("url = " + quoted(url) + "\nuser = " + quoted(username + ":" + password) + "\n").utf8
      ).write(to: config)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
      var arguments =
        [
          "--disable", "--silent", "--show-error", "--config", config.path, "--proto",
          "=imaps,smtps", "--ssl-reqd", "--noproxy", "*", "--resolve",
          "\(host):\(port):\(target.address)", "--connect-timeout", "10", "--max-time", "40",
        ] + options
      if let upload {
        try Data(upload.utf8).write(to: message)
        arguments += ["--upload-file", message.path]
      }
      let process = Process()
      let out = Pipe()
      let err = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
      process.arguments = arguments
      process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path]
      process.standardOutput = out
      process.standardError = err
      try process.run()
      var data = Data()
      while let chunk = try out.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
        guard data.count + chunk.count <= 2_000_000 else {
          process.terminate()
          process.waitUntilExit()
          throw HostError("too_large", "Mail response exceeds 2 MB")
        }
        data.append(chunk)
      }
      _ = err.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw HostError(
          "mail_error",
          "Mail transport failed (curl \(process.terminationStatus)); check the account configuration"
        )
      }
      return String(decoding: data, as: UTF8.self)
    }.value
  }
}
