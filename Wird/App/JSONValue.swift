import Foundation

/// A JSON value. The library is kept in the same shape the web app wrote (state.json), so every field it ever had
/// survives, even ones this version does not show, and a backup stays readable by the Android app.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: reading

    var string: String? { if case .string(let s) = self { return s }; if case .number(let n) = self { return JSONValue.format(n) }; return nil }
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var int: Int? { double.flatMap { $0.isFinite ? Int($0) : nil } }
    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .null: return false
        default: return true
        }
    }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    /// JavaScript truthiness: null, false, 0, "" are false.
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        default: return true
        }
    }

    subscript(key: String) -> JSONValue? {
        get { object?[key] }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    static func format(_ n: Double) -> String {
        n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    }

    // MARK: to and from Foundation objects (JSONSerialization is much faster than Codable for big trees)

    init(any v: Any?) {
        switch v {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n.rounded() == n && abs(n) < 9e15 ? NSNumber(value: Int64(n)) : NSNumber(value: n)
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    static func parse(_ data: Data) -> JSONValue? {
        guard let o = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: o)
    }

    func data(pretty: Bool = false) -> Data? {
        try? JSONSerialization.data(withJSONObject: any, options: pretty ? [.prettyPrinted, .fragmentsAllowed] : [.fragmentsAllowed])
    }
}

typealias JSONObject = [String: JSONValue]

extension Dictionary where Key == String, Value == JSONValue {
    func str(_ k: String, _ d: String = "") -> String { self[k]?.string ?? d }
    func num(_ k: String, _ d: Double = 0) -> Double { self[k]?.double ?? d }
    func int(_ k: String, _ d: Int = 0) -> Int { self[k]?.int ?? d }
    func bool(_ k: String, _ d: Bool = false) -> Bool { self[k].map { $0.truthy } ?? d }
    func optNum(_ k: String) -> Double? { guard let v = self[k], !v.isNull else { return nil }; return v.double }
    func optStr(_ k: String) -> String? { guard let v = self[k], !v.isNull else { return nil }; return v.string }
    func arr(_ k: String) -> [JSONValue] { self[k]?.array ?? [] }
    func obj(_ k: String) -> JSONObject { self[k]?.object ?? [:] }
    func strs(_ k: String) -> [String] { arr(k).compactMap(\.string) }
    func objs(_ k: String) -> [JSONObject] { arr(k).compactMap(\.object) }

    mutating func set(_ k: String, _ v: String) { self[k] = .string(v) }
    mutating func set(_ k: String, _ v: Double) { self[k] = .number(v) }
    mutating func set(_ k: String, _ v: Int) { self[k] = .number(Double(v)) }
    mutating func set(_ k: String, _ v: Bool) { self[k] = .bool(v) }
    mutating func set(_ k: String, _ v: [String]) { self[k] = .array(v.map { .string($0) }) }
    mutating func set(_ k: String, optional v: Double?) { self[k] = v.map { .number($0) } ?? .null }
    mutating func set(_ k: String, optional v: String?) { self[k] = v.map { .string($0) } ?? .null }
    mutating func set(_ k: String, objects v: [JSONObject]) { self[k] = .array(v.map { .object($0) }) }
}

/// Milliseconds since 1970, the way the web app keeps times.
enum Millis {
    static var now: Double { (Date().timeIntervalSince1970 * 1000).rounded() }
    static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
    static func ms(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded() }
}

/// The web app's short random ids (base 36), so new items look like the old ones.
func uid() -> String {
    let t = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
    let r = String(UInt32.random(in: 0...UInt32.max), radix: 36)
    return t + r
}
