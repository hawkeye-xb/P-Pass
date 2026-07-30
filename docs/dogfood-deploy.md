# Dogfood deployment / 狗粮机部署手册

Deploy the P-Pass daemon in production shape on a home machine and
validate it through the interface scenario — fully command-line,
agent-executable. Validated cross-internet on 2026-07-30 (Aliyun ×
office Mac, full scenario green).

在家用机器上以生产形态跑起 P-Pass daemon，并用接口剧本验收。全程命令行，
agent 可执行。2026-07-30 已跨公网双机验证全绿（阿里云×办公 Mac）。

## 0. Prerequisites / 前置

**macOS (Apple Silicon)** — no Rust, no compiling needed / 无需 Rust、无需编译:

```bash
# git comes with Xcode CLT (first `git` run prompts install)
# Homebrew: https://brew.sh (if missing)
brew install libheif        # HEIC decoding (hard requirement / 硬依赖)
brew install ffmpeg         # video thumbnails (optional / 可选,缺则视频给占位图)
```

**Linux (x86_64)**:

```bash
sudo apt-get install -y --no-install-recommends libheif-dev libheif-plugin-libde265 ffmpeg
```

Network notes / 网络注意（H-04 实证教训）:
- Run on the host directly, **never inside a VM** (double NAT kills
  direct connections). / 宿主机直跑，**别进虚拟机**（双层 NAT 毁直连）。
- No global VPN/TUN on the box; a clean Wi-Fi machine is ideal.
  / 机器上别开全局 VPN/TUN；干净连家庭 WiFi 的机器最理想。

## 1. Get prebuilt binaries / 拿预构建二进制（免编译）

```bash
# macOS Apple Silicon:
git clone --depth 1 -b bin-macos-arm64 https://github.com/hawkeye-xb/P-Pass.git ppf-bin
# Linux x86_64:
#   git clone --depth 1 -b bin-linux-x64 https://github.com/hawkeye-xb/P-Pass.git ppf-bin
cd ppf-bin && shasum -c SHA256SUMS && chmod +x daemon testclient && cat BUILD_INFO
```

## 2. Start the daemon / 启动

```bash
mkdir -p ~/ppf-library
PPF_DATA_DIR=~/ppf-library \
PPF_TELEMETRY_ENABLED=false \
PPF_RELAY_URLS="" \
  nohup ./daemon > ~/ppf-daemon.log 2> ~/ppf-daemon.err &
sleep 3 && cat ~/ppf-daemon.log
```

> `PPF_RELAY_URLS=""` is **required** until H-07 ships: the built-in
> official relay domains are not deployed yet and poison path
> negotiation (dogfood smoke #1 finding). This falls back to n0's
> public relays. / 在 H-07 部署前**必须**设置：内置官方 relay 域名尚未
> 部署，留着会毒害连接协商（冒烟 #1 实证）；置空回落到 n0 公共 relay。

Record from the startup output / 记下启动输出里的三样:
1. `NodeId: <64hex>` — the storage identity / 存储端身份
2. `ppf://pair?...` — pairing string (address included, 10 min TTL)
   / 配对串（含地址，10 分钟有效）
3. the `ipc.token` path — local admin credential / 本机管理凭证

## 3. Same-machine smoke / 本机冒烟（第一道验收）

```bash
./dogfood-smoke.sh /tmp/ppf-smoke
# expect the last line / 期望最后一行: DOGFOOD SMOKE: ALL GREEN
```

## 4. Cross-network scenario / 跨网双机验收

From the remote client machine (e.g. the office Mac) with the pairing
string from step 2 / 远端客户端（如办公 Mac）拿第 2 步的配对串:

```bash
./testclient pair --token '<ppf://pair?...>' --name 'office-mac'
# → on the daemon box, confirm over IPC / 存储端上经 IPC 确认:
#   macOS socket:  /tmp/<line1 of ipc.token>
#   Linux socket:  abstract namespace, connect("\0"+name)
#   first line = token, then:
#   {"id":"c","method":"pairing.confirm","params":{"accept":true}}
./testclient backup --files 200 --node <NodeId>
./testclient backup --files 200 --node <NodeId>   # idempotent: missing 0
./testclient browse --limit 50 --node <NodeId>
```

Acceptance (same as dogfood-smoke.sh) / 验收标准（与冒烟脚本同源）:
- pairing lands a whitelist row; backups dedup (run 1 ingests the
  deduped count, run 2 transfers nothing); browse paginates with no
  repeats and thumbnails decode; after IPC `device.revoke`,
  `revoke-check` reports a correct rejection.

Known cross-network caveat / 已知跨网注意: at daemon boot the QR's
`&a=` may contain only LAN/IPv6 addresses. Same-Wi-Fi clients connect
directly; clients on other networks rely on hole punching via the n0
relays, which needs both ends to reach them. If pairing times out
cross-network, that is the H-07 (self-hosted relay) motivation, not a
code bug — retry from the same Wi-Fi to isolate. / daemon 刚启动时 QR
地址段可能只含内网/IPv6 地址。同 WiFi 客户端直连即可；跨网客户端依赖
n0 relay 协调打洞。若跨网配对超时，那是 H-07（自建 relay）的动力而非
代码 bug——可先在同 WiFi 复测以隔离变量。

## 5. Operations / 运维备忘

- Crash/restart: library + index survive (ADR-006 guarded); pairing
  whitelist persists. QR & IPC tokens are re-minted per launch.
  / 崩溃重启：库与索引无恙，白名单在库里；QR 与 IPC 令牌每次启动新发。
- Logs: `RUST_LOG=debug` for connection detail; `logs.export` over IPC
  produces a sanitized zip safe to share. / 日志与脱敏诊断包。
- Update: `git -C ppf-bin pull` (binaries branch is rebuilt on every
  push to main). / 更新：产物分支随主干自动重建，pull 即新版。
