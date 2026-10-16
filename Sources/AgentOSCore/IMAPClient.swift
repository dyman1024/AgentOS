import Foundation
import Network
import Security

/// A TLS connection pinned to the public IP selected by the host, while validating the DNS peer name.
private final class MailTLS: @unchecked Sendable {
  let connection: NWConnection
  let queue = DispatchQueue(label: "agentos.mail.tls")
  let deadline = DispatchTime.now() + 45
  init(address: String, host: String, port: Int) {
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    connection = NWConnection(
      host: .init(address), port: .init(rawValue: UInt16(port))!, using: NWParameters(tls: tls))
  }
  private final class Once<T: Sendable>: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
      lock.lock()
      let saved = continuation
      continuation = nil
      lock.unlock()
      saved?.resume(with: result)
    }
  }
  func connect() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = Once(continuation)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: once.finish(.success(()))
        case .failed(let error): once.finish(.failure(error))
        case .cancelled: once.finish(.failure(HostError("cancelled", "Mail connection closed")))
        default: break
        }
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: deadline) { [self] in
        once.finish(.failure(HostError("timeout", "Mail connection timed out")))
        connection.cancel()
      }
    }
  }
  func read() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      let once = Once<Data>(continuation)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
        if let error {
          once.finish(.failure(error))
        } else if let data, !data.isEmpty {
          once.finish(.success(data))
        } else {
          once.finish(.failure(HostError("mail_error", "Mail server closed the connection")))
        }
      }
      queue.asyncAfter(deadline: deadline) { [self] in
        once.finish(.failure(HostError("timeout", "Mail response timed out")))
        connection.cancel()
      }
    }
  }
  func send(_ text: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = Once(continuation)
      connection.send(
        content: Data(text.utf8),
        completion: .contentProcessed { error in
          if let error { once.finish(.failure(error)) } else { once.finish(.success(())) }
        })
      queue.asyncAfter(deadline: deadline) { [self] in
        once.finish(.failure(HostError("timeout", "Mail request timed out")))
        connection.cancel()
      }
    }
  }
}

public struct MailboxResult: Sendable {
  public let uidValidity: Int
  public let uids: [Int]
  public let message: String?
}

/// Only EXAMINE, UID SEARCH and UID FETCH BODY.PEEK[] are supported. No mailbox mutations.
public actor IMAPClient {
  private var buffer = Data()
  private var sequence = 0
  private let receive: @Sendable () async throws -> Data
  private let send: @Sendable (String) async throws -> Void
  public init(
    receive: @escaping @Sendable () async throws -> Data,
    send: @escaping @Sendable (String) async throws -> Void
  ) {
    self.receive = receive
    self.send = send
  }
  public static func fetch(
    _ account: MailAccount, password: String, folder: String = "INBOX", uid: Int? = nil,
    query: String? = nil, authorize: @escaping @Sendable () async throws -> Void = {}
  ) async throws -> MailboxResult {
    let target = try await HTTPClient.resolve("https://\(account.imapHost):\(account.imapPort)")
    try await authorize()
    let channel = MailTLS(address: target.address, host: account.imapHost, port: account.imapPort)
    defer { channel.connection.cancel() }
    try await channel.connect()
    let client = IMAPClient(
      receive: { try await channel.read() }, send: { try await channel.send($0) })
    return try await client.fetch(
      username: account.username, password: password, folder: folder, uid: uid, query: query)
  }
  private func line() async throws -> String {
    while buffer.range(of: Data([13, 10])) == nil {
      guard buffer.count < 65536 else { throw HostError("too_large", "IMAP line exceeds limit") }
      buffer.append(try await receive())
    }
    let end = buffer.range(of: Data([13, 10]))!
    guard end.lowerBound <= 65536 else { throw HostError("too_large", "IMAP line exceeds limit") }
    let text = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
    buffer.removeSubrange(..<end.upperBound)
    return text
  }
  private func bytes(_ count: Int) async throws -> Data {
    guard (0...2_000_000).contains(count) else {
      throw HostError("too_large", "Mail message exceeds 2 MB")
    }
    while buffer.count < count { buffer.append(try await receive()) }
    let data = Data(buffer.prefix(count))
    buffer.removeFirst(count)
    return data
  }
  private func command(_ text: String) async throws -> ([String], [Data]) {
    sequence += 1
    let tag = "A\(sequence)"
    try await send(tag + " " + text + "\r\n")
    var lines: [String] = []
    var literals: [Data] = []
    var size = 0
    for _ in 0..<10000 {
      let response = try await line()
      size += response.utf8.count
      guard size <= 2_100_000 else { throw HostError("too_large", "Mail response exceeds limit") }
      if response.hasPrefix(tag + " ") {
        guard response.hasPrefix(tag + " OK") else {
          throw HostError("mail_error", "Mail server rejected the request")
        }
        return (lines, literals)
      }
      if response.hasPrefix("* BYE") { throw HostError("mail_error", "Mail session ended") }
      lines.append(response)
      if let match = response.range(of: "\\{[0-9]+\\}$", options: .regularExpression),
        let count = Int(response[match].dropFirst().dropLast())
      {
        size += count
        guard size <= 2_100_000, literals.count < 10 else {
          throw HostError("too_large", "Mail response exceeds limit")
        }
        literals.append(try await bytes(count))
      }
    }
    throw HostError("too_large", "Too many IMAP response lines")
  }
  private func quoted(_ value: String) throws -> String {
    guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      value.utf8.count <= 4096
    else { throw HostError("invalid_args", "Invalid mail argument") }
    return "\""
      + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "\"", with: "\\\"") + "\""
  }
  public func fetch(username: String, password: String, folder: String, uid: Int?, query: String?)
    async throws -> MailboxResult
  {
    guard !password.isEmpty, (1...200).contains(folder.count), (query?.count ?? 0) <= 500,
      uid == nil || uid! > 0
    else { throw HostError("invalid_args", "Invalid mailbox request") }
    let greeting = try await line()
    guard greeting.hasPrefix("* OK ") else {
      throw HostError("mail_error", "Unexpected IMAP greeting")
    }
    _ = try await command("LOGIN " + quoted(username) + " " + quoted(password))
    let (selected, _) = try await command("EXAMINE " + quoted(folder))
    let validity = selected.compactMap { line -> Int? in
      guard let range = line.range(of: "\\[UIDVALIDITY [0-9]+\\]", options: .regularExpression)
      else { return nil }
      return Int(line[range].dropFirst(13).dropLast())
    }.first
    guard let validity, validity > 0 else {
      throw HostError("mail_error", "Mailbox did not provide UIDVALIDITY")
    }
    if let uid {
      let (lines, literals) = try await command("UID FETCH \(uid) (UID BODY.PEEK[])")
      guard lines.contains(where: { $0.contains("UID \(uid) ") || $0.contains("UID \(uid))") }),
        literals.count == 1
      else { throw HostError("not_found", "Message was removed or cannot be read") }
      return MailboxResult(
        uidValidity: validity, uids: [uid], message: String(decoding: literals[0], as: UTF8.self))
    }
    let (lines, _) = try await command(
      query.map { "UID SEARCH CHARSET UTF-8 TEXT " + (try quoted($0)) } ?? "UID SEARCH ALL")
    let ids = lines.filter { $0.hasPrefix("* SEARCH") }.flatMap {
      $0.dropFirst(8).split(separator: " ").compactMap { Int($0) }
    }.filter { $0 > 0 }
    return MailboxResult(uidValidity: validity, uids: Array(Set(ids)).sorted(), message: nil)
  }
}
