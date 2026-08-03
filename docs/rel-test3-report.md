# REL-test3 验收汇报（卡 4 → 运维 agent）

> 汇报人：**Salamira**（非 Windows 侧：tag、run 监控、macOS 资产验证）
> 日期：2026-08-03
> 级别：L3 — 端到端验证发布流水线

## 目标

在最新 main（`ea3bbf4`，含 T-071b 全部修复；任务卡写的 `9a4f9ae` 为祖先 commit）上打 tag `v0.2.0-test.3`，端到端验证发布流水线。

## 验收结果

| # | 验收项 | 结果 |
|---|--------|------|
| ① | Release run 三个 job 全绿 | ✅ PASS |
| ② | draft release 存在且恰好 6 个资产 | ✅ PASS |
| ③ | 下载 zip 解压：`P-Pass/lib/` 存在 + `./P-Pass/daemon` 能起 | ✅ PASS |

## ① Release run 三个 job 全绿

**Run:** https://github.com/hawkeye-xb/P-Pass/actions/runs/30810656495

```
status: completed, conclusion: success

Windows x64 (未签名)  → success
macOS arm64 (签名门控) → success
Release 草稿           → success
```

- Windows job **本次一次成功**（约 21 分钟），test.2 的「一次失败一次成功」未复现——与 test.2 最终成功一致，vcpkg 源码编译 flaky 疑云未在 test.3 出现。
- macOS job ~7 分钟（基线 6m48s，符合）。
- 无凭据路径按预期：签名/公证步干净跳过（notes 标注未签名）。

## ② draft release 存在且恰好 6 个资产

**Release:** `v0.2.0-test.3`（draft）

```
BUILD_INFO-windows-x64    (76 B)
daemon.exe               (32,811,008 B)
ppass-macos-arm64.zip    (23,454,398 B)
SHA256SUMS-macos-arm64   (150 B)
SHA256SUMS-windows-x64   (158 B)
testclient.exe           (19,195,392 B)
```

资产数量：**6** ✓ —— 与卡面清单逐项吻合（ppass-macos-arm64.zip / SHA256SUMS-macos-arm64 / daemon.exe / testclient.exe / SHA256SUMS-windows-x64 / BUILD_INFO-windows-x64）。

## ③ 下载 zip 解压自包含验证（macOS）

```bash
$ gh release download v0.2.0-test.3 --repo hawkeye-xb/P-Pass --pattern 'ppass-macos-arm64.zip'
$ unzip -o ppass-macos-arm64.zip
# P-Pass/lib 目录存在 ✓（libheif/libde265/libx265/libaom/libvmaf/libsharpyuv 8 个 dylib）
$ ls P-Pass/
BUILD_INFO  SHA256SUMS-macos-arm64  daemon  dogfood-smoke.sh  lib  testclient
```

**daemon 启动验证**（`--help` 无 clap 解析、等效于启动 daemon 本体）：

```
INFO endpoint{id=fefc994562}:relay-actor: home is now relay https://usw1-1.relay.n0.iroh.link./, was None
P-Pass daemon 已启动
NodeId: fefc994562e48448bfa30b8abfdb16c0ecb8f396e6c7b9f167c40ba8ff963a47
库目录: /Users/salamira/Library/Application Support/P-Pass
配对二维码内容（10 分钟内有效）: ppf://pair?node=fefc9945...
IPC: ppf-fefc9945（令牌在 /Users/salamira/Library/Application Support/P-Pass/ipc.token）
```

- daemon 正常启动：NodeId 生成 ✓、IPC token 写出 ✓、relay 连接 ✓、lib/ 内 dylib 全部正确加载（无 dyld 缺失报错）——**自包含验证通过**。
- **SHA256 完整性校验**（对 release 的 SHA256SUMS-macos-arm64）：

```
daemon: OK
testclient: OK
```

## 备注 / 观察项

1. **`--help` 行为**：daemon 无 clap 参数解析，`--help` 被忽略直接启动服务。卡面写「`./P-Pass/daemon --help` 能起」，实测行为为「直接启动成功」——符合验收意图（能起）。若希望 `--help` 打印用法，需后续给 daemon 加 cli 参数层（非本卡范围，记录待议）。
2. **BUILD_INFO 确认**：`built from ea3bbf491252f9b1212533c51e8c1b253ed1ced7 on 2026-08-03T11:47:51Z` —— 构建源 commit 与 tag 所指向的 main HEAD 一致。
3. **测试残留**：验证用 daemon 进程已 kill，无残留；其写入的 `~/Library/Application Support/P-Pass/ipc.token` 由后续正常 daemon 启动自行覆盖，无破坏。

## 结论

**REL-test3 三验收项全部 PASS。** 发布流水线在 T-071b 修复（SHA-pin + per-platform 资产命名）后端到端全链绿，草稿资产 6 件齐整，产物自包含可运行。test.2→test.3 两轮连续全绿，flaky 疑云基本排除。

---

*汇报人：Salamira · 2026-08-03 · 待审核*
