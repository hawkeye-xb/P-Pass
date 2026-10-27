// 日志统一脱敏（按值的形状，不按字段名）——`crates/daemon/src/redact.rs` 里 `redact()`（规则 0–4）的 Swift 移植（#1152），
// 与 Android `log/Redact.kt` 同一件事：公网 IP、URL 主机名、十进制字节数组、长不透明串 / 长 hex 串。
//
// 口径锁定：`SharedRedactVectorsTests` 跑与 daemon / 桌面壳 / transport / Android 同一份 `assets/privacy/redact-vectors.json`
// （exact + keep 两段）。改规则先改向量，各份实现一起过。
//
// 移植约定（同 Kotlin 版）：字符类一律显式 ASCII；IP 只做字面量解析，逐步复刻 Rust `core::net` 解析器
// （IPv4 拒前导 0、IPv6 允许尾部内嵌 IPv4、`::` 至少代表一组）；绝不用 inet_pton / NWEndpoint 这类会碰系统解析的接口。
import Foundation

public enum SharedRedact {
    /// 统一入口：字节数组 → IP → URL 主机名 → 长串。幂等。
    public static func redact(_ s: String) -> String { maskTokens(maskUrlHosts(maskIps(maskByteArrays(s)))) }

    typealias Scalars = [Unicode.Scalar]

    private static func scalars(_ s: String) -> Scalars { Array(s.unicodeScalars) }
    private static func string(_ u: ArraySlice<Unicode.Scalar>) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: u); return String(v) }
    private static func string(_ u: Scalars) -> String { string(u[...]) }

    // MARK: ASCII 字符类
    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
    private static func isAlpha(_ c: Unicode.Scalar) -> Bool { (c.value >= 0x41 && c.value <= 0x5a) || (c.value >= 0x61 && c.value <= 0x7a) }
    private static func isAlnum(_ c: Unicode.Scalar) -> Bool { isDigit(c) || isAlpha(c) }
    private static func isHex(_ c: Unicode.Scalar) -> Bool { isDigit(c) || (c.value >= 0x41 && c.value <= 0x46) || (c.value >= 0x61 && c.value <= 0x66) }
    private static func isIpChar(_ c: Unicode.Scalar) -> Bool { isHex(c) || c == ":" || c == "." }
    private static func isWord(_ c: Unicode.Scalar) -> Bool { isAlnum(c) || c == "_" }
    private static func isTokenChar(_ c: Unicode.Scalar) -> Bool { isAlnum(c) || c == "_" || c == "-" }
    private static func isWhitespace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }

    // MARK: 规则 0：十进制字节数组（`[234, 74, 108, …]`）

    static func maskByteArrays(_ s: String) -> String {
        let u = scalars(s)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            guard u[i] == "[" else { out.append(u[i]); i += 1; continue }
            if let close = u[(i + 1)...].firstIndex(of: "]") {
                let items = string(u[(i + 1)..<close]).split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                let allBytes = items.allSatisfy { t in !t.isEmpty && t.count <= 3 && (parseU16(t) ?? 256) <= 255 }
                if items.count >= 16 && allBytes {
                    out.append(contentsOf: "[<bytes:\(items.count)>]".unicodeScalars)
                    i = close + 1
                    continue
                }
            }
            out.append("[")
            i += 1
        }
        return String(out)
    }

    /// Rust `str::parse::<u16>`：可选 `+`，其后至少一位十进制数字。
    private static func parseU16(_ t: String) -> Int? {
        let d = t.hasPrefix("+") ? String(t.dropFirst()) : t
        guard !d.isEmpty, d.unicodeScalars.allSatisfy(isDigit), let v = Int(d), v <= 0xffff else { return nil }
        return v
    }

    // MARK: 规则 1：公网 IP

    static func maskIps(_ s: String) -> String {
        let u = scalars(s)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            guard isIpChar(u[i]) else { out.append(u[i]); i += 1; continue }
            var j = i
            while j < u.count && isIpChar(u[j]) { j += 1 }
            let prev: Unicode.Scalar? = i > 0 ? u[i - 1] : nil
            let next: Unicode.Scalar? = j < u.count ? u[j] : nil
            out.append(contentsOf: maskIpRun(Array(u[i..<j]), prev: prev, next: next).unicodeScalars)
            i = j
        }
        return String(out)
    }

    private static func maskIpRun(_ run: Scalars, prev: Unicode.Scalar?, next: Unicode.Scalar?) -> String {
        // 紧贴着字母数字的不是独立的地址（`noq_proto::connection`、`0.58s`、`T01:49:50.5`）。
        if let next, isWord(next) { return string(run) }
        let lead = run.prefix { $0 == ":" }.count
        var coreEnd = run.count
        while coreEnd > lead, run[coreEnd - 1] == "." || run[coreEnd - 1] == ":" { coreEnd -= 1 }
        let coreTrimmed = Array(run[lead..<coreEnd])
        let trail = run.count - lead - coreTrimmed.count
        for (ld, core, tr) in [(0, run, 0), (lead, coreTrimmed, trail)] {
            let effectivePrev: Unicode.Scalar? = ld > 0 ? ":" : prev
            if let effectivePrev, isWord(effectivePrev) { continue }
            if core.isEmpty { continue }
            guard let rep = classifyIp(core) else { continue }
            return string(run[0..<ld]) + rep + string(run[(run.count - tr)...])
        }
        return string(run)
    }

    private static func classifyIp(_ core: Scalars) -> String? {
        if let v6 = parseIpv6(core) { return v6IsPublic(v6) ? "<ipv6:public>" : string(core) }
        if let v4 = parseIpv4(core) { return v4IsPublic(v4) ? "<ipv4:public>" : string(core) }
        guard let colon = core.lastIndex(of: ":") else { return nil }
        let addr = Array(core[0..<colon])
        let port = core[(colon + 1)...]
        guard !port.isEmpty, port.count <= 5, port.allSatisfy(isDigit), let v4 = parseIpv4(addr) else { return nil }
        return v4IsPublic(v4) ? "<ipv4:public>:\(string(port))" : string(core)
    }

    private static func v4IsPublic(_ o: [Int]) -> Bool {
        let privateNet = o[0] == 10 || (o[0] == 172 && (o[1] & 0xf0) == 16) || (o[0] == 192 && o[1] == 168)
        let loopback = o[0] == 127
        let linkLocal = o[0] == 169 && o[1] == 254
        let unspecified = o.allSatisfy { $0 == 0 }
        let broadcast = o.allSatisfy { $0 == 255 }
        let multicast = (o[0] & 0xf0) == 224
        let cgnat = o[0] == 100 && (o[1] & 0xc0) == 64
        return !(privateNet || loopback || linkLocal || unspecified || broadcast || multicast || cgnat)
    }

    private static func v6IsPublic(_ seg: [Int]) -> Bool {
        let mapped = (0...4).allSatisfy { seg[$0] == 0 } && seg[5] == 0xffff
        if mapped { return v4IsPublic([seg[6] >> 8, seg[6] & 0xff, seg[7] >> 8, seg[7] & 0xff]) }
        let loopback = (0...6).allSatisfy { seg[$0] == 0 } && seg[7] == 1
        let unspecified = seg.allSatisfy { $0 == 0 }
        let multicast = (seg[0] & 0xff00) == 0xff00
        let uniqueLocal = (seg[0] & 0xfe00) == 0xfc00
        let linkLocal = (seg[0] & 0xffc0) == 0xfe80
        return !(loopback || unspecified || multicast || uniqueLocal || linkLocal)
    }

    /// Rust `Ipv4Addr::from_str`：四段十进制，每段 1–3 位、≤255、无前导 0。返回四个八位组。
    static func parseIpv4(_ s: String) -> [Int]? { parseIpv4(scalars(s)) }
    static func parseIpv4(_ s: Scalars) -> [Int]? {
        var p = IpParser(s)
        guard let v = p.readIpv4(), p.done else { return nil }
        return v
    }

    /// Rust `Ipv6Addr::from_str`（无方括号、无 zone）。返回八个 16 位段。
    static func parseIpv6(_ s: String) -> [Int]? { parseIpv6(scalars(s)) }
    static func parseIpv6(_ s: Scalars) -> [Int]? {
        var p = IpParser(s)
        guard let v = p.readIpv6(), p.done else { return nil }
        return v
    }

    /// 逐步复刻 `core::net::parser::Parser`：贪心、原子回滚、不回溯其它分支。
    private struct IpParser {
        let s: Scalars
        var pos = 0
        init(_ s: Scalars) { self.s = s }
        var done: Bool { pos == s.count }

        private mutating func atomically<T>(_ block: (inout IpParser) -> T?) -> T? {
            let saved = pos
            let r = block(&self)
            if r == nil { pos = saved }
            return r
        }

        private mutating func readGivenChar(_ c: Unicode.Scalar) -> Bool {
            if pos < s.count && s[pos] == c { pos += 1; return true }
            return false
        }

        private func digitOf(_ c: Unicode.Scalar, radix: Int) -> Int? {
            switch c.value {
            case 0x30...0x39: return Int(c.value) - 0x30
            case 0x61...0x66 where radix == 16: return Int(c.value) - 0x61 + 10
            case 0x41...0x46 where radix == 16: return Int(c.value) - 0x41 + 10
            default: return nil
            }
        }

        private mutating func readNumber(radix: Int, maxDigits: Int, allowZeroPrefix: Bool, max: Int) -> Int? {
            atomically { p in
                var result = 0, count = 0
                let leadingZero = p.pos < p.s.count && p.s[p.pos] == "0"
                var ok = true
                while p.pos < p.s.count {
                    guard let d = p.digitOf(p.s[p.pos], radix: radix) else { break }
                    p.pos += 1
                    result = result * radix + d
                    count += 1
                    if result > max || count > maxDigits { ok = false; break }
                }
                if !ok || count == 0 { return nil }
                if !allowZeroPrefix && leadingZero && count > 1 { return nil }
                return result
            }
        }

        private mutating func readSeparator<T>(_ sep: Unicode.Scalar, _ index: Int, _ inner: (inout IpParser) -> T?) -> T? {
            atomically { p in
                if index > 0 && !p.readGivenChar(sep) { return nil }
                return inner(&p)
            }
        }

        mutating func readIpv4() -> [Int]? {
            atomically { p in
                var out = [Int](repeating: 0, count: 4)
                for i in 0..<4 {
                    guard let n = p.readSeparator(".", i, { $0.readNumber(radix: 10, maxDigits: 3, allowZeroPrefix: false, max: 255) }) else { return nil }
                    out[i] = n
                }
                return out
            }
        }

        /// 返回 (读到的段数, 是否以内嵌 IPv4 结尾)。
        private mutating func readGroups(_ groups: inout [Int], limit: Int) -> (Int, Bool) {
            for i in 0..<limit {
                if i < limit - 1 {
                    if let v4 = readSeparator(":", i, { $0.readIpv4() }) {
                        groups[i] = (v4[0] << 8) | v4[1]
                        groups[i + 1] = (v4[2] << 8) | v4[3]
                        return (i + 2, true)
                    }
                }
                guard let g = readSeparator(":", i, { $0.readNumber(radix: 16, maxDigits: 4, allowZeroPrefix: true, max: 0xffff) }) else { return (i, false) }
                groups[i] = g
            }
            return (limit, false)
        }

        mutating func readIpv6() -> [Int]? {
            atomically { p in
                var head = [Int](repeating: 0, count: 8)
                let (headSize, headIpv4) = p.readGroups(&head, limit: 8)
                if headSize == 8 { return head }
                if headIpv4 { return nil }
                guard p.readGivenChar(":"), p.readGivenChar(":") else { return nil }
                var tail = [Int](repeating: 0, count: 7)
                let (tailSize, _) = p.readGroups(&tail, limit: 8 - (headSize + 1))
                for k in 0..<tailSize { head[8 - tailSize + k] = tail[k] }
                return head
            }
        }
    }

    // MARK: 规则 2：URL 主机名

    /// 白名单：n0 的 relay / 发现服务（`*.iroh.link`）与 GitHub（更新检查）。其余一律 `<host>`。
    private static let allowedHosts = ["iroh.link", "github.com", "githubusercontent.com"]
    private static let schemes = ["https://", "http://", "wss://", "ws://"]
    private static let hostTerminators = Set("/:?#<>\"'()[]{},;&\\".unicodeScalars)

    private static func hostAllowed(_ host: String) -> Bool {
        var h = host.unicodeScalars.map { $0.value >= 0x41 && $0.value <= 0x5a ? Character(Unicode.Scalar($0.value + 32)!) : Character($0) }
        while h.last == "." { h.removeLast() }
        let lower = String(h)
        return allowedHosts.contains { lower == $0 || lower.hasSuffix("." + $0) }
    }

    static func maskUrlHosts(_ s: String) -> String {
        let u = scalars(s)
        let schemeScalars = schemes.map { scalars($0) }
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            // 同一位置最短的 scheme 优先（`http://` 先于 `https://` 只因更短；rest.indexOf 的最左 + 同位置取短）。
            var best: Scalars?
            for sc in schemeScalars where i + sc.count <= u.count && Array(u[i..<(i + sc.count)]) == sc {
                if best == nil || sc.count < best!.count { best = sc }
            }
            guard let scheme = best else { out.append(u[i]); i += 1; continue }
            out.append(contentsOf: scheme)
            i += scheme.count
            var j = i
            while j < u.count && !isWhitespace(u[j]) && !hostTerminators.contains(u[j]) { j += 1 }
            let host = string(u[i..<j])
            out.append(contentsOf: (host.isEmpty || hostAllowed(host) ? host : "<host>").unicodeScalars)
            i = j
        }
        return String(out)
    }

    // MARK: 规则 3 + 4：长不透明串 / 长 hex 串只留前 8 位

    private static let mask = "…<masked>"

    private static func isOpaque(_ run: ArraySlice<Unicode.Scalar>) -> Bool {
        run.count >= 32 && run.filter(isDigit).count >= 2 && run.filter(isAlpha).count >= 8
    }

    static func maskTokens(_ s: String) -> String {
        let u = scalars(s)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            guard isTokenChar(u[i]) else { out.append(u[i]); i += 1; continue }
            var j = i
            while j < u.count && isTokenChar(u[j]) { j += 1 }
            let run = u[i..<j]
            if isOpaque(run) || (run.allSatisfy(isHex) && run.count >= 24) {
                out.append(contentsOf: run.prefix(8)); out.append(contentsOf: mask.unicodeScalars)
            } else {
                out.append(contentsOf: maskHexSubruns(run).unicodeScalars)
            }
            i = j
        }
        return String(out)
    }

    /// 不够"不透明"的串里嵌着的 ≥24 位 hex（`node_<24hex>`）仍然要打码。
    private static func maskHexSubruns(_ run: ArraySlice<Unicode.Scalar>) -> String {
        var out = String.UnicodeScalarView()
        var i = run.startIndex
        while i < run.endIndex {
            guard isHex(run[i]) else { out.append(run[i]); i += 1; continue }
            var j = i
            while j < run.endIndex && isHex(run[j]) { j += 1 }
            if j - i >= 24 { out.append(contentsOf: run[i..<(i + 8)]); out.append(contentsOf: mask.unicodeScalars) } else { out.append(contentsOf: run[i..<j]) }
            i = j
        }
        return String(out)
    }
}
