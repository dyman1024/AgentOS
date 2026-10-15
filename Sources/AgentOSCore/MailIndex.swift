import Foundation

extension Kernel {
  public static func mailID(account: String, folder: String, validity: Int, uid: Int) -> String {
    digest(Data("\(account)\n\(folder)\n\(validity)\n\(uid)".utf8))
  }
  /// Host-only indexing: the record and its delivery event are committed together.
  public func indexMail(account: String, folder: String, validity: Int, uid: Int, parsed: Value)
    throws -> Bool
  {
    let id = Self.mailID(account: account, folder: folder, validity: validity, uid: uid)
    if try readRecord("mail", id: id) != nil { return false }
    let labels = Labels(taint: ["mail:" + account], isPrivate: true)
    let context = RequestContext(.service("mail-sync"), instanceID: "mail-sync")
    try bindInstance("mail-sync", principal: .service("mail-sync"))
    try propagate(labels, to: context)
    return try db.transaction {
      let fields: [String: Value] = [
        "account": .string(account), "folder": .string(folder),
        "uidValidity": .number(Double(validity)), "uid": .number(Double(uid)),
        "subject": .string(String((parsed["subject"]?.string ?? "").prefix(2000))),
        "from": parsed["from"]?["address"] ?? "",
        "to": .array((parsed["to"]?.array ?? []).compactMap { $0["address"] }),
        "date": parsed["date"] ?? "",
        "snippet": .string(String((parsed["text"]?.string ?? "").prefix(500))),
        "messageId": parsed["messageId"] ?? "", "flags": [],
      ]
      _ = try put("mail", id: id, fields: fields, context: context)
      try appendEvent(
        DomainEvent(
          id: "mail-received:" + id, type: "mail.received", source: "service:mail", subject: id,
          time: Self.now(), labels: labels, depth: 0, runID: nil,
          data: ["collection": "mail", "id": .string(id), "account": .string(account)]))
      return true
    }
  }
  public func hasMail(account: String, folder: String, validity: Int, uid: Int) throws -> Bool {
    try readRecord(
      "mail", id: Self.mailID(account: account, folder: folder, validity: validity, uid: uid))
      != nil
  }
}
