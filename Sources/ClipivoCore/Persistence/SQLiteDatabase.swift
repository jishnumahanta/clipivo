import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }

    /// `SQLITE_CORRUPT` / `SQLITE_NOTADB` indicate an unusable database file.
    public var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal, dependency-free wrapper over the SQLite C API.
///
/// Not thread-safe by itself: every instance is owned by exactly one actor (`ClipLibrary`).
public final class SQLiteDatabase {
    private(set) var handle: OpaquePointer?
    private var statementCache: [String: Statement] = [:]
    public let path: String

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        sqlite3_extended_result_codes(db, 1)
    }

    deinit {
        for statement in statementCache.values { statement.finalize() }
        statementCache.removeAll()
        sqlite3_close_v2(handle)
    }

    public func close() {
        for statement in statementCache.values { statement.finalize() }
        statementCache.removeAll()
        sqlite3_close_v2(handle)
        handle = nil
    }

    var lastError: SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Executes one or more SQL statements without parameters.
    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw SQLiteError(code: rc, message: message)
        }
    }

    /// Returns a prepared statement. Statements for frequently used SQL are cached.
    public func prepare(_ sql: String, cache: Bool = true) throws -> Statement {
        if cache, let cached = statementCache[sql] {
            cached.reset()
            return cached
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw lastError }
        let statement = Statement(stmt, database: self, cached: cache)
        if cache { statementCache[sql] = statement }
        return statement
    }

    @discardableResult
    public func run(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        try statement.stepToCompletion()
        return Int(sqlite3_changes(handle))
    }

    public func query<T>(_ sql: String, _ bindings: [SQLValue] = [], cache: Bool = true, map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, cache: cache)
        defer { if !cache { statement.finalize() } }
        try statement.bind(bindings)
        var results: [T] = []
        while try statement.step() {
            results.append(try map(Row(statement: statement)))
        }
        return results
    }

    public func scalarInt(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64 {
        try query(sql, bindings) { $0.int64(0) }.first ?? 0
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    public var userVersion: Int {
        get { Int((try? scalarInt("PRAGMA user_version")) ?? 0) }
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    /// Runs `body` inside an IMMEDIATE transaction, rolling back on error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func integrityCheck() -> Bool {
        (try? query("PRAGMA quick_check", cache: false) { $0.string(0) }.first) == "ok"
    }
}

public enum SQLValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public static func from(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
    public static func from(_ value: Int64?) -> SQLValue { value.map { .int($0) } ?? .null }
    public static func from(_ value: Data?) -> SQLValue { value.map { .blob($0) } ?? .null }
    public static func bool(_ value: Bool) -> SQLValue { .int(value ? 1 : 0) }
    public static func date(_ value: Date) -> SQLValue { .double(value.timeIntervalSince1970) }
}

public final class Statement {
    private var stmt: OpaquePointer?
    private unowned let database: SQLiteDatabase
    private let cached: Bool

    init(_ stmt: OpaquePointer, database: SQLiteDatabase, cached: Bool) {
        self.stmt = stmt
        self.database = database
        self.cached = cached
    }

    func finalize() {
        sqlite3_finalize(stmt)
        stmt = nil
    }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    public func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, index)
            case .int(let v): rc = sqlite3_bind_int64(stmt, index, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, index, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case .blob(let v):
                rc = v.withUnsafeBytes { buffer in
                    sqlite3_bind_blob64(stmt, index, buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1), sqlite3_uint64(v.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }
            }
            guard rc == SQLITE_OK else { throw database.lastError }
        }
    }

    /// Returns true when a row is available.
    public func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.lastError
        }
    }

    public func stepToCompletion() throws {
        while try step() {}
    }

    fileprivate var raw: OpaquePointer? { stmt }
}

public struct Row {
    fileprivate let statement: Statement

    public func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement.raw, index) == SQLITE_NULL }
    public func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement.raw, index) }
    public func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement.raw, index)) }
    public func bool(_ index: Int32) -> Bool { sqlite3_column_int64(statement.raw, index) != 0 }
    public func double(_ index: Int32) -> Double { sqlite3_column_double(statement.raw, index) }
    public func date(_ index: Int32) -> Date { Date(timeIntervalSince1970: double(index)) }

    public func string(_ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement.raw, index) else { return nil }
        return String(cString: cString)
    }

    public func data(_ index: Int32) -> Data? {
        guard sqlite3_column_type(statement.raw, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement.raw, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement.raw, index) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}
