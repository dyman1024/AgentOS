import CSQLite
import Foundation

// Confined to Kernel's actor. Never expose the connection to runtime or app code.
final class SQLiteStore: @unchecked Sendable {
  private var connection: OpaquePointer?
  private var transactionDepth = 0
  init(path: String) throws {
    guard
      sqlite3_open_v2(
        path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK
    else {
      let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
      sqlite3_close(connection)
      connection = nil
      throw HostError("storage", message)
    }
    sqlite3_busy_timeout(connection, 5000)
    try execute("PRAGMA journal_mode=WAL")
    try execute("PRAGMA foreign_keys=ON")
    try execute("PRAGMA synchronous=FULL")
  }
  deinit { sqlite3_close(connection) }
  func close() throws {
    guard let connection else { return }
    guard sqlite3_close(connection) == SQLITE_OK else { throw error() }
    self.connection = nil
  }
  func execute(_ sql: String, _ parameters: [Value] = []) throws { _ = try query(sql, parameters) }
  func query(_ sql: String, _ parameters: [Value] = []) throws -> [[String: Value]] {
    guard connection != nil else { throw HostError("storage", "Database is closed") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
      throw error()
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_bind_parameter_count(statement) == parameters.count else {
      throw HostError("storage", "Binding count mismatch")
    }
    for (offset, value) in parameters.enumerated() {
      let index = Int32(offset + 1)
      let rc: Int32
      switch value {
      case .null: rc = sqlite3_bind_null(statement, index)
      case .bool(let v): rc = sqlite3_bind_int(statement, index, v ? 1 : 0)
      case .number(let v): rc = sqlite3_bind_double(statement, index, v)
      case .string(let v):
        rc = v.withCString {
          sqlite3_bind_text(
            statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
      default:
        let text = try value.text()
        rc = text.withCString {
          sqlite3_bind_text(
            statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
      }
      guard rc == SQLITE_OK else { throw error() }
    }
    var rows: [[String: Value]] = []
    while true {
      let rc = sqlite3_step(statement)
      if rc == SQLITE_DONE { return rows }
      guard rc == SQLITE_ROW else { throw error() }
      var row: [String: Value] = [:]
      for i in 0..<sqlite3_column_count(statement) {
        let key = String(cString: sqlite3_column_name(statement, i))
        switch sqlite3_column_type(statement, i) {
        case SQLITE_INTEGER, SQLITE_FLOAT: row[key] = .number(sqlite3_column_double(statement, i))
        case SQLITE_TEXT: row[key] = .string(String(cString: sqlite3_column_text(statement, i)))
        default: row[key] = .null
        }
      }
      rows.append(row)
    }
  }
  func transaction<T>(_ body: () throws -> T) throws -> T {
    let depth = transactionDepth
    let savepoint = "nested_\(transactionDepth)"
    try execute(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
    transactionDepth += 1
    defer { transactionDepth -= 1 }
    do {
      let value = try body()
      try execute(depth == 0 ? "COMMIT" : "RELEASE SAVEPOINT \(savepoint)")
      return value
    } catch {
      try? execute(depth == 0 ? "ROLLBACK" : "ROLLBACK TO SAVEPOINT \(savepoint)")
      if depth > 0 { try? execute("RELEASE SAVEPOINT \(savepoint)") }
      throw error
    }
  }
  private func error() -> HostError {
    HostError("storage", String(cString: sqlite3_errmsg(connection)))
  }
}
