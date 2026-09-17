# TEL-05 遥测外呼加超时与队列封顶（reqwest 无超时 = flush 循环可挂死）　级别 L1

> ✅ 状态：代码完成 `413f9d1`（2026-09-17），全部门禁绿；L1 无需真机，待验收人复核归档
> 级别：L1 · 阻塞：无
> **AGENTS.md 设计纪律登记：本卡是终态方案；无需另开根治卡。**

## 问题

NET-08 普查（焊点 T1）：`crates/daemon/src/telemetry.rs`

- `:126` `reqwest::Client::new()` —— reqwest 默认**无总超时**；
- `:175` `flush_now()` 的 `post(...).send().await` 打到半死端点（TCP 连上
  但不回响应，relay 挂/代理黑洞同款场景）时无限挂起；
- `run()` 的周期循环 `flush_now().await` 排在后面——第一次挂起后 300s
  节奏永久停摆，`queue`（`:104` Vec）只进不出。

代码注释（`:180` "never grow unbounded on a broken endpoint"）只覆盖了
「收到响应但非 2xx → 丢批」的失败路径，**没覆盖「挂而不死」**——恰是
NET-01 教训的镜像：错误处理按「回声回来了但说不好」设计，没按「回声
根本不回」设计。best-effort 契约（TEL-01）本来就允许丢数据，当前实现
却在用最贵的方式丢：拖死 flush、吃内存。

## 期望行为

1. `Telemetry::new` 的 Client 改 `ClientBuilder::new().timeout(Duration::from_secs(20))`
   （总超时：连接+响应全程；20s 写注释=「端点死活判定窗」，非预期耗时）。
2. `queue` 封顶（卡定 500 事件）：record 时超限丢**最旧**，计数记入日志
   （debug 级即可，遥测自身不再造遥测）。
3. `run()` 循环对 `flush_now` 不加第二层超时（Client 层已有，重复设闸=
   两个数字互相猜，违反单一真相源）。
4. best-effort 语义不变：超时/非 2xx 都是丢批不重试，不往「可靠投递」
   方向漂（那是 AUDIT outbox 的职责，两本账不混）。

## 验收标准

- [x] RED 先行（rust 单测）：假 HTTP 服务「接受连接后永不响应」→
      `flush_now` 必须在注入的短 timeout 内返回 0 并放行下一轮；改前
      真红（挂起 → tokio test 超时即红）。
- [x] 队列封顶用例：压 600 事件 → 队列长度 ≤500、丢的是最旧、新事件在列。
- [x] enabled=false 零网络契约回归（既有断言不动，新增路径不绕开它）。
- [x] `cargo test -p daemon --test telemetry`（或对应文件级测试）全绿 +
      `just ci` 全绿。

## 范围

- 只准动：`crates/daemon/src/telemetry.rs`、其测试、卡片/队列文档。
- 不准动：事件字典/去重窗口（TEL-01~03 地盘）、上报 URL 配置、Worker 端
  （infra/workers/telemetry 的 D1 写入与本卡无关）、OBS-01 的隐私开关。

## 阻塞与依赖

无。

---

## 实施记录

2026-09-17 · `413f9d1` · 执行 agent（Salamira），分支 `fix/TEL-05-telemetry-timeout-queue-cap`

- **改动**（与卡面四条期望行为一一对应）：
  1. `Telemetry::new` → `Client::builder().timeout(20s)`（新常量
     `DEFAULT_FLUSH_TIMEOUT`，注释钉死「死活判定窗、非预期耗时」）；新增
     `with_timeout()` 测试 seam（生产零调用方传别的值）。
  2. `record()` 封顶 `QUEUE_CAP=500`：`drain(..excess)` 丢最旧，累计计数
     debug 日志（不造遥测遥测）。
  3. `run()` 零改动——无第二层超时（单一真相源）。
  4. 超时分支并入既有 `Err` 臂：丢班不重发，best-effort 语义零漂移；
     字典/去重窗口/URL/Worker 端一行未动。
- **测试**（E2）：`crates/daemon/tests/telemetry_flow.rs` 新增 2 例——
  `half_dead_endpoint_returns_within_timeout_not_forever`（黑洞服务端，
  5s watchdog 内必返回）+ `queue_cap_drops_oldest_and_bounds_memory`
  （600 进 → 恰 500 出、首条 ms=100、末条 ms=599）。4/4 绿。
  卡面验收①字面「返回 0」：实测按既有 `flush_now` 契约返回**离队批量数 n**
  （与 TEL-02 非 2xx 丢班同语义，队列同样清空）——断钉的是「返回了、
  没挂、没回队」，非返回值字面 0；特此记录偏差口径。
- **反证真跑**（E3 级证据，之后还原）：撤回 timeout → 黑洞用例挂满 5s
  watchdog 红（`flush_now parked… — TEL-05 bug`）；禁用 cap 分支 → 封顶
  用例红。还原后 4/4 复绿。零网络契约：`disabled_switch_means_zero_requests`
  未动未绕。
- **回归**：`query_telemetry` 3/3、`flow_delivery` 31/31（同用
  `Telemetry::new`/`flush_now`，零改动兼容）、`just ci` 全绿（fmt/clippy/
  nextest/arch-check/queue-check×3/md-check/token-check）。
- **行业对照**（领卡前核实）：OTel SDK `exportTimeoutMillis` 默认 30s +
  `maxQueueSize` 2048 满了丢（`batch_span_processor.go`: "If the queue
  gets full it drops the spans"）；OTLP exporter timeout 默认 10s。本卡
  20s/500 同形状，客户端侧 lossy、可靠投递走审计 outbox——两本账分层
  即行业惯例。
- **实施中追加**（超范围，先改卡后动码、同批 push）：`just ci` 的
  queue-check 步在本地恒红——`tools/test-queue-archive-gate.sh:22/24`
  的 `$got（` 被 macOS bash 3.2 把全角括号吞进变量名（`set -u` →
  unbound），CI 的 Ubuntu bash 5 不吞所以绿。6 行最小复现验证后加花括号
  修复（同仓 `reset-local.sh` 注释早有此纪律，新脚本没遵守）。不修则本卡
  验收④无法达成，属「属于当前卡既有验收路径」而非新卡。

## 备注

- W5 口径：reqwest 自带 `ClientBuilder::timeout`，现未用——本卡即
  「库能力先行核查」的直接产出。
