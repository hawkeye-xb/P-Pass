# FIX-SC1 testclient 配对解析器没跟上 &r= QR 格式　级别 L1

## blocker（2026-08-10 巡检定位，scenarios job 自 8/8 起 15+ run 全红）

H-10b（8/8）把 daemon 的配对 QR 从 `&a=<完整 PeerAddr>`（100-180 字符
base64，太密扫不出）改成 `&r=<relay URL>`（~30 字符明文），Android 端
同步改了 `parsePairingQr` 重建地址 token。但 **tools/testclient/src/main.rs
的 `pair()` 解析器没跟上**：

```rust
let (token, addr_token) = match rest.split_once("&a=") {
    Some((t, a)) => (t, Some(a)),
    None => (rest, None),   // ← 现在 QR 是 ...&t=<token>&r=<relay>
};                          //   split_once("&a=") 恒 None → token 吞进
                            //   &r= 尾巴 → 坏 token → pair.request 被拒
```

CI 实测（huge_file.sh 第 40 行，run 31351715951）：
`{"id": "x", "ok": false, "error": {"code": "NOT_FOUND", "msg_key": "err.unsupported"}}`
——testclient 带坏 token 的 pair.request 被 daemon 拒（或 token 不匹配），
confirm 队列空，`pairing.confirm` 回 err.unsupported → 脚本 exit 1。

为什么一直没炸在别处：Android 真机走自己的 Kotlin 解析器（已改），
e2e 剧本（DaemonPairTest）用 Kotlin 侧 pairWithQr 或本地构造 token，
唯独 Rust testclient 是唯一还依赖 `&a=` 的消费者，而它只在 scenarios/
dogfood 剧本里跑——所以 8/8 之后所有 CI 的 scenarios job 全红，无人
追查（验收人本地全量复验不含 scenarios？NEXT 记 219/219 Rust 是 nextest，
scenarios 是进程级剧本，独立 job）。

## 修法

1. testclient `pair()` 解析器加 `&r=` 分支：`split_once("&r=")` → relay
   URL 拼回 PeerAddr token（与 Android `buildAddrToken` 同语义：node +
   relay → addr token），`&a=` 旧格式保留兼容（老 QR/旧 daemon 还在用）。
   最简做法：读到 r 后用 transport 的 PeerAddr 构造（node id + relay url）
   或直接 `add_peer` 一个仅 relay 的 addr——参照 Android 端实现。
2. 若 transport 没有现成的「node + relay → PeerAddr」构造，看
   `crates/transport` 有没有 `PeerAddr::from_parts` 之类；没有就在
   transport 加最小构造器（Android FFI 同款语义，金样本随行）。
3. 反证：构造一个只有 `&r=` 的新格式 QR 串喂给 pair() 解析 → token
   必须正确提取（不吞 &r= 尾巴）；再喂旧 `&a=` 格式 → 仍能解析。

## 可执行验收

1. 单测（testclient 解析器若可测则加；否则集成）：
   `ppf://pair?node=<64hex>&t=<24hex>&r=https://relay.example` →
   token == 24hex、addr 含 relay；`&a=` 旧格式 → addr 含完整 PeerAddr。
2. 本地跑 `tools/scenarios/huge_file.sh`（PPF_SCENARIO_SIZE 用小值如 64M
   省时）→ 配对段通过（不再 err.unsupported）。
3. scenarios job 绿（pr.yml 的 T-070 job）。

## 反证

把解析器改回只认 `&a=` → 新格式 QR 的 token 提取必坏（贴输出后还原）。

## 证据要求

测试输出摘录 + scenarios 本地跑通日志。

## 收尾

直推 main 前确认 CI 绿（重点盯 scenarios job）；PROGRESS/NEXT 各留一
行；卡移 done/ 并附验收记录。

---
✅ **验收记录（2026-08-10，Salamira）**：
- 实现：`tools/testclient/src/main.rs` 新增 `parse_pair_qr`（新格式
  `&r=` → `build_addr_token` 重建 PeerAddr token，node+relay → base64url
  JSON，与 Android `buildAddrToken` 逐字段一致；旧格式 `&a=` 原样透传；
  无地址段 → None）+ `build_addr_token`。testclient/Cargo.toml 加
  base64 = "0.22"（与 transport 同版本）。
- 单测 5 个新增（7 个全绿）：`parse_pair_qr_new_relay_format_extracts_token`
  （&r= token 不被污染 + 重建 token 能被 PeerAddr 反序列化 + relay host
  匹配）、`parse_pair_qr_legacy_addr_format_still_works`（&a= 透传）、
  `parse_pair_qr_no_addr_segment_is_ok`（None）、
  `parse_pair_qr_bad_prefix_is_rejected`（坏串拒绝）、
  `build_addr_token_roundtrips_through_peer_addr`（node+relay → PeerAddr
  往返一致）。
- ⚠️ 测试陷阱：node hex 必须用真实公钥（`node_id_from_secret_key`）——
  PublicKey::from_str 校验曲线点，假 hex（"ab".repeat(32)）→ InvalidNodeId。
- 本地 scenarios 实证：`huge_file.sh`（64M）**ALL GREEN**（配对通过 →
  64M 备份 → 落盘校验 → 幂等重跑）+ `crash_recovery.sh` **ALL GREEN**
  （disk_full 平台跳过属预期）。
- fmt/clippy 绿；Cargo.lock 同步（+base64）。
