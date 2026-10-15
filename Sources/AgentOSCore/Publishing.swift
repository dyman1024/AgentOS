import Foundation

public struct Publication: Sendable {
  public let repository: String, path: String, branch: String, content: String, title: String,
    sha: String?
  public init(
    repository: String, path: String, branch: String = "main", content: String, title: String,
    sha: String? = nil
  ) throws {
    guard
      repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
      path.hasSuffix(".md"), !path.hasPrefix("/"), path.utf8.count <= 1024,
      path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".git") && !$0.contains("\\")
          && !$0.contains("\0")
      }),
      branch.range(of: "^[A-Za-z0-9_./-]{1,100}$", options: .regularExpression) != nil,
      !branch.contains(".."),
      content.utf8.count <= 500000, title.count <= 500,
      sha == nil || sha!.range(of: "^[a-fA-F0-9]{40,64}$", options: .regularExpression) != nil
    else {
      throw HostError(
        "invalid_args", "Use owner/repo, a relative Markdown path and valid branch/SHA")
    }
    self.repository = repository
    self.path = path
    self.branch = branch
    self.content = content
    self.title = title
    self.sha = sha
  }
  public var request: Value {
    var fields: [String: Value] = [
      "message": .string("Publish: " + title),
      "content": .string(Data(content.utf8).base64EncodedString()), "branch": .string(branch),
    ]
    fields["sha"] = sha.map(Value.string)
    return .object(fields)
  }
  public var endpoint: String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
    return "https://api.github.com/repos/" + repository + "/contents/"
      + path.split(separator: "/").map {
        String($0).addingPercentEncoding(withAllowedCharacters: safe)!
      }.joined(separator: "/")
  }
}
public actor Publisher {
  let kernel: Kernel
  public init(kernel: Kernel) { self.kernel = kernel }
  public func publish(
    _ args: Value, context: RequestContext, confirm: NetworkGateway.Confirmation?,
    upload: @Sendable (Publication) async throws -> Value
  ) async throws -> Value {
    try await kernel.authorize(context, capability: "service", scope: "publish")
    let doc = try await kernel.get(
      "documents", id: args.requiredString("document"), context: context)
    let plan = try Publication(
      repository: args.requiredString("repository"), path: args.requiredString("path"),
      branch: args["branch"]?.string ?? "main", content: doc.fields["body"]?.string ?? "",
      title: doc.fields["title"]?.string ?? "Document", sha: args["sha"]?.string)
    let details: Value = [
      "document": .string(doc.id), "revision": .number(Double(doc.rev)),
      "repository": .string(plan.repository), "path": .string(plan.path),
      "branch": .string(plan.branch), "title": .string(plan.title), "body": .string(plan.content),
      "sha": plan.sha.map(Value.string) ?? .null,
    ]
    let ticket = try await kernel.prepareSink(
      action: "publish", args: details, effect: .irreversible, capability: "service",
      scope: "publish", context: context)
    if ticket.state == "pending" {
      guard let confirm else {
        throw HostError(
          "needs_confirmation", ticket.reason ?? "Publication requires confirmation",
          details: ["operationID": .string(ticket.id)])
      }
      let allowed = await confirm(ticket)
      try await kernel.approveSink(ticket.id, allow: allowed)
      guard allowed else { throw HostError("denied", "Publication declined") }
    }
    _ = try await kernel.claimSink(ticket.id, context: context)
    var fields = doc.fields
    fields["status"] = "published"
    fields["publicationState"] = "sending"
    let staged: MutationResult
    do {
      staged = try await kernel.put(
        "documents", id: doc.id, fields: fields, expectedRevision: doc.rev, context: context)
    } catch {
      try? await kernel.finishSink(
        ticket.id, state: "failed", result: ["message": .string(error.localizedDescription)])
      throw error
    }
    do {
      try await kernel.authorize(context, capability: "service", scope: "publish")
      let result = try await upload(plan)
      let url = result["content"]?["html_url"]?.string ?? ""
      fields["publishedUrl"] = .string(url)
      fields["publicationState"] = "committed"
      fields["publicationCommit"] = result["commit"]?["sha"]
      _ = try await kernel.put(
        "documents", id: doc.id, fields: fields, expectedRevision: staged.record.rev,
        context: context)
      let output: Value = [
        "state": "committed", "url": .string(url), "commit": result["commit"]?["sha"] ?? .null,
        "effectID": .string(ticket.id),
        "note": "Repository commit accepted; Pages deployment must be checked separately",
      ]
      try await kernel.finishSink(ticket.id, state: "done", result: output)
      return output
    } catch {
      let definite = (error as? HostError)?.code == "service_error"
      if definite {
        _ = try? await kernel.undo(staged.effectID, context: context)
      } else {
        fields["publicationState"] = "unknown"
        _ = try? await kernel.put(
          "documents", id: doc.id, fields: fields, expectedRevision: staged.record.rev,
          context: context)
      }
      try? await kernel.finishSink(
        ticket.id, state: definite ? "failed" : "unknown",
        result: ["message": .string(error.localizedDescription), "automaticRetry": false])
      throw error
    }
  }
}
