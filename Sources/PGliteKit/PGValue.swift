import Foundation

/// A parameter value, encoded on the wire in text format (the server casts
/// from text to the inferred/declared parameter type).
public enum PGValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case bytes(Data)
    case uuid(UUID)
    case date(Date)
    /// pgvector literal, e.g. `[1.0, 2.0, 3.0]`
    case vector([Float])

    var textValue: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "t" : "f"
        case .bytes(let d): return "\\x" + d.map { String(format: "%02x", $0) }.joined()
        case .uuid(let u): return u.uuidString.lowercased()
        case .date(let d): return Self.timestampFormatter.string(from: d)
        case .vector(let v):
            return "[" + v.map { String($0) }.joined(separator: ",") + "]"
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// Ergonomics: let callers pass literals directly.
extension PGValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

public struct PGColumn: Sendable, Equatable {
    public let name: String
    public let typeOid: UInt32
}

/// One result row; values arrive in text format and decode on access.
public struct PGRow: Sendable {
    public let columns: [PGColumn]
    let values: [Data?]
    private let index: [String: Int]

    init(columns: [PGColumn], values: [Data?], index: [String: Int]) {
        self.columns = columns
        self.values = values
        self.index = index
    }

    public var count: Int { values.count }

    public func isNull(_ i: Int) -> Bool { values[i] == nil }

    public func text(_ i: Int) -> String? {
        values[i].flatMap { String(data: $0, encoding: .utf8) }
    }
    public func text(_ name: String) -> String? {
        index[name].flatMap { text($0) }
    }

    public func int(_ i: Int) -> Int? { text(i).flatMap(Int.init) }
    public func int(_ name: String) -> Int? { text(name).flatMap(Int.init) }

    public func double(_ i: Int) -> Double? { text(i).flatMap(Double.init) }
    public func double(_ name: String) -> Double? { text(name).flatMap(Double.init) }

    public func bool(_ i: Int) -> Bool? { text(i).map { $0 == "t" || $0 == "true" } }
    public func bool(_ name: String) -> Bool? { text(name).map { $0 == "t" || $0 == "true" } }

    public func uuid(_ name: String) -> UUID? { text(name).flatMap(UUID.init) }

    public func bytes(_ name: String) -> Data? {
        guard let t = text(name), t.hasPrefix("\\x") else { return nil }
        var d = Data()
        var it = t.dropFirst(2).makeIterator()
        while let hi = it.next(), let lo = it.next(),
              let h = hi.hexDigitValue, let l = lo.hexDigitValue {
            d.append(UInt8(h << 4 | l))
        }
        return d
    }

    /// Decode a pgvector text literal `[1,2,3]`.
    public func vector(_ name: String) -> [Float]? {
        guard let t = text(name), t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        return t.dropFirst().dropLast().split(separator: ",").compactMap {
            Float($0.trimmingCharacters(in: .whitespaces))
        }
    }
}

/// Result of one statement.
public struct PGResult: Sendable {
    public let columns: [PGColumn]
    public let rows: [PGRow]
    /// CommandComplete tag, e.g. `SELECT 3`, `INSERT 0 1`.
    public let tag: String

    /// Rows affected, parsed from the command tag.
    public var rowsAffected: Int {
        Int(tag.split(separator: " ").last ?? "") ?? 0
    }
}

/// A PostgreSQL error (or fatal engine failure) surfaced to Swift.
public struct PGError: Error, CustomStringConvertible, Sendable {
    public let severity: String
    public let sqlState: String
    public let message: String
    public let detail: String?
    public let hint: String?

    public var description: String {
        var s = "\(severity): \(message) (SQLSTATE \(sqlState))"
        if let detail { s += "\nDETAIL: \(detail)" }
        if let hint { s += "\nHINT: \(hint)" }
        return s
    }

    init(fields: [Character: String]) {
        severity = fields["S"] ?? "ERROR"
        sqlState = fields["C"] ?? "XX000"
        message = fields["M"] ?? "unknown error"
        detail = fields["D"]
        hint = fields["H"]
    }

    init(engine message: String) {
        severity = "FATAL"
        sqlState = "XX000"
        self.message = message
        detail = nil
        hint = nil
    }
}
