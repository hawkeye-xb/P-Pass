# AGENT_PROTOCOL — 架构规则与验收口径（按需参考）

流程与红线在根目录 [`AGENTS.md`](../AGENTS.md)。本文只补两样东西：机器执法的
架构规则在哪，以及写验收标准时容易造假的几个点。

## 架构规则：以 `tools/arch-check.sh` 为准

规则全文写在 [`tools/arch-check.sh`](../tools/arch-check.sh) 文件头，`just ci`
里的 `just arch-check` 执法，自测是 `tools/test-arch-check.sh`。本文不复述，
以免两处漂移。要点：iroh 只在 `crates/transport/`；按操作系统分叉只在
`crates/platform/`；设备档案与审计永不删除；授权点不查库；桌面壳不判断平台、
不写 config；核心 crate 不碰托管。存量越界登记在 `tools/arch-allowlist.txt`，
只许降、不许升。

## 架构换代时的旧测试（supersession）

已确认的新架构重定义了某个流程时，保护旧实现细节的测试不许继续当新实现的
门禁，也不许为了让它绿而保留旧机制。做法：在旧测试处写明 frozen/superseded
及对应的新设计（issue 号或 `docs/design/` 文档），把仍然成立的产品不变量按新
case matrix 重写成失败用例，再写生产代码。撞到「bug 被写进测试」时改断言、
保意图，绝不直接删测试，并在 PR 里登记。

## 验收抽检：专挑造假高发点

1. 恒真判据：`grep`/`match` 模式会不会必然命中（子串陷阱、空集、`|| true`）。
2. soft-fail：失败路径只打警告却仍报全绿；吊销、鉴权这类必须 hard-fail。
3. 「全绿」的覆盖面：实际跑了哪些 lane。
4. 跨卡声明：「已修复」在 main 上真的存在吗（`git grep` 验证）。
5. 反证：去掉故障条件，判据必须变红。

## 自举类改动（更新器、安装器、重启、版本对账）

`N → N+1` 这一跳跑的永远是 N 的代码，所以判据要从「这段代码由哪个版本执行」
推导。版本阶梯只需两个包：主修复包 + 纯 bump 的下一跳包，起点手动安装。涉及
多实体版本不一致的，验收清单给多起点矩阵；每条标明通过 / 允许的降级 / 阻断。
