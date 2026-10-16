import Foundation
import NaturalLanguage

public enum LocalEmbedding {
  public static func embed(_ input: String, language: String? = nil) throws -> Value {
    guard !input.isEmpty, input.utf8.count <= 100000 else {
      throw HostError("invalid_args", "Embedding input must be 1–100000 bytes")
    }
    let lang =
      language.map(NLLanguage.init(rawValue:)) ?? NLLanguageRecognizer.dominantLanguage(for: input)
      ?? .english
    guard let model = NLEmbedding.sentenceEmbedding(for: lang),
      let vector = model.vector(for: input)
    else { throw HostError("unavailable", "No local sentence model for \(lang.rawValue)") }
    return [
      "model": .string("apple-nl:" + lang.rawValue + ":" + String(model.revision)),
      "language": .string(lang.rawValue), "vector": .array(vector.map(Value.number)),
      "dimensions": .number(Double(vector.count)), "local": true, "costUsd": 0,
    ]
  }
  static func cosine(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count else { return -1 }
    var dot = 0.0
    var x = 0.0
    var y = 0.0
    for i in a.indices {
      dot += a[i] * b[i]
      x += a[i] * a[i]
      y += b[i] * b[i]
    }
    return x > 0 && y > 0 ? dot / sqrt(x * y) : -1
  }
}
extension Kernel {
  public func semanticQuery(
    _ collection: String, text: String, filters: [String: Value] = [:], limit: Int = 20,
    context: RequestContext
  ) throws -> Value {
    try require(context, capability: "data.read", scope: collection)
    let query = try LocalEmbedding.embed(text)
    let language = NLLanguage(rawValue: query["language"]!.string!)
    let modelID = query["model"]!.string!
    guard let model = NLEmbedding.sentenceEmbedding(for: language) else {
      throw HostError("unavailable", "Local model unavailable")
    }
    let vector = query["vector"]!.array!.compactMap(\.number)
    let rows = try db.query(
      "SELECT * FROM records WHERE collection=? AND deleted=0 ORDER BY id LIMIT 10001",
      [.string(collection)])
    guard rows.count <= 10000 else {
      throw HostError("too_large", "Semantic query supports at most 10000 records per collection")
    }
    let characters = Array(text.lowercased())
    let terms: Set<String> =
      language == .simplifiedChinese || language == .traditionalChinese
      ? Set(zip(characters, characters.dropFirst()).map { String([$0.0, $0.1]) })
      : Set(
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    var ranked: [(Record, Double)] = []
    for row in rows {
      let record = try record(row)
      guard filters.allSatisfy({ Self.matches(record.value[$0.key], $0.value) }) else { continue }
      let content = String(
        record.fields.sorted(by: { $0.key < $1.key }).compactMap { $0.value.string }.joined(
          separator: "\n"
        ).prefix(12000))
      let cached = try db.query(
        "SELECT vector FROM embeddings WHERE collection=? AND id=? AND rev=? AND model=?",
        [.string(collection), .string(record.id), .number(Double(record.rev)), .string(modelID)]
      ).first
      let embedded: [Double]
      if let json = cached?["vector"]?.string {
        embedded = try Value.parse(json).array!.compactMap(\.number)
      } else {
        guard let values = model.vector(for: content), !content.isEmpty else { continue }
        embedded = values
        try db.execute(
          "INSERT INTO embeddings VALUES (?,?,?,?,?) ON CONFLICT(collection,id,model) DO UPDATE SET rev=excluded.rev,vector=excluded.vector",
          [
            .string(collection), .string(record.id), .string(modelID), .number(Double(record.rev)),
            .string(try Value.array(values.map(Value.number)).text()),
          ])
      }
      let coverage =
        terms.isEmpty
        ? 0 : Double(terms.filter { content.lowercased().contains($0) }.count) / Double(terms.count)
      ranked.append((record, 0.7 * LocalEmbedding.cosine(vector, embedded) + 0.3 * coverage))
    }
    let result = ranked.sorted { $0.1 > $1.1 }.prefix(min(max(limit, 1), 100))
    for (record, _) in result { try propagate(record.labels, to: context) }
    try audit(
      "data.semanticQuery", context: context,
      detail: [
        "collection": .string(collection), "model": .string(modelID),
        "count": .number(Double(result.count)),
      ])
    return .array(
      result.map { item in
        var fields = item.0.value.object!
        fields["_score"] = .number(item.1)
        return .object(fields)
      })
  }
}
