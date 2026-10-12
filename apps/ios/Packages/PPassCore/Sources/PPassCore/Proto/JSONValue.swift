// 任意 JSON 值：`Req.params` / `Resp.result` 的线上形状（Rust 侧是 `serde_json::Value`）。
//
// 数字区分整数与浮点：线上的 queue_sequence / occurred_at_ms 是 64 位整数，过 Double 会丢精度。
// 布尔与数字严格区分（`true` ≠ `1`）——契约测试靠它做全等比对，不能用 NSNumber 那种互认的相等。
import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    /// 只在超出 Int64 的正整数（u64 高位）时出现。
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let u = try? c.decode(UInt64.self) {
            self = .uint(u)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .int(i): try c.encode(i)
        case let .uint(u): try c.encode(u)
        case let .double(d): try c.encode(d)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }
}

extension JSONValue {
    /// 把一段 JSON 字节解析成 [JSONValue]（顶层允许任意值）。
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// 把一个 Encodable 编成 [JSONValue]（走与线上同一个编码器）。
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try parse(ProtoJSON.encode(value))
    }

    /// 把这个值当作 [T] 解出来（走与线上同一个解码器）。
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try ProtoJSON.decode(type, from: ProtoJSON.encode(self))
    }
}

/// 线上 JSON 的唯一编解码入口（对位 Android 的 `ProtoJson`）。
public enum ProtoJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        // 键序不影响语义；排序只为日志与调试可读、输出稳定。
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

// serde `#[serde(default)]` 的对位：缺键（或显式 null）取默认值，未知键忽略（Codable 本来就忽略）。
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

// Rust 的 `Option<T>` 不带 skip 时序列化为 `null`；Swift 合成的 encodeIfPresent 会把键省掉——两者不等。
extension KeyedEncodingContainer {
    /// 对位 `Option<T>`（无 skip）：nil 写成显式 `null`。
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}
