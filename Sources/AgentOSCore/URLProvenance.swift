import Foundation

extension Kernel {
  /// Called only by host input and content adapters, never exposed as an application capability.
  public func rememberURLs(_ urls: [String], context: RequestContext) throws {
    try validateContext(context)
    guard let run = context.runID else { return }
    let count =
      try db.query("SELECT COUNT(*) AS count FROM known_urls WHERE run_id=?", [.string(run)])
      .first?["count"]?.int ?? 0
    for value in urls.prefix(max(0, 1000 - count)) {
      guard let url = try? HTTPClient.validateURL(value) else { continue }
      try db.execute(
        "INSERT OR IGNORE INTO known_urls VALUES (?,?)",
        [.string(run), .string(url.absoluteString)])
    }
  }
  public func isKnownURL(_ value: String, context: RequestContext) throws -> Bool {
    try validateContext(context)
    guard let run = context.runID else { return false }
    return try !db.query(
      "SELECT 1 FROM known_urls WHERE run_id=? AND url=?", [.string(run), .string(value)]
    ).isEmpty
  }
  public func rememberUserLinks(_ text: String, context: RequestContext) throws {
    let pattern = try NSRegularExpression(pattern: "https://[^\\s<>\\\"）)]+")
    let urls = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      Range($0.range, in: text).map { String(text[$0]) }
    }
    try rememberURLs(urls, context: context)
  }
}
