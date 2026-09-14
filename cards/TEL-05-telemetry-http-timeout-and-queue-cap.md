# TEL-05 遥测外呼加超时与队列封顶（reqwest 无超时 = flush 循环可挂死）　级别 L1

> ⬜ 状态：未开工（2026-09-14 NET-08 普查产出，焊点 T1）
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

- [ ] RED 先行（rust 单测）：假 HTTP 服务「接受连接后永不响应」→
      `flush_now` 必须在注入的短 timeout 内返回 0 并放行下一轮；改前
      真红（挂起 → tokio test 超时即红）。
- [ ] 队列封顶用例：压 600 事件 → 队列长度 ≤500、丢的是最旧、新事件在列。
- [ ] enabled=false 零网络契约回归（既有断言不动，新增路径不绕开它）。
- [ ] `cargo test -p daemon --test telemetry`（或对应文件级测试）全绿 +
      `just ci` 全绿。

## 范围

- 只准动：`crates/daemon/src/telemetry.rs`、其测试、卡片/队列文档。
- 不准动：事件字典/去重窗口（TEL-01~03 地盘）、上报 URL 配置、Worker 端
  （infra/workers/telemetry 的 D1 写入与本卡无关）、OBS-01 的隐私开关。

## 阻塞与依赖

无。

---

## 实施记录

（待补）

## 备注

- W5 口径：reqwest 自带 `ClientBuilder::timeout`，现未用——本卡即
  「库能力先行核查」的直接产出。
