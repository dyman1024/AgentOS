import Foundation

extension Kernel {
  public func packageLabels(_ id: String) throws -> Labels {
    guard
      let raw = try db.query("SELECT labels FROM package_labels WHERE app_id=?", [.string(id)])
        .first?["labels"]?.string
    else { return Labels() }
    return try Value.parse(raw).decode(Labels.self)
  }
  func labelPackage(_ id: String, with labels: Labels) throws {
    let combined = try packageLabels(id).union(labels)
    try db.execute(
      "INSERT INTO package_labels VALUES (?,?) ON CONFLICT(app_id) DO UPDATE SET labels=excluded.labels",
      [.string(id), .string(try Value.from(combined).text())])
  }
}
