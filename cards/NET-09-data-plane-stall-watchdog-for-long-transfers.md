# NET-09 长数据传输面加「字节停滞」看门狗（手机下载原图 / APK 下载 / daemon 收发）　级别 L1

> ⬜ 状态：未开工（2026-09-14 NET-08 普查产出，焊点 N4+N5）
> 级别：L1 · 阻塞：无
> **AGENTS.md 设计纪律登记：本卡是终态方案本身（看门狗即长数据流的
> 标准答案，非止血）；不需要另开根治卡。**

## 问题

NET-08 普查（详见 NET-08「普查结果」N4/N5 行）：

- `apps/android/.../transport/DaemonClient.kt:241` `downloadAsset`：拨号有
  `connectBounded` 闸，但字节循环（`:280` `recv.readExact`）**没有任何
  idle 上限**——relay 半开、对端进程僵死时，查看大图的协程永久挂起；
  UI 停在最后一次进度百分比，用户分不清「慢」还是「死」，也没有取消后
  的自愈入口（协程挂到 Activity 销毁）。
- `apps/android/.../update/UpdateChecker.kt:158-159`：APK 下载
  `readTimeout = 30_000` 单值同时扮演「服务器死了」（应严）与「百 MB 包
  在蜂窝慢速下载第一个字节之后还在动」（应宽——HttpURLConnection 的
  readTimeout 是 per-read，30s 单条不致命，但慢而停滞的链路报错文案与
  死链完全相同，且 `:175` catch-all 吞掉死因，用户只看到「点了没反应」）。
- 同形镜像在 daemon 侧：`crates/daemon/src/upload.rs:148`（收字节的
  `recv_chunk` await 无上限——手机半死后 daemon 任务挂而不死）、
  `crates/daemon/src/download.rs:102`（发字节 `send_frame` 失败即断，
  风险较低但口径应一致）。

与 NET-01 的区别要说清：fetch 病是「控制 RPC 焊等长任务」，NET-06 修；
本病是「数据面一旦开盘就无人盯字节是否还在流」——同一普查判据的另一种
表现（W2：只有「整通电话断没断」，没有「字节久没动=死」这一层事实）。

## 期望行为

标准答案形态：长数据流不设总时长上限（NET-06 备注既定设计），设
**字节停滞看门狗**（stall timeout：连续 N 秒零进展 = 判死并带上限语义的
错误上报）：

1. `downloadAsset`：`withTimeout` 只包「等待下一个数据块」这一步——
   每收到一块就重置；停滞超阈值（卡定 30s，写注释：它是「对端不再流动」
   的判定窗，不是预期耗时；禁止按文件大小/速率动态推算）→ 抛
   `DaemonStallException(hash, stalledMs)`，UI 层据此显示「传输中断，
   点击重试」而非永久转圈。
2. APK 下载改分档：connect 8s 现值不动；read 停滞判死同上语义；
   `catch (_: Exception)` 收窄——停滞/连接失败/HTTP 非 200 分别落
   不同返回值，UI 至少能区分「网络慢」与「下载失败」。
3. daemon 侧 `upload.rs` 收流加同参数停滞上限：超时 = 拒绝该流、
   清 staging 残包（复用现有 reject 路径），日志带停滞毫秒数。
4. 阈值三端同数（30s）单点定义（Kotlin 常量 + Rust 常量各自注释指向
   本卡），不引共享代码。

## 验收标准

- [ ] RED 先行（JVM）：喂一个「收到 2 块后永不返回」的假 Connection →
      `downloadAsset` 必须在停滞阈值（测试注入缩短值）内抛
      `DaemonStallException`；改前该用例真红（当前永久挂起）。
- [ ] 反证：字节持续流动的慢传输（每 20s 一块 × 10 块）不得触发停滞
      异常——证明看门狗盯的是「零进展」不是「总时长」（防摆钟复发）。
- [ ] APK 下载：停滞 vs 非 200 vs 连接拒绝三种失败返回可区分（JVM 测试
      对假 HttpURLConnection 断言）。
- [ ] daemon：`upload.rs` 停滞用例（假流半死后 daemon 侧任务限期终结、
      staging 清理，tokio test）；断言 reject 日志含 stalledMs。
- [ ] Android JVM 全量（报测试计数）+ `just ci` 全绿。
- [ ] UI 接线：查看大图下载失败走既有失败呈现（不新开提示渠道）；
      「重试」从 head 重新发起（幂等由 content hash 保证，无需新协议）。

## 范围

- 只准动：`apps/android/.../transport/DaemonClient.kt`（downloadAsset +
  新异常类型）、`apps/android/.../update/UpdateChecker.kt`（downloadAndInstall）、
  `apps/android/.../ui/PhotosScreen.kt`（仅失败呈现接线）、
  `crates/daemon/src/upload.rs`、`crates/daemon/src/download.rs`、对应测试、
  卡片/队列文档。
- 不准动：协议方法集（NET-06 地盘）、`call()` 控制面三档（NET-07 地盘）、
  `flow_delivery.rs`、StrictConsumer 重试语义。

## 阻塞与依赖

无。与 NET-06/07 并行（文件不相交：本卡只碰 downloadAsset/UpdateChecker/
upload.rs，NET-06 碰 call 路径与 flow 管线）。UI 接线若与 NET-06 的进度
展示卡撞 `PhotosScreen.kt`，以 NET-06 先合为准，本卡 rebase。

---

## 备注

- NET-08 判定「形状正确的对照组」一节的最后一条即本卡依据：数据面长流
  不设总上限是既定设计，病在「无 idle 检测」——所以修法是停滞看门狗，
  不是把总超时调大（调大=摆钟复发）。
- iroh 连接层自身有 idle 超时（`crates/transport/src/iroh_impl.rs:124`
  120s 回收），但那是**服务端连接表清理**，不解除客户端 await 的挂起；
  设计纪律第 4 条口径：已核查库能力，库无「单流字节停滞」事件可订阅，
  read-with-deadline 即标准答案。
