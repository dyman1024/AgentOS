import AgentOSCore
import AgentOSRuntime
import Foundation
import Observation

@MainActor @Observable final class MailService {
  let kernel: Kernel, settings: ModelSettings, config: URL
  private(set) var accounts: [MailAccount] = []
  private(set) var status = "尚未连接邮箱"
  private var syncTask: Task<Void, Never>?
  private var nextSync = Date.distantPast
  init(kernel: Kernel, settings: ModelSettings, root: URL) {
    self.kernel = kernel
    self.settings = settings
    config = root.appendingPathComponent("system/mail-accounts.json")
    if let data = try? Data(contentsOf: config),
      let saved = try? JSONDecoder().decode([MailAccount].self, from: data)
    {
      accounts = saved
    }
  }
  func save(username: String, imap: String, smtp: String, password: String) throws {
    guard accounts.count < 10 else { throw HostError("invalid_args", "最多连接 10 个邮箱") }
    let account = try MailAccount(username: username, imapHost: imap, smtpHost: smtp)
    try settings.saveCredential("mail:" + account.id, value: password)
    accounts.append(account)
    try persist()
    nextSync = .distantPast
  }
  func remove(_ id: String) throws {
    accounts.removeAll { $0.id == id }
    try persist()
    try settings.removeCredential("mail:" + id)
    status = "已断开；保留本地邮件摘要"
  }
  private func persist() throws {
    try JSONEncoder().encode(accounts).write(to: config, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
  }
  private func account(_ id: String) throws -> MailAccount {
    guard let account = accounts.first(where: { $0.id == id }) else {
      throw HostError("not_found", "邮箱账户未连接")
    }
    return account
  }
  private func password(_ account: MailAccount) throws -> String {
    guard let key = settings.credential("mail:" + account.id) else {
      throw HostError("unavailable", "邮箱凭据不可用")
    }
    return key
  }
  func listAccounts(context: RequestContext) async throws -> Value {
    try await kernel.authorize(context, capability: "service", scope: "mail.read")
    try await kernel.propagate(Labels(taint: ["mail"], isPrivate: true), to: context)
    return .array(try accounts.map { try Value.from($0) })
  }
  func read(_ name: String, args: Value, context: RequestContext) async throws -> Value {
    try await kernel.authorize(context, capability: "service", scope: "mail.read")
    let account = try account(args.requiredString("account"))
    let folder = args["folder"]?.string ?? "INBOX"
    let uid = name == "mail.get" ? args["uid"]?.int : nil
    guard name != "mail.get" || uid != nil else {
      throw HostError("invalid_args", "mail.get requires uid and uidValidity")
    }
    let query = name == "mail.search" ? try args.requiredString("query") : nil
    let result = try await IMAPClient.fetch(
      account, password: password(account), folder: folder, uid: uid, query: query
    ) { [kernel] in
      try await kernel.authorize(context, capability: "service", scope: "mail.read")
    }
    _ = try self.account(account.id)
    try await kernel.authorize(context, capability: "service", scope: "mail.read")
    try await kernel.propagate(Labels(taint: ["mail:" + account.id], isPrivate: true), to: context)
    if let raw = result.message {
      guard args["uidValidity"]?.int == result.uidValidity else {
        throw HostError("conflict", "邮箱已重建，请重新列出邮件")
      }
      let parsed = try await ArticleReader().parseMail(raw)
      try await kernel.validateContext(context)
      return parsed
    }
    return [
      "account": .string(account.id), "folder": .string(folder),
      "uidValidity": .number(Double(result.uidValidity)),
      "uids": .array(result.uids.suffix(200).map { .number(Double($0)) }),
      "total": .number(Double(result.uids.count)),
    ]
  }
  func send(_ args: Value, context: RequestContext) async throws -> Value {
    let account = try account(args.requiredString("account"))
    guard let values = args["to"]?.array, values.allSatisfy({ $0.string != nil }) else {
      throw HostError("invalid_args", "to must be an array of addresses")
    }
    let recipients = values.compactMap(\.string)
    let subject = try args.requiredString("subject")
    let body = try args.requiredString("body")
    try await kernel.propagate(Labels(isPrivate: true), to: context)
    try await MailTransport.send(
      account, password: password(account), to: recipients, subject: subject, body: body
    ) { [kernel] in
      try await kernel.authorize(context, capability: "service", scope: "mail.send")
    }
    return ["sent": true, "reversible": false]
  }
  func stop() {
    syncTask?.cancel()
    syncTask = nil
  }
  func pump() {
    guard syncTask == nil, !accounts.isEmpty, Date() >= nextSync else { return }
    nextSync = Date().addingTimeInterval(300)
    syncTask = Task { [weak self] in
      guard let self else { return }
      defer { syncTask = nil }
      for account in accounts {
        do {
          status = "正在同步 " + account.username
          let password = try password(account)
          let listing = try await IMAPClient.fetch(account, password: password)
          var imported = 0
          for uid in listing.uids.suffix(100).reversed() {
            guard accounts.contains(where: { $0.id == account.id }) else { break }
            if try await kernel.hasMail(
              account: account.id, folder: "INBOX", validity: listing.uidValidity, uid: uid)
            {
              continue
            }
            let message = try await IMAPClient.fetch(account, password: password, uid: uid)
            guard accounts.contains(where: { $0.id == account.id }),
              message.uidValidity == listing.uidValidity, let raw = message.message
            else { break }
            let parsed = try await ArticleReader().parseMail(raw)
            guard accounts.contains(where: { $0.id == account.id }) else { break }
            try Task.checkCancellation()
            _ = try await kernel.indexMail(
              account: account.id, folder: "INBOX", validity: listing.uidValidity, uid: uid,
              parsed: parsed)
            imported += 1
            if imported >= 5 { break }
          }
          status = account.username + " · 本轮新增 \(imported) 封摘要"
        } catch { status = account.username + " · " + error.localizedDescription }
      }
    }
  }
}
