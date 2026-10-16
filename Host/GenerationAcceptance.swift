import AgentOSCore
import Foundation

extension AppModel {
  /// Fixed user tasks, independent of the Builder's own tests. Every write goes through its IDL.
  func generationAcceptance(_ app: InstalledApp, kind: String) async -> Value {
    let context = RequestContext(.user)
    let collection = kind
    let token = UUID().uuidString.lowercased()
    var results: [Value] = []
    func check(_ condition: Bool) throws {
      if !condition {
        throw HostError("acceptance_failed", "Observed result does not satisfy the task")
      }
    }
    func call(_ tool: String, _ args: Value) async throws -> Value {
      try await runtime.call(app.namespace + "." + tool, args: args, caller: context)
    }
    func fields(_ title: String) -> [String: Value] {
      switch kind {
      case "notes": return ["title": .string(title), "body": "正文", "tags": [.string(token)]]
      case "tasks": return ["title": .string(title), "done": false, "due": "2098-01-20"]
      case "bookmarks":
        return [
          "title": .string(title), "url": .string("https://example.com/" + title),
          "tags": [.string(token)],
        ]
      default:
        return [
          "title": .string(title), "amount": 4, "type": "expense", "category": "food",
          "date": "2098-01-20",
        ]
      }
    }
    func seed(_ suffix: String, _ values: [String: Value]? = nil) async throws -> Record {
      try await kernel.put(
        collection, id: token + suffix, fields: values ?? fields(token + suffix), context: context
      ).record
    }
    func test(_ name: String, _ body: () async throws -> Void) async {
      do {
        try await body()
        results.append(["task": .string(name), "pass": true])
      } catch {
        results.append([
          "task": .string(name), "pass": false, "error": .string(error.localizedDescription),
        ])
      }
    }
    await test("create") {
      _ = try await call(
        "create", ["id": .string(token + "create"), "record": .object(fields(token))])
      try check(
        try await kernel.get(collection, id: token + "create", context: context).fields["title"]
          == .string(token))
    }
    await test("get") {
      let item = try await seed("get")
      let value = try await call("get", ["id": .string(item.id)])
      try check(value["_id"] == .string(item.id) && value["title"] == item.fields["title"])
    }
    await test("edit") {
      let item = try await seed("edit")
      var changed = item.fields
      changed["title"] = "已修改"
      _ = try await call(
        "update",
        [
          "id": .string(item.id), "record": .object(changed),
          "expectedRev": .number(Double(item.rev)),
        ])
      try check(
        try await kernel.get(collection, id: item.id, context: context).fields["title"] == "已修改")
    }
    await test("delete") {
      let item = try await seed("delete")
      _ = try await call(
        "delete", ["id": .string(item.id), "expectedRev": .number(Double(item.rev))])
      do {
        _ = try await kernel.get(collection, id: item.id, context: context)
        try check(false)
      } catch let error as HostError { try check(error.code == "not_found") }
    }
    await test("search") {
      let item = try await seed("search")
      let value = try await call("list", ["text": item.fields["title"]!])
      try check(value.array?.contains(where: { $0["_id"] == .string(item.id) }) == true)
      try check(value.array?.allSatisfy { $0["title"] == item.fields["title"] } == true)
    }
    if kind == "notes" || kind == "bookmarks" {
      await test("tag filter") {
        let item = try await seed("tag")
        var other = fields(token + "other")
        other["tags"] = ["unrelated"]
        let excluded = try await seed("other", other)
        let value = try await call("list", ["tag": .string(token)])
        try check(value.array?.contains(where: { $0["_id"] == .string(item.id) }) == true)
        try check(value.array?.contains(where: { $0["_id"] == .string(excluded.id) }) == false)
      }
    }
    if kind == "tasks" {
      await test("complete and filter") {
        let item = try await seed("complete")
        var done = item.fields
        done["done"] = true
        _ = try await call(
          "update",
          [
            "id": .string(item.id), "record": .object(done),
            "expectedRev": .number(Double(item.rev)),
          ])
        try check(
          try await kernel.get(collection, id: item.id, context: context).fields["done"] == true)
        let list = try await call("list", ["done": false])
        try check(
          list.array != nil
            && list.array?.contains(where: { $0["_id"] == .string(item.id) }) == false)
      }
      await test("due ordering") {
        var early = fields(token + "early")
        early["due"] = "2098-01-01"
        let first = try await seed("early", early)
        let last = try await seed("late")
        let list = try await call("list", ["text": .string(token), "orderBy": "due"])
        let ids = list.array?.compactMap { $0["_id"]?.string } ?? []
        guard let a = ids.firstIndex(of: first.id), let b = ids.firstIndex(of: last.id) else {
          try check(false)
          return
        }
        try check(a < b)
      }
    }
    if kind == "bookmarks" {
      await test("URL deduplication") {
        let item = try await seed("dedupe")
        _ = try? await call(
          "create", ["id": .string(token + "duplicate"), "record": .object(item.fields)])
        let found = try await kernel.query(
          collection, where: ["url": item.fields["url"]!], context: context)
        try check(found.count == 1)
      }
    }
    if kind == "expenses" {
      await test("monthly totals") {
        var income = fields(token + "income")
        income["date"] = "2099-02-01"
        income["amount"] = 10
        income["type"] = "income"
        var expense = fields(token + "expense")
        expense["date"] = "2099-02-02"
        _ = try await seed("income", income)
        _ = try await seed("expense", expense)
        let totals = try await call("totals", ["month": "2099-02"])
        try check(totals["income"] == 10 && totals["expense"] == 4 && totals["balance"] == 6)
        let list = try await call("list", ["month": "2099-02"])
        try check(list.array?.count == 2)
      }
      await test("reject negative amount") {
        var invalid = fields(token)
        invalid["amount"] = -1
        do {
          _ = try await call(
            "create", ["id": .string(token + "invalid"), "record": .object(invalid)])
          try check(false)
        } catch let error as HostError { try check(error.code != "acceptance_failed") }
        let found = try await kernel.query(
          collection, where: ["_id": .string(token + "invalid")], context: context)
        try check(found.isEmpty)
      }
    }
    return [
      "coverage": .number(
        Double(results.filter { $0["pass"] == true }.count) / Double(results.count)),
      "tasks": .array(results),
    ]
  }
}
