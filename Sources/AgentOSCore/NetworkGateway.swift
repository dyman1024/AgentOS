import Foundation

/// Every redirect is a new checked exit. Transport injection is only used by host tests.
public actor NetworkGateway {
  public typealias Resolver = @Sendable (String) async throws -> HTTPDestination
  public typealias Sender =
    @Sendable (HTTPDestination, String, [String: String], Data?, Int) async throws -> HTTPResult
  public typealias Confirmation = @Sendable (SinkTicket) async -> Bool
  private let kernel: Kernel
  private let resolve: Resolver?
  private let send: Sender?
  public init(
    kernel: Kernel, resolve: Resolver? = nil,
    send: Sender? = nil
  ) {
    self.kernel = kernel
    self.resolve = resolve
    self.send = send
  }
  public func fetch(
    _ args: Value, service: String? = nil, context: RequestContext, confirm: Confirmation? = nil
  ) async throws -> Value {
    let initial = try args.requiredString("url")
    var current = try HTTPClient.validateURL(initial)
    var method = (args["method"]?.string ?? "GET").uppercased()
    if service != nil, method != "GET" {
      throw HostError("denied", "Content services only perform GET requests")
    }
    guard let values = (args["headers"] ?? [:]).object,
      values.values.allSatisfy({ $0.string != nil })
    else { throw HostError("invalid_args", "Headers must be strings") }
    var headers = values.mapValues { $0.string! }
    var body = args["body"]?.string.map { Data($0.utf8) }
    let maxBytes = args["maxBytes"]?.int ?? 2_000_000
    try HTTPClient.validateRequest(
      method: method, headers: headers, body: body, maximumBytes: maxBytes)
    if headers.keys.contains(where: { ["authorization", "cookie"].contains($0.lowercased()) }) {
      try await kernel.propagate(Labels(isPrivate: true), to: context)
    }
    for redirect in 0...5 {
      let host = current.host!.lowercased()
      var bound = args.object!
      bound["url"] = .string(current.absoluteString)
      bound["method"] = .string(method)
      bound["headers"] = .object(headers.mapValues(Value.string))
      bound["body"] = body.map { .string(String(decoding: $0, as: UTF8.self)) }
      let ticket = try await kernel.prepareSink(
        action: service ?? "net.fetch", args: .object(bound),
        effect: method == "GET" || method == "HEAD" ? .fetch : .irreversible,
        capability: service == nil ? "net" : "service", scope: service ?? host,
        knownURL: try await kernel.isKnownURL(current.absoluteString, context: context),
        context: context)
      if ticket.state == "pending" {
        guard let confirm else {
          throw HostError(
            "needs_confirmation", ticket.reason ?? "Confirmation required",
            details: ["operationID": .string(ticket.id)])
        }
        let accepted = await confirm(ticket)
        try await kernel.approveSink(ticket.id, allow: accepted)
        guard accepted else { throw HostError("denied", "Request declined") }
      }
      _ = try await kernel.claimSink(ticket.id, context: context)
      let result: HTTPResult
      do {
        let destination: HTTPDestination
        if let resolve {
          destination = try await resolve(current.absoluteString)
        } else {
          destination = try await HTTPClient.resolve(current.absoluteString)
        }
        // The real resolver pins a validated public address; validation repeats after any approval wait.
        try await kernel.validateContext(context)
        if let service {
          try await kernel.authorize(context, capability: "service", scope: service)
        } else {
          try await kernel.authorizeNetwork(host, context: context)
        }
        if let send {
          result = try await send(destination, method, headers, body, maxBytes)
        } else {
          result = try await HTTPClient.send(
            destination, method: method, headers: headers, body: body, maximumBytes: maxBytes)
        }
        try await kernel.finishSink(
          ticket.id, state: "done",
          result: [
            "status": .number(Double(result.status)), "bytes": .number(Double(result.body.count)),
          ])
      } catch {
        try? await kernel.finishSink(
          ticket.id, state: method == "GET" || method == "HEAD" ? "failed" : "unknown",
          result: ["message": .string(error.localizedDescription)])
        throw error
      }
      try await kernel.propagate(Labels(taint: ["web:" + current.absoluteString]), to: context)
      try await kernel.rememberURLs([current.absoluteString], context: context)
      if [301, 302, 303, 307, 308].contains(result.status),
        let location = result.headers["location"]
      {
        guard redirect < 5, let next = URL(string: location, relativeTo: current)?.absoluteURL
        else { throw HostError("network_error", "Redirect limit exceeded") }
        current = try HTTPClient.validateURL(next.absoluteString)
        // Never forward credentials to a different origin.
        if current.host?.lowercased() != host
          || current.port != URL(string: bound["url"]!.string!)?.port
        {
          headers = [:]
        }
        if result.status == 303 || ([301, 302].contains(result.status) && method == "POST") {
          method = "GET"
          body = nil
        }
        continue
      }
      try await kernel.validateContext(context)
      return [
        "url": .string(current.absoluteString), "status": .number(Double(result.status)),
        "headers": .object(
          result.headers.filter { !["set-cookie", "set-cookie2"].contains($0.key) }.mapValues(
            Value.string)), "body": .string(String(decoding: result.body, as: UTF8.self)),
        "base64": .string(result.body.base64EncodedString()), "effectID": .string(ticket.id),
        "labels": try await Value.from(kernel.labels(for: context)),
      ]
    }
    throw HostError("network_error", "Redirect limit exceeded")
  }
}
