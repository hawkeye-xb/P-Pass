# P-Pass 核心备份流程：行为 Case Catalog（仅设计）

**目标：** 先用场景定义系统承诺，再让状态图、数据模型和实现从 case 推导；不从现有 WorkManager 入口或旧补丁反推需求。

**本轮边界：** 不写生产代码、不写自动化测试、不改任务卡。本文是后续 TDD 的行为验收目录；实施时必须按垂直切片逐个 `RED → GREEN → REFACTOR`，不能一次堆完所有测试。

## 统一术语

- **后台自动开启/关闭**：只决定 App 不在前台时能否自动发现、自动消费。App 在前台时默认可以自动备份。
- **Pause**：用户暂停整个管线；保留未确认项，禁止自动继续。
- **Continue**：清 Pause，继续原有未确认项；绝不偷换成手动全量扫描。
- **Cancel 本次传输**：用户明确放弃当前暂停的传输；仅未确认项可取消，必须清理手机与电脑两侧活跃传输/staging 记录，并留审计终态。
- **系统取消**：OS/执行器被停止；不是用户 Cancel，不改变产品意图。
- **永久错误**：文件不可读、协议明确不可重试或重试预算耗尽；保留错误原因、清理两侧活跃传输记录、继续处理其他项。
- **发现事务**：`upsert TransferItem(s) + advance DiscoveryCursor` 的同一原子提交。

---

## A. 配置、范围与后台自动权

| ID | Given / When | Then（可验证事实） |
|---|---|---|
| POL-01 | 尚未选择备份范围，任何自动 wake 到来 | 不扫描、不建 TransferItem、不传输；状态是“未选择范围”，不是“全部安全”。 |
| POL-02 | 用户范围为空，任何 wake 到来 | 不扫描、不传输；状态是“范围为空”，不是成功。 |
| POL-03 | 已选范围为 A，MediaStore 同时有 A/B 相册照片 | 只允许 A 的版本进入队列或传输链路；B 永远不出现。 |
| POL-04 | 后台自动开启，App 在后台，新照片触发 | 合法条件满足时能自动发现并消费。 |
| POL-05 | 后台自动关闭，App 在后台，新照片/周期 wake 到来 | 不发现、不消费、不改 cursor/queue；不会把待传项丢掉。 |
| POL-06 | 后台自动关闭，用户打开 App 并留在前台 | 仍默认自动发现并消费已有队列，不要求额外点“立即备份”。 |
| POL-07 | 后台自动关闭，前台正在传输，App 切到后台 | 当前执行器被有序停止；lease 回到可恢复状态；后台不得继续传。 |
| POL-08 | 后台自动从开启切为关闭，已有后台待传队列 | 队列和 cursor 保留；只撤销后台执行权。 |
| POL-09 | 后台自动从关闭重新开启 | 不造新业务任务；下次符合条件的 wake 可消费旧队列/发现新变化。 |
| POL-10 | 用户缩小范围时，队列里存在新范围外的未确认项 | 这些项不许再传；转为显式 `cancelledByScope` 或等价终态，并清理活跃传输记录。 |
| POL-11 | 用户扩大范围或把旧照片移动进已选范围 | 对应版本必须有重新发现机制；不能只靠已越过的 cursor 而永久漏掉。 |

## B. 本地发现与 Cursor 原子性

| ID | Given / When | Then（可验证事实） |
|---|---|---|
| DSC-01 | cursor=C，扫描发现一张版本 V | 同一事务写入 V 的 `QUEUED` 项和新 cursor=C'。 |
| DSC-02 | 同一 wake / 多个 wake 重复扫描到版本 V | 队列最多一项 V；不产生重复传输。 |
| DSC-03 | 在发现事务提交前进程崩溃 | cursor 仍为 C、队列无半项；下次可安全重扫。 |
| DSC-04 | 发现事务提交后、传输前进程崩溃 | cursor=C' 且 V 仍在队列；下次不丢失 V。 |
| DSC-05 | `TransferItem` 落盘失败 | cursor 不许前进；下次必须能重扫到该项。 |
| DSC-06 | cursor 落盘失败 | 不允许出现“项已可靠发现但 cursor 不一致”的半提交；事务整体回滚或可恢复。 |
| DSC-07 | 相同 MediaStore stable key 的内容版本发生变化 | 新版本作为独立待确认版本处理；旧 confirmed 不得掩盖新版本。 |
| DSC-08 | 连拍/Watch 连续触发 N 次 | 允许合并为一次 discovery；结果覆盖 cursor 后全部变化，不漏、不重复。 |
| DSC-09 | App 前台、冷启动、Watch、周期同时 wake | 至多一个 controller 进入 discovery；其他 wake 合并，不影响最终发现集合。 |
| DSC-10 | 用户明确发起手动全量 | 只有该动作生成 `manual-full-scan` 请求；它不由 Continue、Retry 或后台 wake 隐式生成。 |
| DSC-11 | 低频对账发现远端缺失 | 不通过把 cursor 回退来重扫整库；精确 upsert 对应 `reconciliation` 项。 |

## C. 准入与约束

| ID | Given / When | Then（可验证事实） |
|---|---|---|
| ADM-01 | 自动 discovery 前 Wi‑Fi/电量不满足 | 不扫描、不改 cursor、不创建失败记录；派生为 `WaitingConstraints`。 |
| ADM-02 | 已发现队列项，但 consumer 开始前条件不满足 | 队列项保持原状；不加 retry count/error。 |
| ADM-03 | 传输中条件变化或 OS 停止执行器 | 当前 lease 被释放回可恢复状态；不是 Pause、不是用户 Cancel、不是永久失败。 |
| ADM-04 | 条件重新满足 | 不需重建业务意图；wake 后继续 discovery/消费。 |
| ADM-05 | scheduler 错误地在条件不满足时唤醒 | controller 的最终准入检查仍阻止网络/传输开销。 |
| ADM-06 | scheduler 因条件满足没能唤醒 | 后续任一合法 wake 仍可从 durable queue 继续；不依赖那一次 wake。 |
| ADM-07 | 前台显式手动全量有独立约束豁免 | 豁免只属于这一明确请求；不得扩散到 Continue、Retry 或自动队列消费。 |

## D. 队列消费、去重与传输结果

| ID | Given / When | Then（可验证事实） |
|---|---|---|
| XFR-01 | 一个 `QUEUED` 项、远端确认成功 | 该项立即 `CONFIRMED`，写确认时间/hash；不用等待整批结束。 |
| XFR-02 | 内容 hash 已在远端存在且远端给出有效去重确认 | 本地同样进入 `CONFIRMED`；不能因“未重新传字节”而永久 pending。 |
| XFR-03 | 远端已接收但确认回包丢失，随后重试 | 同一项幂等重试；远端不会制造重复档案，本地最终进入 `CONFIRMED`。 |
| XFR-04 | 某项临时网络错误 | 只该项进入 `RETRY_AT`，携带 error/attempt/next time。 |
| XFR-05 | 队列前项处于 `RETRY_AT` 未到期，后项可传 | consumer 必须能跳过前项继续后项；临时错误不得堵住整个队列。 |
| XFR-06 | 已到 retry 时间 | 该项重新获得传输机会；不需要重新扫描整库。 |
| XFR-07 | 文件在本地已被删、权限永久撤销或明确不可重试 | 标记 `FAILED_PERMANENT(reason)`；错误可供后续 UI 显示。 |
| XFR-08 | 远端协议给出明确不可重试拒绝 | 同 XFR-07；不得无限退避。 |
| XFR-09 | 不可恢复项出现 | 清理 mobile 与 desktop 两侧 active transfer/staging；保留最小错误审计；继续下一项。 |
| XFR-09a | 永久错误后的远端 staging cleanup 网络失败 | 本地保持 `FAILED_PERMANENT(cleanup=Pending)` 并持久化 cleanup outbox；只重试 abort/cleanup，不得重新上传该文件。 |
| XFR-10 | 一项永久失败，队列后仍有可传项 | 后项仍成功传输；批次结果不能把整批伪装为失败/暂停。 |
| XFR-11 | 一项传输中系统取消/进程崩溃 | 本地 stale lease 在下次启动被恢复为 `QUEUED`；不得误标 `FAILED_PERMANENT`。 |
| XFR-12 | 远端 staging 已过期或不完整 | 下一次从 `QUEUED` 重启幂等协商；不得把过期 staging 当 `CONFIRMED`。 |
| XFR-13 | 同一版本被多个 wake/执行器竞争 | 最多一个有效 lease；远端确认和本地终态只能写一次。 |
| XFR-14 | 传输先成功、同时用户发出 Cancel | 已 `CONFIRMED` 的项保持确认；Cancel 只能影响尚未确认项，不能删除已交付档案。 |

## E. Pause / Continue / Cancel

| ID | Given / When | Then（可验证事实） |
|---|---|---|
| CTL-01 | consumer 正在运行，用户 Pause | 必须先持久化 `userPaused=true`，再请求停止执行器。 |
| CTL-02 | Pause 与当前 discovery 事务竞争 | 若事务未提交则 cursor 不前进；若已提交则项安全留在队列；两种结果都不丢候选。 |
| CTL-03 | Pause 与传输中 lease 竞争 | 不把项记为 retry/error；lease 回到可恢复项；未确认项保持。 |
| CTL-04 | 已 Pause 时任何后台/前台 wake 到来 | 不 discovery、不消费；只有 Continue 或 Cancel 能改变暂停状态。 |
| CTL-05 | Pause 后杀 App / 重启 | `userPaused` 与未确认队列仍存在；不得因进程重启自动恢复。 |
| CTL-06 | 用户 Continue | 原子清 `userPaused`，从首个未确认、已符合条件的项继续；不是全量扫描。 |
| CTL-07 | Continue 后条件仍不满足 | 进入 `WaitingConstraints`，不是失败或再次 Paused。 |
| CTL-08 | 用户 Cancel 已暂停的传输 | 当前传输范围内的未确认项进入 `CANCELLED_BY_USER`，清两侧 active transfer/staging，并清 `userPaused`。 |
| CTL-08a | Cancel 后远端 abort 失败或 App 崩溃 | Cancel 意图和 cleanup outbox 已持久化；重启后继续 cleanup，绝不把取消过的项重新投入传输。 |
| CTL-09 | Cancel 时存在已 `CONFIRMED` 项 | 确认项保持不变；只处理未确认项。 |
| CTL-10 | Cancel 完成后出现全新本地照片且后台自动已开启 | 新照片可以正常走后续自动流程；Cancel 不等于关闭后台自动。 |
| CTL-11 | 用户再次主动发起手动全量 | 这是独立明确请求；不得因为有历史 `CANCELLED_BY_USER` 而被静默吞掉。 |

> **待定但必须在实现前定：** `CTL-08` 的“当前传输范围”如何界定：是同一次
> discovery request、当前队列快照、还是用户可选择的项。需要一个可持久化的
> `TransferIntent/Session` 归属字段；不能临时靠 WorkManager name 或 UI 状态猜。

## F. 低频远端对账（Reconciliation）

| ID | Given / When | Then（可验证事实） |
|---|---|---|
| REC-01 | 到对账时间，confirmed 为空 | 不发无意义远端请求。 |
| REC-02 | 远端确认所有 confirmed hash 仍存在 | 不增加队列项、不改变 confirmed。 |
| REC-03 | 远端报告某 hash 缺失，本地源仍在范围内 | 标远端缺失并 upsert 对应 `reconciliation` 项；走普通 consumer 恢复。 |
| REC-04 | 远端报告缺失，但本地源已不存在或不在范围内 | 产生可诊断终态；不得全量重扫或上传范围外照片。 |
| REC-05 | 对账网络失败 / daemon 不可达 | 保留 confirmed 原样；不把“未知”错写成“远端丢失”。 |
| REC-06 | 对账与日常自动备份并发 | 同一版本在队列中合并，不形成双重传输。 |
| REC-07 | 已恢复上传成功 | remote presence / confirmed evidence 回到确认状态；不反复补传。 |

## G. 远端切换、恢复与并发安全

| ID | Given / When | Then（可验证事实） |
|---|---|---|
| RCV-01 | App 进程在无传输、发现中、传输中分别崩溃 | 每种时刻重启后都满足：不丢已提交候选、不提前推进 cursor、不把未确认项当完成。 |
| RCV-02 | 设备配对到新的远端 | 新远端绝不继承旧远端的 `confirmed`、queue lease 或 staging 身份；不会向错误电脑传输。 |
| RCV-03 | 解除配对时仍有未确认项 | 按显式产品策略终止/隔离旧远端队列；绝不能在新配对后自动发送。 |
| RCV-04 | 两个 controller wake 并发 | discovery transaction 和 item lease 保证单写/单传；结果不依赖先后随机性。 |
| RCV-05 | 数据库存储空间不足或状态文件损坏 | fail closed：不前进 cursor、不声明成功；给出可诊断错误。 |
| RCV-06 | 时钟变化影响 retryAt / reconciliationDue | 采用可验证的时间语义；不得无限等待或立即风暴重试。 |

## H. 派生状态与可观测性（不设计 UI 版式）

| ID | Given / When | Then（可验证事实） |
|---|---|---|
| OBS-01 | 没选范围 / 空范围 | 状态原因可区分；不得显示“已全部备份”。 |
| OBS-02 | 后台自动关闭且 App 在后台 | 表达“后台自动已关闭”，而非“暂停”或“失败”。 |
| OBS-03 | 用户 Pause | 表达“已暂停”，可用动作只有 Continue / Cancel。 |
| OBS-04 | 条件不满足 | 表达“等待 Wi‑Fi/电量”等条件，不显示 Continue。 |
| OBS-05 | 某项重试中、后项仍在传 | 不误报整个管线暂停；能反映仍有传输进展。 |
| OBS-06 | 某项 `FAILED_PERMANENT`，后续项成功 | 错误可追溯，但整体状态不能把成功/进行中覆盖为“暂停”。 |
| OBS-07 | 用户 Cancel 后 | 可追溯“用户取消”的事实；不得假装所有项已经安全备份。 |

## I. 真机/端到端验证切片（最后执行）

| ID | 真实操作 | 必须观察到 |
|---|---|---|
| E2E-01 | 选范围 → 前台拍一张 | 前台默认自动发现、传输、确认一张。 |
| E2E-02 | 关闭后台自动 → 退后台拍一张 | 后台不传；打开 App 后自动补发现并传。 |
| E2E-03 | 传输中 Pause → 杀 App → 重开 → Continue | 未确认内容仍在，按原队列继续，不变手动全量。 |
| E2E-04 | 传输中 Pause → Cancel | 未确认传输被两端清理；后续新照片在后台自动开启时仍可备份。 |
| E2E-05 | 制造一个永久不可读文件，队列另有正常文件 | 该项有错误且两端无悬挂 staging；正常项仍完成。 |
| E2E-06 | 断网/恢复、切 Wi‑Fi/蜂窝、低电量/恢复 | 仅出现等待或单项重试；不丢项、不误暂停、不全量重扫。 |
| E2E-07 | 在电脑端删除一张已确认照片，等低频对账 | 只定向补回缺失项，不扫/传整库。 |

---

## Case catalog 驱动的设计缺口

1. **必须新增 `TransferIntent/Session` 归属。** 否则无法定义 Pause 后 Cancel 的精确范围，也无法可靠清理两侧 staging。
2. **队列选择策略必须是“最早可传项”，不是死盯 head。** 否则 `RETRY_AT` 会阻塞用户要求的“继续其他内容传输”。
3. **scope 收缩、解除配对、用户 Cancel 都是业务终态。** 不能伪装成系统取消或裸删本地记录。
4. **每一个永久错误、用户取消、scope 取消都要保留轻量审计理由。** 清理 active transfer 不等于抹掉事实。

## 后续使用方式

先由用户确认 case 的产品语义，特别是 `CTL-08` 的 Cancel 范围；随后按风险由高到低实施垂直切片：

1. `DSC-01/03/04/05`（原子发现与不丢候选）；
2. `XFR-01/04/05/07/09/10`（逐项传输与错误不阻塞）；
3. `CTL-01..10`（Pause/Continue/Cancel）；
4. `POL-04..09`（后台自动与前台默认自动）；
5. `REC-*`、并发恢复与真机 E2E。

在每一项实现前必须先写该 case 的失败测试，并亲眼确认失败原因是目标行为尚未实现。