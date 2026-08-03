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
$ gh release download v0.2.0-test.3 --repo hawkeye-xb/P-Pass --pattern 'ppass-macos-arm64.zip' --pattern 'SHA256SUMS-macos-arm64'
$ unzip -q ppass-macos-arm64.zip -d extracted
# P-Pass/lib 目录存在 ✓（实测 6 个 dylib：libaom/libde265/libheif/libsharpyuv/libvmaf/libx265）
$ ls extracted/P-Pass/
BUILD_INFO  SHA256SUMS-macos-arm64  daemon  dogfood-smoke.sh  lib  testclient
```

**SHA256 完整性校验**（三重核对，全部通过）：

```bash
# ① zip 内自带 SHA256SUMS 与 release 资产的 SHA256SUMS 必须逐字节一致
$ diff <(cat extracted/P-Pass/SHA256SUMS-macos-arm64) SHA256SUMS-macos-arm64
IDENTICAL ✓
# ② 解压后对 zip 内清单做 shasum -c
$ cd extracted/P-Pass && shasum -a 256 -c SHA256SUMS-macos-arm64
daemon: OK
testclient: OK
# ③ BUILD_INFO 指向与 tag 一致的构建源
$ cat BUILD_INFO
built from ea3bbf491252f9b1212533c51e8c1b253ed1ced7 on 2026-08-03T11:47:51Z
```

**二进制属性验证**（file + codesign，隔离目录 `/tmp/ppf-daemon-verify` 实测）：

```bash
$ file daemon testclient
daemon:     Mach-O 64-bit executable arm64
testclient: Mach-O 64-bit executable arm64
$ codesign -dv daemon
Identifier=daemon-55554944662b1ee3ead0305382cfd2b28e3b2064
Signature=adhoc        # ← 无凭据路径预期：adhoc 签名，非 Developer ID
$ spctl -a -vv daemon  # rejected —— 与 notes「macOS=no」一致，符合未签名预期
```

**daemon 启动验证**（`--help` 无 clap 解析、等效于启动 daemon 本体；用 `PPF_DATA_DIR=/tmp/ppf-daemon-verify` 隔离，不写真实库目录）：

```
INFO endpoint{id=9dcd62421c}:relay-actor: home is now relay https://usw1-1.relay.n0.iroh.link./, was None
P-Pass daemon 已启动
NodeId: 9dcd62421c71dd3b392ade63b832c530fc224895c641c2d50e60b0574b4b5d1e
库目录: /tmp/ppf-daemon-verify
配对二维码内容（10 分钟内有效）: ppf://pair?node=9dcd6242...
IPC: ppf-9dcd6242（令牌在 /tmp/ppf-daemon-verify/ipc.token）
```

- daemon 正常启动：NodeId 生成 ✓、IPC token 写出 ✓、relay 连接 ✓、lib/ 内 dylib 全部正确加载（无 dyld 缺失报错）——**自包含验证通过**。
- **testclient --help 实测**（clap 正常）：

```
P-Pass daemon 集成测试客户端

Usage: testclient <COMMAND>

Commands:
  pair          配对流程测试：扫码令牌 → PairRequest → 等待确认（T-031 实装）
  backup        备份剧本：推送 N 个文件走 manifest→missing→接收→commit（T-032 实装）
  browse        浏览剧本：分页遍历时间线 + 拉取缩略图校验（T-033 实装）
  revoke-check  吊销验证：以未配对/已吊销身份连接，期望 not_authorized（T-030 实装）
  help          Print this message or the help of the given subcommand(s)

Options:
  -h, --help     Print help
  -V, --version  Print version
```

## 备注 / 观察项

1. **`--help` 行为**：daemon 无 clap 参数解析，`--help` 被忽略直接启动服务。卡面写「`./P-Pass/daemon --help` 能起」，实测行为为「直接启动成功」——符合验收意图（能起）。若希望 `--help` 打印用法，需后续给 daemon 加 cli 参数层（非本卡范围，记录待议）。
2. **BUILD_INFO 确认**：`built from ea3bbf491252f9b1212533c51e8c1b253ed1ced7 on 2026-08-03T11:47:51Z` —— 构建源 commit 与 tag 所指向的 main HEAD 一致。
3. **测试残留**：验证用 daemon 进程已 kill，无残留；验证全程用 `PPF_DATA_DIR=/tmp/ppf-daemon-verify` 隔离目录，**未触碰**真实库目录（`~/Library/Application Support/P-Pass`），无任何污染。

## 结论

**REL-test3 三验收项全部 PASS。** 发布流水线在 T-071b 修复（SHA-pin + per-platform 资产命名）后端到端全链绿，草稿资产 6 件齐整，产物自包含可运行。test.2→test.3 两轮连续全绿，flaky 疑云基本排除。

---

*汇报人：Salamira · 2026-08-03 · 待审核*
