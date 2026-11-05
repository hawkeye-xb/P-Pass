# 发布链 hdiutil 遇到「Resource busy」时退避重试

- 状态：已采纳
- 日期：2026-11-05
- 采纳：产品负责人 2026-11-05 在 owner 会话采纳选项一
- 关联：#1438（v0.11.0-test.3 Release 失败）、#772（发布链外部命令限时）

## 结论

1. `tools/release/with-timeout.sh` 加一个可选前置参数 `--retry-on <ERE>`：命令**在上限内结束**、
   **退出码非 0**、**本次 stderr 匹配该模式**，三条同时满足才重试；其余失败照旧立即透传退出码。
2. 重试间隔 5s / 10s / 20s，即最多重试 3 次、命令最多跑 4 次。重试用完仍是 busy，透传命令自己的
   退出码，并说清是哪一步、第几次。
3. `tools/bundle-desktop-macos.sh` 第 6 步只给 `hdiutil create`、`hdiutil attach`、`hdiutil detach`
   三处加 `--retry-on 'Resource busy'`；`hdiutil convert` 与其它命令不变。
4. 超时的处理不变：超时仍由 `with-timeout.sh` 原有的「次数」参数管，超时用完以 124 退出；
   busy 重试与超时重试分开计数，互不占用。
5. 测试进现有的 `tools/test-release-timeouts.sh`（CI 的 `release-timeouts` lane 已在跑它），
   用假命令覆盖：busy 两次后成功 → 0；一直 busy → 跑满 4 次后透传原退出码；其它错误 → 只跑 1 次
   （反证）；不带 `--retry-on` 的旧调用行为一字不变。门禁再加一条：bundle 脚本里 create / attach /
   detach 三处都带 `--retry-on`。

## 背景

#1438：Release v0.11.0-test.3（run 41978251616）在 macOS arm64 签名门控的第 6 步失败：

```
hdiutil: create failed - Resource busy
FAILED: 「hdiutil create（可写 dmg）」退出码 1
```

下游 manifest 因缺 mac 产物拒绝发布，tag 已建，只能重出 -test.4。最近 12 次 Release 失败里只此一次，
属 GitHub macOS runner 上磁盘镜像子系统被占用的偶发，不是我们的回归。

现在的 `with-timeout.sh` 只在**超时**时重试，非 0 退出一律当真失败立即透传——这对「真失败」是对的，
但让一类已知的瞬时错误也要人工重出一个 test 号。

## 决定

`with-timeout.sh` 用法变为：

```
tools/release/with-timeout.sh [--retry-on <ERE>] <步骤名> <秒> <最多尝试次数> -- <命令...>
```

- 不带 `--retry-on`：行为与现在完全一样（release.yml、artifacts.yml 现有调用不改）。
- 带 `--retry-on`：每次运行把命令的 stderr 单独截到临时文件（每次清空），运行结束后原样回放到
  stderr；按「结论」第 1、2 条判断是否重试，重试前打印
  「RETRY: 「<步骤名>」退出码 <rc>，stderr 命中「<模式>」（第 i/n 次重试），<秒>s 后重试」，
  n 是本次实际生效的最多重试次数（`PPF_RETRY_DELAYS` 的个数，默认 3），不写死。
- 间隔取环境变量 `PPF_RETRY_DELAYS`（空格分隔的秒数，默认 `5 10 20`），个数即最多重试次数；
  只为测试能秒级跑完而开，发布链不设它。

## 理由

- 本质：发布链要保证「真失败立刻红、瞬时错误不让一次发版作废」。区分两者唯一可靠的依据是错误本身，
  所以按 stderr 里的错误串判，而不是按退出码（hdiutil 各种失败都是 1）。
- 标准做法：对已知瞬时错误做「可重试错误白名单 + 指数退避 + 次数上限」（AWS、Google Cloud 的
  重试指南都是这个形状）。社区打 dmg 的脚本（如 create-dmg）对 `hdiutil detach` 的 busy 也是
  等几秒重试几次。
- 放在 `with-timeout.sh` 而不是 bundle 脚本里包一层：发布链的外部命令本来就统一经它调用，
  「挂住」与「瞬时失败」两种重试放在一处，判定与日志格式一致，也只需在一个测试文件里覆盖。
- 白名单只有 `Resource busy` 一条，只挂在 create / attach / detach 三处：重试面最小，不吞别的失败。

## 后果

- 偶发 busy 时这一步多等的退避时间最多 35s（5+10+20），不再作废整个 test 号。这 35s 只是重试间隔；
  每次重试会再跑一遍命令，单次运行仍受该步原有上限约束（create 600s、attach / detach 120s），
  所以最坏耗时 = 4 × 单次上限 + 35s。实际 busy 在几秒内就返回，远到不了这个上界。
- 真失败（签名、磁盘满、参数错等）仍第一次就红，日志与现在相同。
- `hdiutil create` 带 `-ov`，重跑覆盖上一次的半成品；attach / detach 失败时未改动卷，重跑安全。
- 一直 busy 时比现在晚「35s 退避 + 3 次命令运行时间」才红，日志里能看到 4 次尝试。

## 备选（未采纳）

- **选项二：不改脚本，遇到就重出下一个 test 号**：每次要人工一轮，且 tag 作废、版本号跳号。
- **对 hdiutil 的任何非 0 都重试**：会把真失败拖慢并掩盖在重试日志里，违背「真失败立即红」。
- **在 bundle 脚本里为 hdiutil 单独写一个重试函数**：与 `with-timeout.sh` 的超时逻辑嵌套，
  两层重试计数与日志各一套，测试也要另起炉灶。
