# infra/workers/update

Update manifest (T-062): a static JSON file + detached Ed25519 signature that
clients poll to learn whether a newer P-Pass exists. Served on Cloudflare
Pages or a Worker (or any static host — it is deliberately boring). Format and
signing convention are defined here; the client-side read/verify logic lives
in `crates/daemon/src/update.rs` (pure functions, unit-tested). The fetch
loop + release pipeline land with T-071.

更新清单（T-062）：静态 JSON + 分离式 Ed25519 签名，客户端轮询以获知是否有新版本。
托管在 Cloudflare Pages 或 Worker（或任意静态主机——刻意保持无聊）。格式与签名约定
在此定义；客户端读取/验签逻辑在 `crates/daemon/src/update.rs`（纯函数，单测覆盖）。
抓取循环与发布管线归 T-071。

## File layout / 文件布局

```
<update-endpoint>/
├── manifest.json          # the manifest (below)
└── manifest.json.sig      # detached Ed25519 signature over manifest.json bytes
```

## Manifest format / 清单格式

```json
{
  "version": "0.2.0",
  "notes": "what changed",
  "pub_date": "2026-07-31T00:00:00Z",
  "platforms": {
    "macos-arm64":  { "url": "…", "sha256": "<64 hex>", "signature": "<base64>" },
    "macos-x64":    { "url": "…", "sha256": "<64 hex>", "signature": "<base64>" },
    "windows-x64":  { "url": "…", "sha256": "<64 hex>", "signature": "<base64>" },
    "linux-x64":    { "url": "…", "sha256": "<64 hex>", "signature": "<base64>" },
    "linux-arm64":  { "url": "…", "sha256": "<64 hex>", "signature": "<base64>" }
  }
}
```

- `version` — SemVer of the offered update. Clients compare against their own
  version with strict SemVer rules (pre-releases sort below releases).
- `platforms` — keys are `{os}-{arch}` with the canonical arch names
  `arm64` / `x64` (map from Rust's `aarch64` / `x86_64`).
- `sha256` — hex SHA-256 of the artifact; validated at parse time (exactly
  64 hex chars) and verified after download.
- `signature` (per artifact) — base64 Ed25519 signature over the artifact
  bytes, Tauri-updater style. **Required** (T-062b): a missing or empty
  signature is a hard parse error — nothing is installable unsigned.

`version` 为 SemVer，客户端按严格 SemVer 规则比较（预发布低于正式版）。
`platforms` 键为 `{os}-{arch}`，架构名统一 `arm64`/`x64`（对应 Rust 的
`aarch64`/`x86_64`）。`sha256` 为产物十六进制 SHA-256，解析期校验（恰 64 位
hex）且下载后校验。`signature`（每个产物）为产物字节的 base64 Ed25519 签名，
Tauri-updater 风格；**必填**（T-062b）——缺失或空签名是硬解析错误，未签名
产物不可安装。

## Signing convention / 签名约定

1. Sign the **exact published bytes** of `manifest.json` — any byte change
   (whitespace, field order, a flipped bit) invalidates the signature. This is
   deliberate: the manifest is tamper-evident by construction.
2. Signature file: `manifest.json.sig`, raw 64-byte Ed25519 signature,
   base64-encoded (standard alphabet, no newline).
3. The public key is **embedded in clients** (not fetched from the network).
   Key rotation: ship a new embedded key with a signed update, keep the old
   key valid for one release cycle (详见私有仓 release runbook).
4. Per-artifact `signature` fields pin downloads: verify the artifact against
   its base64 Ed25519 signature AND the manifest `sha256`.

1. 对 `manifest.json` **发布时的精确字节**签名——任何字节变化（空白、字段顺序、
   翻转一位）都会使签名失效。这是刻意的：清单天然防篡改。
2. 签名文件 `manifest.json.sig`：64 字节 Ed25519 原始签名，base64 编码
   （标准字母表，无换行）。
3. 公钥**内嵌在客户端**（不从网络获取）。轮换：随一次已签名更新发布新内嵌公钥，
   旧公钥保留一个发布周期（详见私有仓 release runbook）。
4. 每个产物的 `signature` 字段钉死下载：下载后同时校验 base64 Ed25519 签名
   与清单 `sha256`。

## Deploy note / 部署说明

Nothing here is secret — the endpoint serves public JSON. Deploy the two files
to any static host; Cloudflare Pages with `cache-control: max-age=300` is the
planned production home (so a bad manifest is never cached longer than the
client poll interval). Production config lives in the private ops repo.

这里没有任何秘密——端点只服务公开 JSON。两个文件部署到任意静态主机即可；
计划生产环境为 Cloudflare Pages，`cache-control: max-age=300`（坏清单不会被缓存
超过客户端轮询间隔）。生产配置在私有仓。

## Client contract / 客户端契约

`crates/daemon/src/update.rs` provides (pure, unit-tested):

- `Manifest::parse(bytes)` — strict parse, unknown fields rejected
- `is_newer(current, candidate)` — strict SemVer comparison
- `verify_manifest(bytes, sig, pubkey)` — Ed25519 verify (strict)
- `verify_artifact(bytes, artifact, pubkey)` — SHA-256 digest + per-artifact
  Ed25519 signature, both enforced (T-062b)
- `check_update(manifest, sig, pubkey, current, os, arch)` — verify → parse →
  newer? → platform artifact, returns `UpdateInfo` or `None`

`crates/daemon/src/update.rs` 提供（纯函数，单测覆盖）：`Manifest::parse`（严格
解析，未知字段拒绝）、`is_newer`（严格 SemVer 比较）、`verify_manifest`
（Ed25519 严格验签）、`verify_artifact`（SHA-256 摘要 + 逐工件 Ed25519 签名，
双强制，T-062b）、`check_update`（验签→解析→比较→平台产物，返回
`UpdateInfo` 或 `None`）。
