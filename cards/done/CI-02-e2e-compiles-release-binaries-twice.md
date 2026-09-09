# CI-02 e2e nightly 两个 job 各自编译一遍 release 二进制　级别 L3

> ✅ 状态：已完成（2026-09-09）
> 级别：L3 · 阻塞：无

## 问题

`e2e.yml` 的两个 job 并行跑，各自从零编译 release 二进制：

| job | 构建命令 |
|---|---|
| `e2e`（android live: hello/pair/backup） | `cargo build --release -p daemon` |
| `scenarios`（T-070 超大文件/崩溃恢复/磁盘满） | `cargo build --release -p daemon -p testclient` |

两个 job 并行 → **同一个 run 内的 cache 互相看不见**（缓存是上一次 run 留下的），
所以每次 nightly 都把 `daemon` 编译两遍。按 nightly 每天一次、单次 release
编译 ~10 min 估算，一个月约 **300 Linux 分钟纯浪费**（计费 1x，不致命，但是
白烧）。

## 期望行为

release 二进制在一次 nightly 里**只编译一次**，两个测试 job 都用同一份产物。

## ⚠️ 改法必须保留失败隔离（不许合并成一个 job）

最省事的改法是「把两个 job 并成一个，编一次、依次跑两套场景」——**不许这么改**。
那会重新引入 2026-08-22「四层洋葱」的反模式：串行 fail-fast 下前一层的红
掩盖后一层，`ci-rust` 拆并行 job 就是为了治这个。e2e 的两套场景测的是完全
不同的东西（真机链路 vs 进程级故障注入），**必须各自独立报绿/报红**。

正确改法：加一个 `build` job 编译一次 → `upload-artifact` → 两个测试 job
`needs: build` + `download-artifact`。编译一次，失败隔离不变。

## 验收标准

- [x] `e2e.yml` 里 `cargo build --release` 只出现一次
- [x] `e2e` 与 `scenarios` 仍是两个独立 job，一个红不影响另一个出结论
- [x] `actionlint .github/workflows/*.yml` 零告警
- [x] 实跑一次 `workflow_dispatch` 确认两个 job 都拿到二进制且都跑到结论
      （**这条必须真跑，不许只读 yml 就报绿**——本卡改的是 nightly 门禁本身）
- [x] 二进制的可执行位在 upload/download 往返后仍在（artifact 打包会丢
      权限位，需 `chmod +x` 或打 tar 保权限——这是这类改动最常见的坑）

## 范围

- 只准动：`.github/workflows/e2e.yml`
- 不准动：两套场景脚本本身；其它 workflow

## 阻塞与依赖

无。但注意它改的是 nightly 门禁，验收必须实跑一次 dispatch，不能只静态检查。

---

## 备注

发现于 2026-08-25 的 CI 全量盘点（用户问「哪些该自动触发、哪些不该」）。
同一轮盘点已落地两项：`artifacts.yml` 的 macOS job 改只手动触发（10x 计费，
自用裸二进制不值），`ci-workers.yml` 的 paths 去掉自身（防误触发生产部署
去等审批）。本条因为要改 nightly 门禁本身、且必须实跑验证，单独开卡不顺手做。

## 验收记录（2026-09-09）

- 改法：`.github/workflows/e2e.yml` 新增 `build` job（`cargo build --release
  -p daemon -p testclient` 只跑一次），打包为 `release-bins.tar.gz`（tar 保留
  可执行位，规避 upload-artifact zip 打包丢 +x 的已知坑），`e2e`/`scenarios`
  两个 job 各自 `needs: build` + `download-artifact` + `tar -xzf` 解包，解包
  步骤各自加 `test -x` 断言可执行位存活。两个 job 保持独立、互不阻塞对方结论。
- `actionlint .github/workflows/*.yml` 本地跑：exit 0，零告警。
- 实跑 `workflow_dispatch`：run
  https://github.com/hawkeye-xb/P-Pass/actions/runs/34317704548
  （commit `f7bb429`）。三个 job 全部 `completed / success`：
  `build` → `e2e`（含 `Unpack release binaries` 步骤成功、`test -x
  target/release/daemon` 通过）→ `scenarios`（`Unpack release binaries` 步骤
  成功、`test -x target/release/daemon` 与 `testclient` 均通过）。
  `Build release binaries` 步骤在整个 run 里只出现一次（在 `build` job）。
