# P-Pass 实施进度

> 按完成时间倒序排列。每卡: `DONE` + 一行摘要 + 验收输出摘录。

| 卡片 | 日期 | Commit | 状态 | 摘要 |
|------|------|--------|------|------|
| **ARCH-01（L2）备份核心流程：发现队列与严格单张消费** | 2026-08-29 | 本 commit | 🟡 设计已收口，待拆实施卡 | 设计完成：单文件是交付单位，批次只作 500 项发现窗口；触发合并为 `discoveryRequested`，发现器用复合 DiscoveryCursor 原子入队，消费者用严格 UploadCursor 单张处理。传输统一为原生 iroh-blobs fetch/resume，不新增 raw upload/offset/chunk-map 协议；Pause 保留有主 partial 且仅 Continue 恢复，Wi-Fi/电量/Desktop 等条件进入自动 `WAITING_FOR_CONSTRAINTS` 并在条件恢复后从队头续传。范围增加走延后补扫；范围减少经确认替换 ScopeRevision，已获 Desktop 完整保存凭据的项仍确认完成，其他旧未确认项取消并重新发现。Cancel Current Round 在 Pause 后逐页清空本轮全部待传项，取消期间入队项也取消；结束后新入队项属于下一轮，仅用户显式恢复才重新准入。对账默认 `NEEDS_DECISION`，不自动补传或删手机。未改生产代码。 |
| **NET-02（L2）relay 握手失败的 stderr 洪水折叠** | 2026-08-27 | 本 commit | ✅ 完成（daemon 单测 4/4 + `just ci` 全绿 + 真实二进制对假 relay 跑 95s 验证） | 8/26 家中真机实锤：Clash 代理导致 relay TLS 握手失败，daemon 7 分钟写了 92211 行/73MB 到 `.err`（同一句 `tls handshake eof`）。这些行来自 iroh/quinn 内部的 `tracing` 调用，我们没有对应的调用点可改，所以修在 subscriber 层：新增 `crates/daemon/src/log_guard.rs::DedupGuard`（`tracing_subscriber::fmt::MakeWriter`）——折叠 key = 格式化行去掉行首时间戳，第一次立即打印，重复只计数，安静 2 秒后打一条汇总（`×92211 over 1m32s`，格式对上卡片期望），单次/偶发失败不受影响。独立加一道 8MB/次运行的硬上限（Unix `ftruncate` 当前 stderr 文件），防的是"折叠按精确文本分组、某个循环每次内容不完全一样就漏网"的场景；Windows 分支老实标注未接、不装作修好。顺带 `.with_ansi(false)` 去掉落盘文件里没用的颜色码。**调试真坑**：单测最初用 `std::time::Instant`，`tokio::time::advance`/`sleep` 只拨动 tokio 自己的虚拟时钟，`std::time::Instant::now()` 不受影响，导致"是否已安静"的判断永远读到真实墙钟时间、从未触发——切到 `tokio::time::Instant` 才真正验证了逻辑。**真机验证的已知局限**：本地假 relay（accept 即 close）跑出来的是 daemon 被动网络探测（`net_report`，每 ~21s 一轮、自带回退），不是故障当晚"已配对设备正在传输、relay 连接被主动维持"时的紧密循环——那个要复现需要第二台设备真的在传输，本次未做；折叠机制本身的洪水级压力已由单测（真实 92211 次重复，虚拟时钟）覆盖。验证脚本未纳入 CI：测的是 iroh 库自己的探测退避节奏而非我们的代码，慢且环境敏感，价值已被更快更确定的单测覆盖。 |
| **验收人第二批真机验收：9 张归档** | 2026-08-27 | 本 commit | ✅ 已归档（纯卡片/索引，零 CI） | 验收人 Discord 批量报「通过」：**MOB-32**（大批量传一半开 App 不丢照片，L0）、**MOB-37**（通知权限关掉也有重传提示）、**MOB-29**（删照片→桌面警告+手机重传）、**MOB-34**（删老照片自动回归、K 归零）、**MOB-36**（移入已选相册自动被备）、**WATCH-03**（Finder 挪动不丢）、**WATCH-04**（手拷自动收录）、**DESK-08**（批量删除活动页不打挂）、**UI-03**（顶部大标题已删）→ 全部横幅转 ✅、补验收记录、移入 `done/`，QUEUE.md 待验收区同步移除。剩余待验：UX-14、MOB-40、DESK-10、MOB-38、UX-13、WATCH-07、MOB-19、MOB-09、MOB-13、BLOB-01、E2E-02。 |
| **验收人 7 条真机反馈开卡批次（6 新卡 + MOB-26 解冻）** | 2026-08-27 | 本 commit | ✅ 已开卡（纯文档/卡片，零 CI） | 验收人 2026-08-27 反馈 7 条（⚠️ 与并行 session 撞号后重排，最终编号如下）：**①侧滑返回**→`MOB-45`（L2，含查看页手势分层，与 MOB-26 交集已在两卡互相标注）；**②开源图片查看库**→`MOB-26` 从 backlog 解冻移回队列（L2），补调研：查看层 Telephoto/ZoomImage/SubsamplingScaleImageView、元数据层 metadata-extractor/ExifInterface，包体积纪律沿用 ICON-02 先例；**③相册计数虚高**（选 3 显 7、选 4 显 8，恒 +4）→`MOB-46`（L1，线索指向计数混入 4 个固定伪桶，卡面标注先取证）；**④闲置时审计被连接事件刷屏**→`NET-03`（L2，先取证定性真抖动 vs 误记，⚠️ PRES-01 在读 `device.connected` 做 10 分钟去重，口径不能乱动）；**⑤鸿蒙恢复备份无后台**→`MOB-44`（L1，与 DOG-03 同族，先分 HarmonyOS 4.x 兼容层 vs NEXT，需鸿蒙真机窗口）；**⑥闪电标没了**→`UI-07`（L3，当天验收人定性：不是丢了，是小 icon 用错版本——引用了不带闪电标识的 icon，修法等她指示）；**⑦选相册页长名换行+缩略图模糊**→`UI-08`（L3）。QUEUE.md 可接队列已同步。 |
| **UX-13（L1）暂停之后按钮不再消失，原地变「继续」** | 2026-08-26 | 本 commit | ✅ 代码完成（Android **44 类 / 334 tests / 0 failures**，反证真跑；真机验收欠验收人） | 验收人真机原话：「暂停之后，没有重新开始的按钮？」——英雄区那个按钮只在 `busy` 时渲染，一暂停 `busy` 变 false、整个 `if` 块不渲染，续传入口只剩设置页那个低调的「立即备份」，**与 UX-01 卡面自己写的「再点一次 = 续传」冲突**。⚠️ 不是 MOB-33 改出来的（之前那句 `_state.value = Idle` 同样让按钮消失，只是以前没人点第二次）。根因是**「用户主动暂停」与「本来就没事干」都映射到 `Idle`，界面分不出来**。改法：新增 `BackupUiState.Paused`，判据落一个「按下暂停的时刻」（新 `backup/PausePrefs.kt`，tmp+rename）再与 work 真实状态合成——纯函数 `pausedAfterOf(pausedAt, newestFinishedAt, anyRunning)`。**刻意不看那条 CANCELLED 记录**：取消拿不到 `outputData` → 无戳 → 在 MOB-31 的「按戳取最大」里恒被当上古记录，靠它判断「刚被暂停」永远不成立（本卡点名的坑）。**也没破 MOB-33 的「界面不许自己编状态」**：合成要求「没有 work 在跑」，所以点完暂停而字节还在传的那几帧照旧显示进行中。记时刻而不是布尔，是为了**不需要清除时机就能自证过期**（出现更新的完成记录即失效）。英雄区按钮改由纯函数 `heroActionOf` 裁决，**同一个位置换文案**、两个分支共用同一个 `onClick = onBackupNow`（MOB-19 红线：不新增第二条管线）；点击的裁决与文案的裁决共用 `isBackupRunning`，于是「界面显示什么」和「点下去干什么」永远对得上。两处易漏已处理：①构造时**同步**读 `pausedAt`（异步会跟 WorkManager 首帧抢跑 → 暂停后杀 App 重开按钮不见）；②被后来的运行覆盖时清掉标记（不清则终态记录被清理后「继续」凭空复活）。**「继续」刻意不加「K>0」门**：三元组不可用时 K 传 0，加门等于把缺陷原样放回去。 |
| **MOB-38（L0）回到前台就补捞** | 2026-08-26 | 本 commit | ✅ 代码完成（Android **43 类 / 326 tests / 0 failures**，两条反证真跑；真机验收欠验收人） | 验收人：「在前台，一张照片很久也没有同步……从我们 app 切换到相机，这样就不算前台了吗？我记得咱们针对不同的 app 状态有过讨论的啊。」——**算前台，但我们没在「回到前台」这个时机补捞**。补捞原来只挂 `LaunchedEffect(backupInterrupted)`，键只有一个 → composition 存活期间只跑一次；STOPPED→RESUMED 不会让它重跑。讽刺的是同文件**已有四处 ON_RESUME 刷新 + 两处 start/stop**，唯独备份补捞漏了。改法：把门控提成共用闭包 `foregroundCatchup`（**只写一份**），挂进那个已有的 `LifecycleEventObserver`；`LaunchedEffect` 保留但只转调它。提成函数不是为了少打字，是让「漏接一处」变得不可能——MOB-33/34/35/38 四个 bug 全是这个形状，测试里专门一条 `the_catchup_logic_exists_in_exactly_one_place` 钉它。放心「每次 resume 都补」的前提是 MOB-33 的互斥门（代价降到一次 CAS）。**顺带修三条被误伤的既有测试（本轮第四次同款）**：逻辑搬家后 MOB-35 的三条源码断言全红，守的不变量一个没变、只是切片位置过时。**源码文本断言天生与位置耦合**——已把这条写进注释提醒 MOB-39 的实施者。**还有一条我自己当场踩的**：修那三条时顺手加了一条正则断言，当场误报——Kotlin 单语句 `if` 无花括号，正则按「N 字符内出现」判命中，**分不出作用域**。已删并留注释：别用正则猜作用域，文本匹配做不到。 |
| **真机走查（test.5）：MOB-36 受控实验通过 + 开两张新卡 + 一条判定设计如此** | 2026-08-26 | 本 commit | ✅ 已完成（受控实验取证；两张新卡未开工） | **①「移动的还是不 OK，必须打开 App 才触发」→ MOB-36 在受控实验里通过**：把 `_id=1000000539`（水位之下）从未选的 Screenshots 移进已选的 Camera，**App 全程在后台**，13:47:44 移动 → 13:47:45 `ingested=1`。1 秒。机制工作，验收人那次差在别处（待补：从哪个相册移到哪个、那张之前备份过没有——若之前已备份，正确行为就是什么都不发生）。**②「前台一张照片很久没同步」→ 真 bug，MOB-38（L0）**：前台补捞挂在 `LaunchedEffect(backupInterrupted)`，键只有那一个，**composition 存活期间只跑一次**；STOPPED→RESUMED 不会让它重跑。反差是 `MainActivity` 里**已经有**多处 ON_RESUME 观察者（部分授权 MOB-02 / 电池白名单 DOG-02 / 心跳 PRES-01），**只有备份补捞没挂**——正好回答验收人「我记得咱们针对不同的 app 状态有过讨论的啊」。**③「暂停之后没有重新开始的按钮」→ 真缺陷，UX-13（L1）**：按钮只在 `busy` 时渲染，一暂停就整个消失，续传入口只剩设置页，**与 UX-01 卡面自己写的「再点一次 = 续传」冲突**。⚠️ 不是 MOB-33 改出来的。**④「传输中 desktop 删一张，本地有通知远端没有，重新拍照后才通知+重传」→ 设计如此**：手机端只在校准时刻发现（校准跑在备份开始与 App 打开），那条路径正是设计。**顺带答策略提问**：验收人提议「优先后台，后台起了前台就不管」。方向对但**不需要二选一**——他的担心在 MOB-33 之前成立（无互斥 → 并行乱跳），MOB-33 的 `backupInFlight` 门让「都跑」变安全，重复触发代价降到一次 CAS；三条通道失效场景**不重叠**（监听被 OEM 清 / force-stop 不恢复 / Doze 推迟周期），覆盖面越大越好。**教训：验收人报「还是不 OK」时，先做受控实验分清「机制没做」和「这次情形不同」——这次是后者，直接改代码就白改了。** |
| **DESK-10 补漏：脱敏按「字段名」白名单做，`detail` 里的路径把全长 NodeId 带出了包** | 2026-08-26 | 本 commit | 🟡 脱敏已补齐（`just ci` nextest **320 passed**、src-tauri `cargo test --lib` **15 passed**、desktop vitest 24 passed、clippy 零告警；两侧反证真跑）——**其余验收项仍等真机复验，卡不进 `done/`** | 真机验收把 DESK-10 打回：9 份文件齐、真日志在、版本号对、家目录脱敏全过，**只有验收标准第 5 条「NodeId 仍只出前缀」没达到**——`audit.json` 里有完整 64 位 NodeId。根因是**掩码按字段名做**：`actor` 有前缀掩码，`detail` 只过 `sanitize()`（家目录替换），而库布局是 `originals/<nodeid>/YYYY/MM/<file>`，`detail` 里嵌的 `rel_path` **本身就以全长 NodeId 开头**。修法：脱敏改成按**值的形状**做——daemon 侧新增 `mask_long_hex()`（≥24 位连续 hex → 前 8 位 + `…<masked>`，短 hex 如端口号不动）+ `scrub() = mask_long_hex(sanitize())`，`export_logs` 三个出包字段（diag `detail` / device `name` / audit `detail`）全换 `scrub`；`sanitize()` 语义不动，家目录脱敏零改动。**顺带自查确认 `diag_events.json` 的 `detail` 是同一个洞的另一半——它也漏，一起修了。**桌面壳侧也补一刀：`build_bundle` 里 daemon 给的 JSON 不再「原样搬」，同样过 `scrub`——**版本可以歪**（新壳配旧 daemon 就会再漏一次），而验收标准是「**包**里不许有全长 hex」，保证必须做在 bundle 边界上（≥24 位 hex 不可能跨越 JSON 语法字符，掩码只发生在字符串值内部，测试里真解析了一遍确认 JSON 仍合法；8 位前缀在阈值之下不受影响）。**既有那条测试为什么没抓到**：`logs_export_zip_carries_audit_events` 的 fixture 里 `detail` 是 `"测试吊销"`——一个 hex 字符都没有，于是那句 `assert!(!audit.contains(&"ab".repeat(32)))` **空转**（fixture 里唯一的全长 hex 在 `actor` 上，而 `actor` 早有前缀掩码）。判据本身也太窄：「某个已知常量不出现在某个字段里」，漏掉的字段永远测不到。已换成**扫整个包里最长的连续 hex 串，超 24 位就红**——这条判据不认识字段名，下一个嵌了 NodeId 的新字段进包时它会自己红。反证先加强测试再改代码，所以红打在真漏的代码上：两条导出测试同时 FAILED，红输出里两份 JSON 都带着完整 hex；桌面壳那条把 `scrub` 改回 `text.to_string()` 也立刻红。**教训：脱敏白名单字段名 = 给「我只想到这几个字段」盖章；数据的形状才是不变量，判据也得挂在形状上。** |
| **MOB-33（L0）暂停改成管线级 + 进度条不再乱跳** | 2026-08-26 | 本 commit | ✅ 代码完成（Android **39 类 / 298 tests / 0 failures**，四条反证真跑；真机验收欠验收人） | 验收人真机报「暂停按钮没有任何用处」+「正在读文件后有长时间 pending，然后又展示读文件，再上传」。根因都是四条通道各自一个 unique name——原卡把后果写成「浪费不损坏」，**那个定性是错的**。`cancelManualBackup` 只取消 MANUAL 通道，而界面按 tag 观察全部通道 → 自动备份也显示进度条和暂停按钮，点下去取消不了它，而 `_state.value = Idle` 让界面当场假装停了、字节还在传；`uiStateOf` 的 `firstOrNull { RUNNING }` 在两条同时跑时随机挑 → 进度在两轮之间来回跳。验收人定的原则（与 MOB-19 一致）：**「传输只有一个路径，暂停也得在一个路径。上传不分自动手动，只有触发会区分。」** 四处改动：进程级互斥门 `backupInFlight`（一次只跑一轮）；暂停按 id 取消正在跑的那条并删掉自置 Idle；提出 `runningInfoOf` 让选取确定化且与暂停共用同一判据；进度条覆盖 M3 1.3 的 `gapSize`/`drawStopIndicator` 默认值（那道跟着进度头走的缝就是验收人说的「和背景同色的圆点在移动」，本仓 compose-bom:2024.12.01 = M3 1.3.x）。**顺带解一处不变量冲突**：新增终态返回点撞上 MOB-31 的「每个终态都要盖戳」，而直接盖戳会让空转那轮盖过用户暂停的 CANCELLED（取消拿不到 outputData → 无戳 → 被当最旧）→ 界面显示「已备份 0 张」。解法是新增 `KEY_SKIPPED`：盖戳满足不变量，同时让 `uiStateOf` 排除它——**盖戳与「别被选中」是两件事，要分开表达**。**教训（今天第三次）：守卫测试要钉不变量，钉形状会在正当重构时误伤自己**——这次误伤我的是我十分钟前刚写的那条断言。 |
| **MOB-37 重传告知落盘，通知丢了也还在** | 2026-08-26 | 本 commit | 🟡 代码已合并（Android **40 类 / 302 tests / 0 failures**，`--rerun-tasks`，XML 时间戳本次生成 + `assembleDebug`；反证真跑；**真机验收欠验收人一条**） | MOB-29 的手机端告知只有一条系统通知，而且**天然一次性**（算出 `lost` → 发通知 → `removeMissing` 剔除 → 下一轮算不出同一批）。我当初把这个一次性写成了优点（「连去重窗口都不用做」）——**那是把缺陷说成了优雅**：一次性 = 没有兜底 = 那一次发失败就永久静默（通知权限没授 / 渠道被关 / 系统丢弃 / 锁屏没看见）。2026-08-26 真机现场坐实：删 3 张 → 重传**确实发生了**（21 秒传回来），验收人**什么提示都没看到**。修法：新 `backup/ReuploadNotice.kt` 把告知**落盘**，`noteReuploadNotice` **先落盘、再发通知、并吞掉通知的异常**；两条校准门（`BackupWorker` 含收尾补校准 + `BackupUiStateHolder` 的 App 打开那次，后者只落盘不发通知——人就在看着 App）都接上；App 内一条可 acknowledge 的琥珀提示，读的**只是**盘上状态。**不重试通知**（卡面定调：重试只制造骚扰，治不了「用户当时没看」）——只在 acknowledged→unacknowledged 的跃变时发一条。张数记的是 **hash 并集不是累加计数**：MOB-33 的并发双发会让两轮看到同一批 missing，累加就把 3 张报成 6 张，一个编出来的数字。**反证第二条红得最有价值**：去掉落盘之后，通知的异常一路冒到 `calibrateConfirmed` 的 catch → `removeMissing` 被跳过 → 这批 hash 留在 `confirmed` 里 → **下一轮重新算出同一批、再发一条通知**，正好破了「不重试通知」。所以「先落盘 + 吞异常」一手守两条判据。顺带给 `UI-04` 搭了提示优先级骨架（`ui/HomeNotices.kt`：`HomeNoticeKind` + `HomeNotice` + `HOME_NOTICE_PRIORITY` + 纯函数 `topNotice` + 复用的 `NoticeCard`，已带单测），**既有几条提示刻意没迁**——迁移是 UI-04 的活且会跟进行中的 HomeScreen 改动撞车。**教训：省掉一套机制之前先问「它本来在防什么」；这里防的是投递失败，而通知投递恰恰是最不可靠的一环。** |
| **MOB-34 补记：删掉一条假的「已知边界」——存量条目本来就查得到** | 2026-08-25 | 本 commit | ✅ 已修（Android **38 类 / 290 tests / 0 failures**，反证真跑） | MOB-34 第一版把「MOB-13 之前备份的条目没有文件级记录 → 定向补偿够不着」写成已知边界，还配测试钉它，我还据此推荐了「启动时一次性全量扫描迁移」。**验收人当场质疑：「这不是一个 json 吗？为什么会丢失？重建的话 hash 算出来不一致吗？」——两条都对。** ①没有丢失，`confirmed.json` 和 hash 一直在，缺的只是「hash → 本地 _ID」这一个方向的索引；②内容哈希重算必然一致，不存在不兼容。**而且连重算都不用**：PERF-01 的 `hash-cache.json` 本身就是 `uri → hash`，键里带着 uri，而且跨版本跨配对存活（文件头明写「不放 per-remote 目录，断开配对不清理」）。修法：`reuploadTargetsOf` 改两路并集（`files` ∪ `HashCache.fileKeysOf`），两处校准门都传缓存，新增 `HashCache.fileKeysOf`；删掉假边界那条测试，换成「存量条目必须被找回」+「两种 key 形状都要认」+「两处门都必须接第二路」三条真判据；**「一次性全量迁移」方案作废**。**这个缺口特别阴：只在覆盖安装/自动更新路径上显形**（那条路径保留老格式 confirmed.json），卸载重装的机器永远复现不出来。顺带又修一条钉字面量的守卫测试（`enqueueReuploads(store.load(), reuploads, lost)` 整串），多传一个参数就误伤变红。**同一天第二次踩「守卫测试钉实现形状而不是不变量」。** **教训：把「我没想到怎么做」写成「已知边界」，是给错误结论盖了个合法的章。** |
| **MOB-35 中断待确认时前台同步不再被冻住** | 2026-08-25 | 本 commit | ✅ 代码完成（Android 全量 **267 tests / 0 failures**，反证真跑；真机验收欠验收人一条） | 真机撞到：force-stop → 停止期间拍照 → 重开 App 放前台不动 → 轮询 90 秒零上传。根因是 `MainActivity.kt` 那个 `LaunchedEffect` 里**一个 `return` 挡了两件事**——`scheduleAutoBackup`（重挂后台监听，该挡，MOB-28 红线）和 `triggerUserPresentBackup`（前台补捞，不该挡）。用户定调：「前台情况下，都无法上传，是不是不合理呢？」**前台 = 人在场 = 该传**；MOB-28 要防的是「背着用户把后台监听装回去」，不是「人在看着也不许传」。改法：`if (!backupInterrupted) scheduleAutoBackup(context)` + 无条件 `triggerUserPresentBackup(context)`。文案同步改（原文案「后台备份被停掉了，这段时间没有在跑」在前台会传之后自相矛盾）。**顺带把 MOB-28 的守卫测试从「钉形状」改成「钉不变量」**——它原来断言的是`contains("if (backupInterrupted) return@LaunchedEffect")` 这个具体写法，现在断言「重挂必须受门控」+「块内不许整块早退」，守的东西没变但不再钉死实现。**教训：守卫测试断言实现形状而不是不变量时，正当的重构会被它误伤，而它并没有多守住任何东西。** ⚠️ **同日补记：第一版漏了两处「顺带重挂」，MOB-28 红线一度被我破掉。** 前台补捞放行后，那趟 work 会跑到 `doWork` 的 `finally`，那里有句幂等的 `ensureMediaWatch`（MOB-27 留的 5h 自检），于是用户 force-stop、提示还挂着、一次「恢复」都没点，后台监听自己回来了；同款第二处是 `rescheduleAutoBackup`。**那 4 条单测抓不到它**——它们只断言那个 `LaunchedEffect` 块，破线发生在下游 work 的 finally 里。修法：新增 `mayRearmWatchIncidentally` 门控两处「顺带」重挂，`scheduleAutoBackup` 不设门（它是 `resumeAfterInterruption` 的显式入口）。补第 5 条测试，判据改成**全文级**：每一处 `ensureMediaWatch(` 要么带门控要么在显式入口函数体内；反证报出「第 369 行的 ensureMediaWatch 没有门控」。最终 **268 tests / 0 failures**。**这条是并行 agent 交接时报上来的坑，不是我自己测出来的——块级断言守不住跨函数的不变量，判据必须跟不变量同一个作用域。** |
| **DESK-10 「导出日志」不含 daemon 日志，且 daemon 挂了它自己也不工作** | 2026-08-25 | `1e1359f` + `0e0521f` | 🟡 代码已合并（`just ci` nextest **319 passed**、src-tauri **14 passed**、desktop vitest 24 passed + `vite build` 207 modules；反证真跑；**真机验收欠验收人一条**） | 同一场事故的另一面：验收人按「导出日志」把 zip 发来求助，**包里只有 1 条四天前的 diag 事件、489 字节**，而真实错误一直躺在 LaunchAgent 的 `.err` 里。更致命的是 `export_logs` 挂在 `logs.export` 这个 **daemon IPC** 上——daemon 起不来时这个按钮压根不工作，而那正是最需要日志的场景。修法：导出改为**桌面壳本地组装**（新命令 `export_logs_bundle`），收集与落盘拆出 `assemble_export`，daemon 那部分以 `Result` 传进去——**Err 不是失败路径**，只是少三份文件、多一份 `daemon-unreachable.txt`，zip 照出。包里现在有：daemon 的 stdout/stderr 日志（路径从 plist 读，取尾部 256 KiB）、`versions.txt`（App + daemon 版本；daemon 不可达时问内置服务 `--version`——真机事故里正是这一句拿到真相）、`config-summary.txt`、`log-sources.txt`、`README.txt`（先看哪个），daemon 可达时再附它那三份（daemon 侧 `export_logs` 顺带补上 `audit.json`）。脱敏不回退：家目录 → `<DATA>`，长 hex（NodeId/配对令牌）只留前 8 位，新加的文件全过同一道 scrub。文件名与落盘位置不变（`<库目录>/ppf-logs.zip`）。反证：把不可达分支改回 `return Err` → 「daemon 不可达也要出包」那条立刻变红。 |
| **dmg 拖拽窗口装不下两个图标 + 布局失败其实是致命的** | 2026-08-25 | 本 commit | ✅ 已修（真机 dmg 实测读回几何 + 算术反证 + 守卫反证，三样都真跑） | 验收人反馈「双击 dmg 打开的窗口太小，容纳不下 app 和 Applications 的图标」。**几何算错**：`bounds {100,100,520,400}` = 窗口 420 宽，而 Applications 图标中心 x=390、算上比图标更宽的文字标签（半宽约 70）横跨 320..460，**溢出内容区 40px**。改成窗口 560×360、图标中心 x=150/410，两侧都留余量。验证方式（没构建整个 App）：造一个假 dmg 应用同一段 AppleScript，再用 AppleScript **读回**实际生效值——`bounds=100,100,660,460 app=150,180 applications=410,180 iconsize=96` 全部生效。**顺带修一处潜在致命 bug**：`osascript` 之后写的是 `if [ $? -ne 0 ]; then echo "布局失败不致命"; fi`，但脚本开头是 `set -euo pipefail`——osascript 一旦非零退出脚本当场就死，那句判断永远执行不到，**注释宣称的「不致命」是假的**，无头 CI 的 TCC 拦 Apple Events 就会炸掉整个打包步骤。改成 `osascript ... || echo`。**加了防复发守卫**：四个几何常量提到 shell 里先算一遍装不装得下，装不下直接 `exit 1`（单改一处数就是本 bug 复发的入口）；反证：把宽度改回 420 → 守卫报错退出。**教训：这次的 8/6 vs 8/8 混淆说明「修过」不等于「你手上那个包里有」——先验产物版本，再查代码。** |
| **撤除 R2 发布镜像 + 本机客户端清空** | 2026-08-25 | 本 commit | ✅ 已完成（actionlint 8 workflow 零告警） | `v0.4.0-test.1` 出包时 R2 镜像 `403 Forbidden` 挂掉 release job。**诚实记录：这个 403 在 `NEXT.md:1468` 已挂账 13 天（2026-08-12），我从零重新诊断了一遍，本该先查挂账。**真实损坏面：镜像是 release job 的第 10/10 步，前九步（三平台构建+签名+公证+建草稿+上传资产+自动发 prerelease）全过——**包能下载能装**；坏的是 manifest：第 5 步就按「token 存在」把下载地址写成镜像域，第 6 步签名、第 8 步上传，等第 10 步 403 时坏 manifest 已经出门，而签名让它无法手改 → 这一版自动更新是坏的。**用户拍板整步撤除**：删掉镜像步骤（40 行）+ `ASSET_BASE` 恒指 GitHub 直链 + 删 release job 的 `HAS_CF_TOKEN`（`ci-workers.yml` 的同名门控保留，那是 update worker 部署，与镜像无关）。耦合缺陷开 `REL-04` 卡，明确标注为「重开镜像的前置条件」而非当前的活。**教训：「凭据存在」≠「能力可用」——同一个步骤里这个坑犯过两次**（8/12 是 token 无 memberships 读权限，8/25 是同一 token 无 R2 写权限）；存在性检查 `secrets.X != ''` 只能证明「配了」，证不了「配对了」。顺带按用户要求清空本机客户端：停 debug daemon、删 `Application Support/P-Pass`（config.toml）、两个 Caches（24M）、`com.p-pass.desktop.plist`、`~/ppf-daemon.log`、`~/ppf-library`（指向已不存在的 Desktop/NAS 的陈旧残留）。**照片库未动**（571M / 204 张，等用户拍板要不要一起清）。|
| **0.4.0-test.1 版本 bump + 两处挡住预发布出包的缺陷** | 2026-08-25 | 本 commit | ✅ 已完成（`just ci` all green，**318 tests passed**；反证真跑） | 用户要出 test 版「从 0.4.0 开始」。bump 后连撞两个缺陷：**① `dae_flow.rs` 的 `newer_version()` 把 `CARGO_PKG_VERSION` 当纯数字三段解析**，`0.4.0-test.1` 末段是 `0-test` → parse panic，三个 takeover 用例同时挂——**等于 test 通道那条跑道上 CI 恒红**，而预发布是发版常规路径（bump 脚本的 SemVer 校验本来就接受 `-test.N`）。修：先剥 `-`/`+` 后缀再解析；逻辑提成纯函数 `bump_patch` + 钉子 `bump_patch_survives_prerelease_versions`（挂在 `CARGO_PKG_VERSION` 上的话，版本回到纯数字三段这缺陷就又藏回去，下次出 `-test.N` 再炸一遍）。反证：去掉剥后缀那行 → 4 个用例全红。**② `bump-version.sh` 静默跳过 `src-tauri/Cargo.toml`**——第 90 行拿 `tauri.conf.json` 的版本去匹配它，而它早漂到 `0.2.1`，sed 匹配不上就 no-op；尾部断言只验「没碰不该碰的文件」，不验「该碰的都碰了」，照样报 ok。`0.2.1` 正是脚本注释里点名要防的那个 `DOG-01d` 值——**它自己又犯了一次，还悄悄犯了好几个版本**。本次手工对齐 + `cargo update -w` 同步 lock，脚本盲区开 `REL-03` 卡。版本终检五处一致（主仓/tauri.conf/package.json/desktop crate 全 `0.4.0-test.1`，android versionCode 10→11）。**教训：版本号解析器不许假设「纯数字三段」——预发布后缀是发版流程的一等公民。** |
| **进度盘点 + 文档漂移清理（验收人问询驱动）** | 2026-08-25 | 本 commit | ✅ 已完成（纯文档/卡片，零 CI；`just ci` 本机实测 **316 tests passed** 全绿） | 验收人问「进度如何、别的 agent 干得如何」，盘完发现三处文档漂移**且我把其中一处当现状转述给了用户**（事故）：①`ROADMAP` CI-01 条目写着「等用户：GitHub Secrets 加 CLOUDFLARE_API_TOKEN」，实际该 secret **两周前就在位**（用户截图 Repository secrets 佐证）——我照搬过期文档报了假挂账，**教训：「等用户」类挂账在转述前必须核实，文档里的挂账是写下那天的事实，不是今天的事实**；②`ROADMAP:7` 的「Now / 当前位置」还停在「M1 closed → next M2」，而实际 M2 已上真机狗粮、M3 代码全落地、上线三件必做已清完——ROADMAP 是验收人看状态的唯一入口，这行漂移等于入口失效；③`SITE-02` 按用户 2026-08-25 裁决降级 L3（「优先级没这么高，回头统一审稿」），从「等你拍板」移入 backlog，不再算上线阻塞。**顺带按模板开两张一直挂在 NEXT「未开卡」里的卡**（代码层已核实）：`MOB-33` 四条备份通道各自一个 unique name + `backup/` 包零互斥（`Mutex`/`synchronized`/`withLock`/`AtomicBoolean` 全零命中）→ 两个 `BackupWorker` 可并行扫同一水位重复推字节（存储端去重兜底，所以是**浪费不是损坏**）；`LINT-01` Android lint 不在 CI 里跑（`BucketScreen.kt` 那条 `ProduceStateDoesNotAssignValue` 是条件赋值误报，真问题是没门禁 = 下一条真报也会被埋）。**ci-workers 审批门定性**（用户质疑「一直占用 GitHub 机器等我点审批？」）：`environment` 拦在 runner 分配**之前**，Waiting 不占机器不计费、30 天自动作废——用户猜错但闻对了味道：那 3 个 Waiting run 全是「改 ci-workers.yml 自己」触发的（paths 包含自身，worker 代码零改动），且 `cancel-in-progress` 收不掉 Waiting 状态，每次 push 还会再堆一个。清理 5 个已合入 main 的 `worktree-agent-*` 本地分支 + 0 差异的 `site/site-02`。|
| **dependabot 5 PR 合并 + subscription 薛定谔挂起根因修复** | 2026-08-23 | `fbac929`/`2d26b57`/`ebd6ac9` + #48-52 | ✅ CI 全绿 | K3 评审抓到我删 PR 触发 + 开 dependabot 的自相矛盾（升级 PR 零检查，dependabot.yml 写的「PR→绿→合」永远等不来绿）。修复：ci-rust/ci-android/ci-desktop/site 加回 pull_request（paths 只含 .github/workflows/** + 依赖清单，业务代码 PR 仍不跑，额度不多花）；ci-workers concurrency group 按环境命名（ci-workers-prod，防将来 test/prod 互 cancel，用户红线：环境隔离）。合并 5 个 dependabot PR（#48-52，checkout 4→7 / cache 4→6 / setup-java 4→5 / upload-pages-artifact 3→5 / install-action 2.85→2.86），逐个 update-branch 消冲突、全绿才合（#52 checkout 大跳与 #50 setup-java 同文件冲突，手动取双侧新 SHA）。合并后 main CI 抓出真 bug：`subscription_delivers_pending_change_under_100ms` 300s 挂起（313/314 过，本地恒绿=薛定谔红）——根因 events.subscribe 先写 Resp 应答、后 subscribe() 建 receiver，broadcast 无订阅者时 send 丢弃（events.rs 契约），客户端收到 Resp 立即 emit 的事件被丢。修复：receiver 先于 Resp 创建（Resp 语义=订阅已生效）。site workflow 顺带修两处：concurrency group 裸 pages 让 5 PR 并行互 cancel、deploy job 在 PR 上 0s fail（加 if 只 push 跑）。**教训：删 PR 触发必须同时想 dependabot；subscribe 类接口的「应答即生效」语义要保证 receiver 先注册；concurrency group 要么带 ref 要么带环境。** |
| **CI 重构第二波：workers 审批门 + 全 action pin + 删 PR 双触发 + 工具链核实** | 2026-08-23 | `776e0aa` | ✅ CI 全绿（Rust 5 job / Desktop / Android / site；workers 审批门停在 waiting 等 owner 批准） | 承接首波（拆并行 + dogfood release），用户拍板四条：**① workers 部署挂审批门**——新建 `workers-prod` environment（required_reviewers = owner 25927625 + branch policy），push 仍自动触发但部署前暂停等批准（CI/CD 分离第一步）；API 实测：protection-rules POST 端点 404，正确姿势是 PUT environment 时 body 带 `reviewers` 数组。**② nightly 通知**——用户听完目的后拍板「不通知，push 代码留工作记录」（工作留痕 = PROGRESS/NEXT 既有机制，不建通知渠道）。**③ 全 action pin SHA + dependabot**——ci-desktop/site/workers 的裸 `@v4`/`@stable` 全部换 commit SHA（checkout/cache/setup-node/upload-pages-artifact/deploy-pages/rust-toolchain），新增 `.github/dependabot.yml`（github-actions 每周一检查，PR 升级 CI 兜底；首次检查已跑成功）。**④ BUILD-02 工具链钉扎核实**——CI 日志实证 `rustc 1.98.0 (88d9e12ae)` + `overridden by rust-toolchain.toml`，钉扎确认生效。**⑤ 删 PR 触发**——ci-rust/ci-android/ci-desktop 的 pull_request 块删除（直推 main 阶段 PR 事件用不上，同一 commit 双触发白烧额度）；e2e 的 PR labeled 触发是选择性门禁保留。**教训：GitHub Environment 审批门 = push 自动触发 + 部署前人工批准，API 配 required_reviewers 用 PUT environment 带 reviewers 数组（POST protection-rules 端点 404）；CI 工作留痕靠交付文档不靠通知。** |
| **CI 重构：Rust 域拆并行 job + 产物分发改 GitHub Release** | 2026-08-23 | `3c5ac8a`/`901be17` | ✅ CI 全绿 + dogfood release 资产在位 | 用户盘问「CI 跑的必要吗？必要的对吗？业内标准做法？」后拍板两件事：**① ci-rust.yml 拆并行**——5 个 gate（fmt/clippy/test/arch-check/deny）从单 job 串行 fail-fast 改为独立并行 job（8/22 四层洋葱的根：一层红藏一层，deny 层从未被跑到）；cache key 各 job 带前缀防并行写竞争。**② artifacts.yml 弃 git 孤儿分支**——bin-linux-x64/bin-macos-arm64/bin-win-x64 force-push 是业内反模式（对象库膨胀 3.3GB 教训、无审计），改为固定 `dogfood` prerelease：tag 只建一次（不违反 tag 纪律）、每次 push clobber 资产，消费方 `gh release download` / curl 免认证拉取；race-safe 处理（macos/linux 并行首建竞争 || true 吸收）。首跑抓出真 bug：gh 在非 git 目录（/tmp）无法推断仓库——所有 gh 命令显式 `--repo $GITHUB_REPOSITORY` 修复。同步更新消费方（win-smoke.ps1/dogfood-deploy.md/windows-smoke.md/README×2/CLAUDE.md 仓库卫生节）。验收：CI Rust 5 job 并行全绿（fmt+actionlint/clippy/test/arch/deny），Linux Artifacts 绿，`gh release view dogfood` 资产 8 项在位（macos tar/linux daemon+testclient/SUMS×2/INFO×2/smoke.sh）。**教训：fail-fast 串行 gate 是洋葱，并行 job 让一次 run 暴露全部问题；git 不装二进制，分发走 Release/对象存储；gh 命令在非 git cwd 必须 --repo。** |
| **CI Rust 解红：四层洋葱一次剥完** | 2026-08-22 | `e3d50b4`/`6276427`/`e68e4f4`/`b3e443a`/`d610ebc` | ✅ CI 全绿（run 32581234995：fmt+clippy+314 测试+arch-check+deny） | WATCH-07 push 后发现 **CI Rust 从 8/21 起一直红**——fail-fast 让每层红掩盖下一层，本地 `just ci`（macOS）全绿所以没人察觉，「CI 绿不过夜」破了一天。逐层取证修复：**①** `fsevents_shapes` 钉的是 FSEvents 专属不变量（句柄不绑 inode），inotify 下必失败——先加 cfg 门撞 arch-check B.2，改移入 `crates/platform/tests/`（B.2 立法本意）；**②** `subscribe_flow` 的 Fixture 没持有 TempDir，setup 返回目录即删，连接池新开连接炸 code 14——macOS 靠连接复用侥幸绿（薛定谔的绿），持有即修；**③** `commit_batch_emits` 断言「恰好一次 emit」依赖 1s 节流窗口在批中不到点，CI 高负载下窗口必到点——`with_events_and_window` 注入 1h 窗口把墙钟运气变结构性不可能（机制归 Throttle 单测）；**④** h2 0.4.15 有 RUSTSEC-2026-0258（低危），cargo-deny 层从未跑到——升 0.4.18。**教训：fail-fast 的红是洋葱，修红必须盯到整条流水线绿，不是第一个红消失就停。** |
| **WATCH-07 活动流被自触发 `ingest.duplicate` 刷屏** | 2026-08-22 | 本 commit | ✅ 代码完成（core-index 全绿 + 反证；真机验收欠用户一条） | 根因证实：备份管线 `place()` 后 watcher 对同一文件再 ingest，全判 Duplicate 各写一条审计（12 张→12 条）。按用户拍板的方案 2 修：Duplicate 分支加 `is_recorded_file()`，被 ingest 路径 == 索引记录路径（canonicalize 双侧，防 /var vs /private/var）→ 复检不是事件，不写审计；不同路径同内容仍记。新增 2 测试（复检无审计行 / 异路径仍审计）+ 既有 `ingest_is_audited_to_device_granularity` 保持绿；反证实跑：去掉判定新测试立刻红。同批与用户定稿**审计设计规矩**（只记数据层面事件、语义稳定因业务会读——PRES-01 实例、防「展示对实际错」靠对账），写进卡备注。 |
| **文档卫生批次：任务卡模板化 + 本机状态移出 git** | 2026-08-22 | 本 commit | ✅ 已完成（纯文档，零 CI） | 用户批评两条成立：①TODO 条目「没头没脑」无标准格式；②本机路径/设备序列号混进远端仓库。整改：新建 `cards/TEMPLATE.md` 统一卡模板（问题/期望行为/验收标准/范围/阻塞五段必填 + 状态横幅三档），`AGENT_PROTOCOL.md` §C.2 与 cards README 联动更新；21 张活跃卡全部按模板重写；`docs/CHECKLIST.md` 重写为纯索引（卡是唯一事实源）；本机环境状态（库路径/NodeId/设备/旧副本/adb 取证命令/本机对账命令 + 三个本机待答问题）移到 `cards/../local-state.md`（已 gitignore，不进 git）；全仓脱敏：测试机序列号 → `<测试机>`、开发机用户名路径 → `~`、旧副本目录名泛化（含 done/ 归档卡与 MediaWatchJobTest 注释）。残留：jniLibs 里的 `libiroh_ffi.so` 二进制内嵌了本机构建路径，下次 CI 重建 ffi 库时自然消除。 |
| **真机验收一轮：连拍空窗/查看页按钮/三元组刷新/保存去重 六条修复** | 2026-08-19 | 本 commit | ✅ 已实现（`--rerun-tasks` **207/207** 绿 + 逐条反证；真机截图确认） | 用户真机走完整验收流程报 6 个问题，逐条定位：**①连拍中途断**——监听 work 与干活 work 是同一个，备份跑多久监听就断多久（用户实测"前面的出去了，后面的就没有同步"）；当轮治标（重挂延迟 15s→1s、rearm 后按 `catchUp = batchSize > 0` 补捞，只在有照片时补以免无限循环），**用户当场指出这是治标**"你强行用时间来做判断的话不太合适，假设重挂超过 1-2 秒中间还是有 gap"——完全正确，根治方案已整理成 MOB-27 未实施。**②查看页只剩图片**——`Box(fillMaxSize())` 吃掉全部剩余高度把底部「保存/分享」顶出屏幕，按钮一直在只是看不见；照片页视频页同病均改 `weight(1f)`；与 ICON-02 无关（PhotosScreen 那轮没被动过）。**③「已回家」显示 0**——数据层一直正确（confirmed.json 165 条、范围内 142 条，设备实测 N=139图+3视频=142），根因是 `refreshTriplet` 只在 init/手动备份/补齐后跑，后台 worker 跑完不通知 UI；改为按 tag 订阅 BackupWorker 状态流（四条自动通道共用它）。**④新选相册不同步**——上一轮的水位归零验证通过。**⑤保存到相册重复写文件**——实测 `P-Pass-<hash>.jpg` 与 `P-Pass-<hash> (1).jpg` 同 hash 两份；文件名本就带内容 hash，保存前查 DISPLAY_NAME 去重，返回 `SaveResult(uri, alreadyExisted)` 并区分文案（用户"点一下闪了下没响应"正是他点第二次的原因）；顺带确认「保存→上传→保存」循环不存在（Pictures/P-Pass 是独立相册，新相册默认不勾选 + hash 去重两道）。**⑥force-stop 检测撤除**——用户拍板 pending：WorkManager 的 `ForceStopRunnable` 跑在 androidx.startup 的 ContentProvider 里、比 `Application.onCreate` 还早就重排了 work，"检测到中断→只提示不恢复"应用层实现不了，留着只会显示语义不诚实的提示；`BackupHealth.kt` 保留但无人调用（「两边对账」判据是真机验证过的正确结论）。新增 backlog：MOB-18/25/26；新增待办 MOB-27。 |
| **MOB-09/13/18 + ICON-02 四卡批次（三个 sub-agent 并行 + 验收人抽检）** | 2026-08-19 | 本 commit | ✅ 代码完成（`--rerun-tasks` **206/206** 绿 + 逐卡反证复现；**真机验收全部欠着**，卡均未移入 done/） | **MOB-09** 一条「有记录没文件」的坏 MediaStore 条目会让整批备份 ENOENT 失败并无限重试、watermark 不推进 = 永久卡死该设备备份；新增 `buildCandidates()` 逐条隔离。实施中挖出卡面没写的两件：①缓存洞——`hashWithCache` 命中缓存时不调 open，「上轮哈希过、之后被删」的记录带旧 hash 溜到 `pushFile` 才炸，加探针 `open().use { }`；②整批读不了则不推水位（全批失败更可能是权限被撤/存储卸载，推水位=把这批照片永久跳过，真丢数据）。**MOB-13** `K = N - M` 单位不一致（M 数 hash、N 数文件），相册有内容重复照片时 K 恒 > 0；`ConfirmedState` 增记文件级标识，M 改按文件数，迁移期按「无文件记录的存量 hash 回退老口径」混合计数，补齐时机=一次手动备份（含 `fresh.isEmpty()` 早退分支，否则存量用户按几次都修不好）。两卡交叉不变量：MOB-09 的隔离打破 `candidates == scan.items` 1:1，MOB-13 的 `fileEntriesOf` 依赖它，解法是 `CandidateBuild.kept` + 长度不符时整体降级空 map。**MOB-18** force-stop 会清空全部 job 而权限/配对都还在（既有三张引导卡一张不亮），加 `isBackupScheduled` 主动查询 + 琥珀提示条；用户定调"必须点了才恢复，你都提示了就别自作主张"，故检测到即 `return@thread` 只记录不重排，恢复唯一入口是用户点按钮。**ICON-02** 桌面 5 个手写 SVG path → `@lucide/svelte`（headless Chromium 实测渲染属性与旧图逐项一致 + 截图对照）；Android 只换 `ic_share` → `Icons.Filled.Share`（隔离 worktree 实测 APK **小 759 字节**——core 集本就随 material3 进包），`ic_notification` 是平台硬约束（`setSmallIcon` 收 resource id，SystemUI 进程外渲染）、`TabIcons` 手绘相机+齿轮不换（core 集无相机类，extended 在无 R8 的 release 下要塞几 MB）。**验收人抽检**：MOB-09 隔离改回 rethrow → 3 测试红；MOB-13 退回 `M = confirmed.size` → 5 测试红且 FIX-T6 既有范围测试保持绿（证明判据不宽泛）。⚠️ 两处假绿教训：源码级断言 `src.contains(...)` 把生产代码注释掉照样通过，`BadMediaRecordTest.codeOf()` 因此连 KDoc/块注释一起剥。 |
| **MOB-10 删除「仅充电」改用「电量不低」 + 锁定竖屏 + 自动备份开关放回** | 2026-08-19 | 本 commit | ✅ 已实现并真机验证（`--rerun-tasks` **181/181** 绿 + 反证；**拔掉电源放电中**实测 4.7 秒送达） | 用户拍板"因为我们能耗很低，如果不好实现，我们把仅充电删除"。`requiresCharging` 整个删掉（连同设置页开关与 `BackupSettingsState.chargeOnly` 字段），后台档改恒定 `setRequiresBatteryNotLow(true)`——`batteryNotLow` 不受充电状态影响，才是"别在快没电时折腾"的真实意图，"必须正在充电"只是坏代理；局域网 P2P 传照片能耗不是瓶颈。**触发本次改动的现场**：用户报"连拍之后没有触发同步"，日志显示不是没触发而是触发后被掐——`stopReason=CONSTRAINT_CHARGING(6)`，30~2362ms 内反复被杀，因为该机 `AC powered:true` 但 `status:3 DISCHARGING`（保护电池到上限）。**验收**：拔掉电源、放电中（改前必被掐的最严苛场景）拍照 10:20:31 → 10:20:35.769 `offered=5 pushed=5 ingested=5` SUCCESS，4.7 秒，并把此前被 charging 挡下的积压照片一并补传（印证"约束不满足只是排队等，照片不丢"）。反证：把 `setRequiresCharging` 加回 → `charging_constraint_is_gone_for_good` 立刻红。升级路径：旧 json 的 `chargeOnly` 由 `ignoreUnknownKeys` 忽略、`wifiOnly` 原样读出（有显式测试，防止悄悄把用户关掉的「仅 WiFi」打开）。同批：`android:screenOrientation="portrait"` 锁定竖屏（用户："不允许横屏，没有这个必要吧"）。 |
| **MOB-11 同步节奏改为尽快送达 + 仅充电文案删除 + i18n 漂移修红** | 2026-08-18 | 本 commit | ✅ 已实现并真机验证（`--rerun-tasks` **179/179** 绿；真机端到端 **1.6 秒**，改前 2 分 03 秒） | 用户定稿"不强行搞 2 分钟 delay，延迟一秒防连拍就快速发起"。`CONTENT_UPDATE_DELAY_MS` 2min→1s、`CONTENT_MAX_DELAY_MS` 15min→30s。⚠️ **2026-08-19 更正**：本行初版写的"连拍会被不断重置、要等满 15min 才触发"是**错的**（用户当场戳穿"我们避免事件爆炸，不是避免触发事件"）。`setTriggerContentUpdateDelay` 是**尾沿防抖**，连拍结束后 1s 只发一次，1s 能聚合任意长度连拍，有限连拍永远到不了 max delay。max delay 15min→30s 的真实理由是另一个：触发器挂在整个集合上，截图/IM 收图等**持续** churn 会让 1s 静默窗口永远等不到，max delay 是从第一次变化起算的强制闸，防饿死。测试回归锁 `MAX <= UPDATE*60` 保留，断言理由已重写。真机实测注册参数 `+1s0ms/+30s0ms`，拍照 17:38:52 → 17:38:54.593 发起备份 = **1.6 秒**。同批删掉「仅充电时备份」后果解释文案（用户反馈"解释不清楚，白白占用空间"），仅 Wi-Fi 的提示保留。**顺带修掉 main 上的既有红**：`assets/i18n/` 新增 `ui.photos_yesterday`/`ui.photos_week` 后 Android 捆绑副本未同步，`DiagTextTest` 漂移守卫红——该红被 gradle 增量构建掩盖已久，**验收 Android 测试须用 `--rerun-tasks`**。 |
| **MOB-08 后台自动同步不生效——三根因定位 + 修复** | 2026-08-18 | 本 commit | ✅ **已完成并通过用户真机验收**（android **179/179** 绿 + 反证 + lint NewApi 清零；卸载重装干净环境下真实相机拍照两张，端到端延迟均 **2 分 03 秒** = 2min 安静窗口 + ~3s 传输，第二张全程未开 App 也自动送达） | 用户报"三星手机后台不主动同步"。定位到三个独立根因，前两个是自家代码 bug、**与三星无关**（上一轮"怀疑 One UI OEM 后台限制"被证据否掉——该 job 的系统约束全程全绿，同机其它 app 的 content trigger 正常翻转）：**A** `addContentUriTrigger(it, false)`——MediaProvider 通知的是带行 id 的 item URI，精确匹配收不到，content trigger 从未触发；改 `true` 后真机实测 constraint history 在插入后恰好 ~2min（安静窗口）翻转、`Changed URIs` 出现 item URI。**B** content trigger 是 OneTimeWork，跑完进终态监听即消失，`doWork()` 里没有任何重新 enqueue——"后台自动同步"实际只在开过 App 之后的第一张照片有效；用独立 name 的中转 `ContentTriggerRearmWorker` 修（不能在 doWork 里 REPLACE 同名 unique work，那会取消正在跑的自己）。**C** 现象 2 的 `JobCancellationException` 不是代码 bug 而是排查前提错了——手机插着 USB 但 `status:4 NOT_CHARGING`，JobScheduler 认为 CHARGING 满足并放行、WorkManager 的 `BatteryChargingTracker` 认为没充电，job 起来同一瞬间被停；它顺带暴露三个真实缺陷并一并修掉：`setForeground()` 原在 `try` 之外（最常见失败路径连日志都没有）、cancellation 被当业务失败吞掉（污染失败计数+可能误发失败通知）、`client.close()` 在取消路径跑不到（连接泄漏，改 `NonCancellable`）。**修复实证**：真机跑通 `auto backup: offered=15 pushed=15 ingested=14` + `Worker result SUCCESS` + `reschedule=false`（终态，未修复版正是死在这），27s 后 rearm 成功、新 ct job 顶上；再模拟一张（全程不碰 App）又触发一轮并再次续上监听。电脑端收到 15 个文件，**含用户当天 13:47 真实拍摄的照片/视频**（此前一直滞留手机未同步）。**真机验收读数**：15:57:44 拍→15:59:47 到达、16:02:17 拍→16:04:20 到达；rearm 29~41ms 续挂；关「仅充电」前那次触发被新仪器化当场抓出 `cancelled by system after 20ms, stopReason=CONSTRAINT_CHARGING(6)`——修复前这里只有一句无信息量的 `JobCancellationException`，正是上一轮误判成「三星 OEM 限制」的那条。**注意**：验收前必须关掉「仅充电」，因为该机开着三星保护电池（`protect_battery=2`）充到 80% 上限即 `NOT_CHARGING`，产品默认 `chargeOnly=true` 在此等于后台档永不满足——这是 MOB-10 的范围，与本卡三根因无关。**顺带开卡**：MOB-09（一条"有记录没文件"的坏 MediaStore 条目让整批备份 ENOENT 失败并无限重试，等于永久卡死该设备备份）、MOB-10（"仅充电"档在插线但系统判未充电时静默失效且无提示，含待用户拍板的产品决策点）。 |
| **真机走查续十七反馈——扫码圆角裁剪/设置页"更多"隐藏/相册回退tab错乱/存储详情二级页tab未隐藏** | 2026-08-18 | 本 commit | ✅ 已实现（android 全量 **177/177** 绿，`assembleDebug` 绿；真机验收待用户） | 用户真机走查续十七那批后追加四点，逐条修复：①扫码取景框裁剪只套在摄像头预览本身上，不再套外层 240dp 方框（原来外层裁一次会把 `ViewfinderFrame` 画在方框物理边缘的四角括号尖角一并削掉）；②设置页"更多"卡（暂停自动备份+手动备份入口）先隐藏——用户拍板"默认自动备份，不提供手动触发"，底层机制不删（`AutoBackupPrefs`/`onBackupNow` 仍被失败重试/暂停按钮复用），只是这张卡的 UI 先不露出；③相册选择页回退后错误跳到照片 tab——根因 `tab` 状态原来 remember 在 `Screen.Home` 分支内部，`Screen.Buckets` 是独立顶层 Screen，回退时 Home 分支重新构建导致状态重置，提到 `PPassApp` 顶层修复；④存储电脑详情二级页时底部 Photos/设置 tab 栏仍显示——新增 `onStorageDetailOpenChange` 回调，跟大图查看页同款机制把"是否在二级页"提到顶层控制 `TwoTabs.showTabBar`。**新发现挂账**：用户随后问"后台是不是不主动同步"，现场用 `adb shell content insert` 直接走 `ContentProvider.insert()` 真实代码路径测试，确认 content trigger（新照片落库触发）在充电+Wi-Fi 都满足的条件下从未触发，周期任务（6h兜底）触发了但报 `JobCancellationException` 退出重试——开新卡 `MOB-08` 记录完整排查证据，留给下一 session 用真实拍照复现+定位根因（怀疑三星 One UI 的 OEM 级后台限制）。 |
| **真机走查续十六反馈——M2/M3/M4/M6/M10/M11/M12 七处修复** | 2026-08-18 | 本 commit | ✅ 已实现（android 全量 **177/177**（182-5，删掉死代码自己的测试）绿，`assembleDebug` 绿，`StringsSymmetryTest` 2/2 绿） | 用户逐条挑出具体问题：①M2 摄像头预览改裁到 240dp 圆角窗口内,窗口外纯黑(之前摄像头铺满全屏);②M3 输入框真 bug——之前用 Text 纯展示导致打不了字/长按无粘贴菜单,改成真实 BasicTextField;③M4 去掉 Joined 中间页,桌面允许后直接进选相册;④M6 删掉装饰圆点+只在 onboarding 首次(`firstTime`参数)显示,设置页重选不再打扰;⑤M10 cell 行高统一 52dp、"备份"卡改 4 个直接行(相册导航+仅充电/仅WiFi/失败通知 3 个真开关,删掉想当然加的"什么时候备份"子页和死函数 policySentenceKey/timingSummaryKey)、"失败通知"落地成真实偏好 NotifyOnFailurePrefs、"存储电脑/版本"独立"其他"卡、"暂停/立即备份"挪"更多"卡;⑥M11/12 信息卡改状态点+设备名+"已连接·最近同步\n配对日期·存了N张照片"(Pairing 新增 pairedAt 字段,老数据诚实显示为未知不编造),断开按钮统一 48dp。 |
| **M2/M3/M5 结构性重做——上一轮审查不够穷尽** | 2026-08-18 | 本 commit | ✅ 已实现（android 全量 **182/182** 绿，`assembleDebug` 绿） | 用户装上上一批小修后反馈"完全对不齐"——如实承认上一轮不是逐页系统走查，是抽查了几个点。这次真正逐张核对 M1-M13，发现 onboarding 前 5 步里 3 张结构性对不上（比上一轮任何一条差距都大）：①M2 扫码页从"大标题+方框+取消按钮"重做成"暗底窄标题栏(✕关闭)+四角括号取景框(Canvas手绘)+底部纯文字链接"；②M3 手动输入配对串从内联展开改成独立子页 `ManualPairScreen`（返回箭头+说明段+单行占位框+粘贴胶囊按钮+连接主按钮）；③M5 选相册从竖排复选框列表改成2列封面卡片网格（右上角圆形勾选角标+总结句+单个"开始备份"按钮），这个改动是全局的（onboarding 和设置页重选共用同一个 `BucketScreen`）。M1/M4文案/M6/M10-M13 复查确认已对齐。M7/M8 的月份分组+↑↓状态角标+图例仍未做，是下一批。 |
| **对照《全页面状态稿》补 4 处 mobile UI 差距** | 2026-08-18 | 本 commit | ✅ 已实现（android 全量 **182/182** 绿，`assembleDebug` 绿） | 用 `claude_design` MCP 拉到新增的 `P-Pass 全页面状态稿.dc.html`（M1-M13 手机端每页每态静态稿）逐页核对当前代码，发现 7 处差距。已实现 4 处纯 mobile 端能做的：①大图页底部按钮改回"保存+分享"（原来是保存+用其他应用打开，分享在右上角图标）；②`TwoTabs.kt` 加 tab 图标（新增 `TabIcons.kt`，Canvas 手绘相机/齿轮，不引入图标库避免跟排期中的 ICON-02 迁移卡打架）；③设置 tab 加哨兵态红点（`settingsAlert` 参数，`pairingLost` 时齿轮图标角标——跟上一轮否掉的"备份!"文字变红方案是两回事，那个是文字，这个是图标角标）；④补 M6 选相册完成页（新增 `Screen.Started` + `BackupStartedScreen`，触发首次备份后先过一遍"{N}张照片正在回家"再进 Home）。另外 3 处（M9 归因真名字/M8 按姓名分 chip/M4 等待页显示电脑名）都卡在协议层缺口（`AssetMeta` 无 `src_device`、QR 不带设备名字段），明确记录不在本轮做，详见 NEXT.md。 |
| **用 claude_design MCP 核对设计稿——断开连接改回点按钮确认+tab文案改回"设置"** | 2026-08-17 | 本 commit | ✅ 已实现（android 全量 **182/182** 绿，`assembleDebug` 绿） | 用官方 `claude_design` MCP 直接读 claude.ai/design 项目 `P-Pass 设计稿交付` 的 `P-Pass 布局与交互.dc.html` 纯文本源码核对（比之前另开浏览器渲染 8MB atomics 导出精确），发现续十二那轮照一份更早设计稿快照（"离线版3"）实现的两处东西做反了：①"断开连接"不是滑动确认，原文是"三层防误触"——存储电脑详情页最底部红色描边按钮→点了展开"确定断开吗？"确认卡→"确认断开"按钮，完全没有滑动手势；删掉自绘 `SwipeToConfirm`，改用 `armed` 布尔状态切换按钮/卡片，顺手删掉一套更老的、这次改动前会跟详情页确认叠加成两层确认的 `showDisconnectDialog`/`AlertDialog` 遗留代码，`onDisconnect` 现在直接是真正的断开逻辑（unpair+清本地pairing+回Welcome）。②tab 文案改回"设置"（`dc.html` 原文是写死的静态文本，不随配对失效/电池未加白等状态变红变"备份 !"）——`TwoTabs.kt` 的 `backupNeedsAttention`/`alert` 分支整删。**顺带发现并记录**：`adb install -r` 不会杀掉正在运行的旧进程，之前几轮重装如果没配合 `adb shell am force-stop`，装的新代码可能一直没被加载过，以后每次重装完都补一次 force-stop。 |
| **配对成功直接进选相册——onboarding 权限/条件步骤整个删除** | 2026-08-17 | 本 commit | ✅ 已实现（android 全量 **182/182**（183-1）绿，`assembleDebug` 绿） | 用户拍板"onboarding 123步骤都是多余，就申请一个图片的权限"，比上一轮（只砍通知/电池两行）更进一步——连"系统权限（仅照片）"这一屏也整个删掉。用浏览器实际渲染 dc.html 找到直接依据：设计稿"决策：只有「选相册」进 onboarding，其余给默认值，设置页随时改"+ 第一轮原始流程标注"桌面点允许 → 直接进 Home，第一个页面是相册范围选择"——跟用户方向一致，"先给3个权限"那屏是被这条决策覆盖的过时草稿。`Screen.Joined.onDone` 直接调 `enterBucketPicker`（选相册页本来就有完整权限链，读取照片权限就是打开这页顺带弹的系统对话框，不需要额外解释屏）；删掉 `Screen.OnboardPermissions`/`OnboardConditions` 两个状态分支 + `fromOnboarding` 全部相关字段；设置页"重新查看引导"入口一并删除。清理死代码：`OnboardingSteps.kt`/`backup/OnboardingPermissions.kt`/`OnboardingPermissionsTest.kt` 三文件整个删除、`hasFullMediaAccess`（零调用点）删除、strings.xml en/zh 各清 13 个孤儿字符串。通知/忽略电池优化两项不受影响，继续走既有契机式提醒。 |
| **备份页/照片页对齐设计稿截图+dc.html 原文** | 2026-08-17 | 本 commit | ✅ 已实现（android 全量 **183/183**（+4 `timingSummaryKey` 单测）绿，`assembleDebug` 绿，`StringsSymmetryTest` 2/2 绿） | 用户先发 3 张截图（欢迎/备份/照片失联态），随后用浏览器实际渲染 dc.html 核对出几处比截图更精确的原文，两批指令合并实施，详见 NEXT.md 本条目完整记录。①备份页英雄卡数字加千分位分组，进行中状态改"正在备份 {文件名}（第 x / y 张）"（`BackupRunner.onProgress` 加文件名参数，数据本来就在 `Candidate.fileName`）；②备份规则卡收缩成 4 行 cell（备份哪些相册/什么时候备份/通知/存储电脑），仅充电/仅WiFi 两个开关折进"什么时候备份"详情子页，原有功能行（暂停/版本/重看引导/立即备份）挪到单独"更多"卡不删功能；③**dc.html 原文纠偏**——"断开连接"不是"间距+卡片"方案，是"收进「存储电脑」详情页最底部+滑动确认才生效"，新写 `SwipeToConfirm` 自绘拖拽控件（Material3 无现成组件）替换原来的点击+系统弹窗二次确认；④照片页新增失联红卡，逐字对齐 dc.html（"和家里的电脑失去了联系"等），天数复用既有 `SentinelStore.lastReachableAt`（SENT-01）推算不编数据；⑤底部 tab 栏文案改回"备份"/"备份 !"（UX-09 当年改"设置"的理由已不成立，现在页面本来就是备份进度为主）。诚实挂账：存储电脑名字要等下次配对才刷新（无主动查询协议）；滑动手势没有独立 Compose 手势测试；桌面端设备行是否同步亮红未核实（用户原话"不是本次重点"）。 |
| **onboarding「系统权限」步骤收缩为仅照片权限** | 2026-08-17 | 本 commit | ✅ 已实现（android 全量 **179/179**（189-10）绿，`assembleDebug` 绿；已重装真机） | 用户实机走查后拍板：通知 + 忽略电池优化从 onboarding 里整个拿掉，只留读取照片（必需）。理由：占一屏 onboarding 换来的只是「弹窗前多一句解释」，两项都可跳过，既有的契机式提醒（`HomeScreen.kt` 的电池白名单卡 + 通知引导卡，均只看当前授权状态，跟 onboarding 无关）已经能接住后续补授权的需求。删掉整套现在零消费者的 `OnboardingAskState`/`OnboardingPermissionsStore`/`shouldOfferNotificationPermission`/`shouldOfferBatteryWhitelist`（不留死代码），`PermissionRow` 组件顺手简掉恒为 null 的 `onSkip` 分支，`strings.xml` en/zh 各清 5 个孤儿字符串。`OnboardingPermissionsTest` 11 例减到 1 例（删的是被删函数自己的测试）。 |
| **Android 四项 UI/交互修复——真机走查续二** | 2026-08-17 | 本 commit | ✅ 已实现（android 全量 **189/189** 绿，`assembleDebug` 绿；本轮为布局/导航接线改动，未新增可测纯函数） | 用户真机走查上一轮落地后追加四点，逐条修复，详见 NEXT.md 本条目完整记录。①备份页"状态摘要句"（`policySentenceKey`）挪出设置卡片，单独一行大字号呈现，不再跟可点设置行长得一样；②照片页"N 张·已去重"副标题无信息量，直接删除（无现成时间戳数据源，不编数据），顺手清理 `strings.xml` en/zh 里因此变孤儿的 `photos_count_dedup`；③"断开连接"行改用主流危险操作隔离手法（间距 10dp→40dp + 独立描边卡片），降低滚动误触概率，既有的二次确认弹窗不变；④**结构性 bug**——大图查看页显示时底部仍渲染主 `[照片]/[设置]` tab 栏（根因：`PhotosScreen` 内部管理"打开的大图"状态，`TwoTabs` 外层 tab 栏对此一无所知），修复为 `TwoTabs` 新增 `showTabBar` 参数（`false` 时 tab 栏 Row 根本不进组合树）+ `PhotosScreen` 新增 `onViewerOpenChange` 回调冒泡通知 `MainActivity`，改动面小、不碰既有 `loader`/`mine` 数据流。 |
| **Android 三项 UI/流程功能——onboarding 权限步骤 + 大图归因 + 备份页重看入口** | 2026-08-17 | 本 commit | ✅ 已实现（android 全量 **189/189** 绿，新增 `OnboardingPermissionsTest` 11 项；`assembleDebug` 绿；真机验收待用户） | 用户给设计规格三条，逐条落地，详见 NEXT.md 本条目完整记录。①手机配对成功后插入「系统权限」→（选相册，复用既有 BucketScreen）→「备份条件」三步：新 `ui/OnboardingSteps.kt` + `backup/OnboardingPermissions.kt`（纯函数判定 + 持久化「是否已问过一次」，跳过后本轮不再重复弹系统对话框）；读取照片必需，通知/忽略电池优化可跳过并各自说明用途——**顺带补上本 session 早些时候诊断出的真 bug**：Android 端此前全仓库零处主动申请过 `POST_NOTIFICATIONS`，Android 13+ 不主动申请永远拒绝，导致失败通知机制即使检测到问题也发不出提醒；设置页新增「重新查看引导」入口 + 通知权限的不堵路引导卡（跟已有的电池白名单卡同款风格）。②大图页归因：网格不标来源，只有大图才显示「来自 XX · 日期」，深底复用已有的 `PPColor.SurfaceDark`。**诚实挂账**：`proto.AssetMeta` 目前没有 `src_device` 字段（独立卡 SYNC-05 的范围，本次未顺手做 proto/daemon 改动），拿不到具体设备名，用已有的 `mine`（T-080 轻过滤器同款数据源）近似区分「你自己传的」/「不是你传的」，后者笼统标「家人的手机」不编造具体名字；「保存到手机」取回入口复用既有的「保存到相册」按钮（本来就对所有资产可用），未新增重复入口；手机端未新增任何删除类危险操作。③备份页信息架构：现有 `HomeScreen.kt` 已经覆盖设计稿要求的「进度/规则/白名单建议」三块，未推倒重写，只加了①提到的两处入口。④顺手修复一处无关但阻塞测试绿的漂移：`DiagTextTest` 的 i18n 捆绑副本漂移守卫是红的——根因是当天早些时候桌面端改动往共享 `assets/i18n/*.json` 加了新 key，Android 端捆绑副本没跟着同步，直接复制源文件覆盖修复。 |
| **reset-local.sh 清场脚本真 bug 修复——pkill 相对路径不匹配** | 2026-08-17 | 本 commit | ✅ 已实现（`pgrep` 反证：修复前对真实 `pnpm tauri dev` 会话返回空/exit 1，修复后能匹配到进程；语法检查绿；未杀用户正在用的活跃会话，改动等下次重启生效） | 用户复测发现"清数据清得不够彻底"：桌面端数据（sqlite/照片库）已确认清空，但正在跑的桌面壳窗口里照片墙依然显示清场前的旧缩略图。**根因不在数据层，在清场脚本本身**：`reset-local.sh` 第 3 步 kill 桌面壳/daemon 用的 pattern 写的是 `pkill -f '/target/(debug|release)/p-pass-desktop'`（带前导 `/`），但 `pnpm tauri dev` 是从 `apps/desktop/src-tauri` 这个 cwd 启动子进程的，进程 argv 里存的是**相对路径** `target/debug/p-pass-desktop`（没有前导 `/`）——`pkill -f` 是子串匹配，这个前导 `/` 在真实命令行里根本不存在，pattern 从来没匹配上过，桌面壳网页进程在"清场"全程存活。更隐蔽的是脚本自己的"验证清场"步骤复用了同一个带前导 `/` 的 pattern，导致自检也一起谎报"✅ 无残留进程"，没有任何环节能发现这个 bug。后果：daemon/sqlite 是真清空了，但幸存的桌面壳 Svelte 页面进程内存里的 `photos` 数组从未失效（`onMount` 只在页面首次挂载时跑一次，日常刷新走的是只增不删的 `syncPhotosWallIncremental`），继续渲染清场前的旧缩略图，造成"清得不彻底"的假象。**修法**：去掉三处 pattern（kill daemon/testclient、kill 桌面壳、验证清场）里的前导 `/`，改成子串匹配 `target/(debug|release)/...`，absolute 和 relative 两种启动方式都能命中，不影响原本就能匹配的场景。**验证**：`pgrep -fl` 用真实存活的 `pnpm tauri dev` 会话（PID 26368, `2026-08-17` 当天 14:00 启动）直接反证——旧 pattern 空匹配（exit 1），新 pattern 命中；`bash -n` 语法检查绿。**挂用户**：本次修复对用户当前正在用的窗口不生效（不擅自杀掉活跃会话），下次完整退出重启 `pnpm tauri dev` 才会真正吃到干净的清场效果。 |
| **Android 端重新编译 + 清场重装** | 2026-08-17 | — | ✅ 已实现（`assembleDebug` 成功，`adb uninstall`+`adb install -r` 全新安装，versionCode 6/0.3.2） | 用户问"手机上是不是最新 APK"——查证原装机版本（`lastUpdateTime` 2026-08-14 16:28）与当天最后一次 Android 相关改动（`621264c`，16:12）时间差只有 16 分钟，但本地构建产物文件时间戳对不上（8/13），证据不足以确认原装机版本包含最新改动。为消除疑问直接从当前 main 重新 `./gradlew :app:assembleDebug`（需要手动指定 `JAVA_HOME` 到 Android Studio 自带 JBR，系统没有独立安装 JDK）+ `adb uninstall` 清空全部本地数据 + 重新 `adb install -r`，确保测试机现在跑的是当前 main 的确定版本。同时确认 SYNC-04（Android 前台常驻订阅）/SYNC-06（订阅生命周期提到前台级别）虽然代码已合入 main、单测全绿，但两张任务卡都明确记录"真机验收挂用户，一条剧本都没被确认通过"——桌面→手机的事件推送机制（`events.rs`/`router.rs::serve_subscription`/`subscriptions.rs`）有完整集成测试非空壳，但双端真机长连接的实际体验从未被验证确认，不能算"能用"的确定结论。 |
| **照片墙增量合并改用正确排序键 + device.renamed 文案修复** | 2026-08-17 | 本 commit | ✅ 已实现（vite build 绿 191 modules；用户直接验收） | 用户复核出一个真实 bug：上一轮的照片墙增量合并（`syncPhotosWallIncremental`）把新到达项直接插到数组最前面，但查证 `asset_repo.rs::timeline_page` 是 `ORDER BY COALESCE(taken_at, 0) DESC, hash ASC`——**按拍摄时间排，不是按同步/到达时间**，补录的老照片直接插最前面会把它排成"最新"，弄错时间线顺序。改用跟后端一致的排序键（`comparePhotoOrder`）做二分查找插入正确位置（`insertPhotoSorted`），不是无脑塞最前面；已加载窗口之外的补录老照片这版仍不特殊处理（page-1 请求本来就拉不到，用户滚动到那个时间范围时正常分页会照常拉到，不需要额外代码）。另修复：活动记录（总览"最近动静"摘要卡 + 活动记录页两处共用同一套 `auditText`）里 `device.renamed` 事件之前落到 default 分支原样吐出机器可读 detail，把 64 位十六进制 node_id 也带出来撑爆一行导致换行/超出显示区域（用户实测截图反馈）；detail 格式是 `ipc.rs` 里定死的 `"{旧名} -> {新名} ({node_hex})"`，正则精确匹配 64 位 hex 后缀去掉，只留"改名：{旧名} → {新名}"。 |
| **总览标题措辞+最近动静撑底 + 照片墙增量同步（去卡顿）** | 2026-08-17 | 本 commit | ✅ 已实现（vite build 绿 191 modules；用户直接验收） | 用户继续走查提出四点：①"全家备份水位"措辞奇怪——改成"备份状态"（直接描述卡片内容，不玩水位比喻）。②大屏三栏"最近动静"看起来跟左边两张卡高度不一样——查代码确认外框其实是等高的（grid 默认 stretch），真因是"最近动静"内容天然短（最多 3 行）又没有撑底逻辑，链接紧贴在短内容下面、下半段留白，视觉上像矮了一截；补上跟"添加设备"卡同款的 flex-1 撑底包裹层，让"全部活动记录 ›"链接固定贴底。③**照片墙卡顿根因查证属实**——`resetPhotosWall` 每次 daemon 事件（activity.appended/device.changed/timeline.invalidated）都把 `photos` 置空再整页重拉，`{#each g.items as item (item.hash)}` 的 keyed diff 面对"先清空再填入"这种中间态无从复用，等于把所有 `PhotoThumb` 组件实例（含已经拉到手的缩略图）全部销毁重建——库大/事件密集时就是卡顿；改成 `syncPhotosWallIncremental`：拉一次最新第一页当真相，只把本地还没有的 hash 插到数组最前面，已渲染条目原样不动，一次 IPC/缩略图请求都不多花；手动"刷新"按钮保留硬重置语义（用户主动要最新真相时才整墙清空重拉）。深层分页内的删除这版不处理（小概率场景，靠 SYNC-01 每小时对账 + 手动刷新兜底）。④大屏总览下方大片空白能放什么——开放问题，见 NEXT.md，等用户选方向。 |
| **总览页卡片区改功能驱动响应式布局** | 2026-08-17 | 本 commit | ✅ 已实现（vite build 绿 191 modules；用户直接验收，非自截图） | 用户明确桌面端不再逐屏对设计稿，指出总览页三张卡（水位/添加设备/最近动静）在不同尺寸下内容不一致（"最近动静"以前 <1440px 直接整卡消失，是凑三栏的设计稿年代遗留）。**内容优先级确认**：水位卡=核心状态永远第一大，添加设备=常驻低频动作次之，最近动静=补充信息——不是"操作优先/展示其次"的二元对立，总览的核心功能就是"一眼确认备份没坏"。**改法**：卡片容器从 flex+hidden 改 grid——大屏（≥1440px）三栏并排、中屏（1080-1439px）两栏+最近动静沉到下面占满两栏、小屏（<1080px）单栏全部竖排，任何尺寸都不会突然"少一块内容"，只是密度/位置随可用空间变。删掉水位卡下面"只要这台电脑开着、手机插电连 Wi-Fi..."的话术（用户反馈很奇怪，没有合适替代直接删）。**中屏空白修复**（用户实测直接反馈）：两栏 `items-start`（卡片不等高，T-082 时代为贴设计稿定的规则）导致空状态的水位卡比"添加设备"卡矮很多，下面露出一大块背景——改成等高（grid 默认 stretch）+ 空状态文字用 `flex-1 items-center` 垂直居中，不再显得像没做完。 |
| **首启向导功能调整（进入功能驱动阶段第一批）** | 2026-08-17 | 本 commit | ✅ 已实现（Rust cargo check/clippy/fmt 干净；vite build 绿 191 modules；dev 环境 HMR 已生效，用户验收中） | 用户走查向导提出三点，均已核实/实现：①**"自动睡眠还开着"一键设置**——原「去系统设置」打开的电池面板经实测（无障碍 API 读取，非目测）确认根本没把开关摆在明面上，不同 macOS 版本/机型入口还不一样；新增 Tauri 命令 `disable_auto_sleep`（`osascript ... with administrator privileges` 弹系统原生授权，不是终端）作为主选项一键关闭（`pmset -a`，覆盖电池+电源两种场景，口径对齐 `parse_pmset` 检测逻辑），「去系统设置」保留做退路，文案改成引导用右上角搜索框搜"睡眠"（版本无关的稳定路径）。②**"会申请什么"是否真的申请了——查证是真的，但今天的 dev 模式测试从未真正触发过**：`install_autostart` 有 DAE-01 的路径安全防线（拒绝 `/target/` 开发路径），`pnpm tauri dev` 的 daemon 正好在这个路径下，每次都被拒绝、静默降级成一次性进程（非常驻），因此从未真正注册过 LaunchAgent，系统自然不会弹"后台项目已添加"通知——不是通知被抑制，是真的什么都没注册；现查 `launchctl`/plist 均证实无残留。要验证这条真实路径需要 `pnpm tauri build` 出真正的 .app 装到 /Applications 里跑。③**向导收缩为 3 步**——原第 4 步「扫码」整个删掉（连带清理 Wizard.svelte 里整套重复的 QR 生成/pending 轮询/事件监听代码，改用总览页本来就有的常驻"添加设备"卡片承接这个功能，不需要新设计引导机制），第 3 步「完成」直接 `onDone()` 进主界面。 |
| **ICON-01d macOS 图标纸底直角改圆角** | 2026-08-17 | 本 commit | ✅ 已实现（幂等验证 PASS；`pnpm tauri build --bundles app` 后 bundle 内 icon.icns 与源 md5 一致；实测数据见下） | 用户拿真实系统图标（iCloud）对比反馈"人家圆角我们直角，hover 还有阴影"。查证 `scripts/icons/generate.sh` 的纸底一直是 `<rect width="1024" height="1024" fill="#FBF8F2"/>`——ICON-01c 只做了①整体留白（外层 scale 0.8），从没做过②形状本身的圆角——macOS 不会替第三方 icns 自动套圆角遮罩（这点上 Android adaptive-icon 系统会自动裁，macOS 不会，需要美术本身就是圆角/squircle）。**参数不是拍脑袋**：用 `iconutil -c iconset` 解包 + PIL 逐像素扫不透明边界，量了系统 Music.app 真实图标——留白 9.8%（跟我们已有的 10% 吻合，不用改）、圆角曲线从留白边界延伸到画布 29.3% 处变直边；换算回我们 1024 画布、外层 0.8 缩放之前的 rect，rx≈250px。改动只是给纸底 rect 加 `rx="250" ry="250"`。验证：同款方法量修复后的图标——留白 10.1%、曲线延伸到 28.1% 处变直边，跟 Music.app 的 9.8%/29.3% 高度吻合（SVG 圆弧 vs Apple 真实的连续超椭圆曲线有细微形状差异，是近似不是逐像素复刻，但比之前的直角方形准确得多）；PIL 合成三方对比图（旧直角版/新圆角版/Music.app 参照）目视确认。"Hover 阴影"不需要单独处理——macOS 的图标阴影是跟着 alpha 通道形状走的系统渲染效果，形状修对了阴影自然跟着对。Android 前景层不受影响（本来就用另一条不含纸底的生成路径，OS 自己裁形状）。 |
| **首启向导整体对齐设计稿 v2** | 2026-08-17 | 本 commit | ✅ 已实现（vite build 绿 191 modules；用户实机走查中） | 用户反馈"onboarding 整个流程 UI 都不对"——查证 `Wizard.svelte` 从未跟上 DESK-07/08 的 Tailwind 迁移，还是最早期手写 CSS（h2 26px 不是 28px、按钮无主/次/链接三级区分、第 3 步用堆叠卡片不是设计稿的两列表格、nav 栏带一条设计稿没有的分隔线）。逐字段核对设计稿 v2 向导四步 markup 重写整个模板，换成 Tailwind + shadcn Button，删掉整段失效的旧 `<style>`（500 行→约 320 行）；数据流/交互逻辑（chooseFolder/toStep2~4/generateQr/confirmPair）一字未动。顺手清了 `toStep4` 里一行调试 `console.log` 残留 + 一处自己引入的属性加引号警告。**另附带修复**：`tools/reset-local.sh` 复测时炸了两次——①BSD sed 不认 `\s`（已修，见上条）；②新发现更隐蔽的一个：macOS 自带 bash 3.2（GPLv3 avoidance 停在这个老版本）解析「`$VAR` 紧跟多字节 UTF-8 字符」在 `set -u` 下有真实 bug（`bash -c 'set -u; FOO=x; echo "$FOO（"'` 直接复现"unbound variable"），脚本里两处 `$CONFIG_DIR（`/`$PHOTO_LIBRARY_DIR（` 全部改成 `${VAR}` 花括号显式定界。 |
| **总览添加设备卡 + 照片墙滚动修复** | 2026-08-17 | 本 commit | ✅ 已实现（vite build 绿 192 modules；实机截图对照确认） | 用户验收发现两处：①总览"添加设备"卡布局不对——误加的 `items-center` 把整卡居中挤扁，设计稿实际是标题/说明文字左对齐、按钮撑满卡宽（内部文字居中）、只有底部"无法扫码"链接单独居中；去掉 `items-center`，按钮/链接各自补 `w-full`，说明文字去掉 `text-center` 补 `flex-1`。②照片墙滚动区域又回归成整个右侧内容区跟着长高滚动（2026-08-13 修过一次，DESK-08 迁 Tailwind 时把 Card 的 `flex-1 min-h-0 overflow-y-auto` 弄丢了）——照活动记录页同款处理补回来，`.page` 高度约束扩到 `main[data-page="photos"]`。截图实测：照片墙卡片内容在窗口边缘处被正确裁切、提示文字固定在卡片下方不跟着推，与活动记录页同一视觉签名。 |
| **家人与设备页 v2 对齐修复** | 2026-08-17 | 本 commit | ✅ 已实现（vite build 绿 192 modules；截图实测前后对照，非目测） | 用户对照最新离线设计稿导出（`P-Pass 布局与交互(离线版)3.html`，与已归档 v2 md5 一致）反馈"家人与设备页 UI 不对"，本轮只对齐静态布局，不碰改名交互（NAME-01 已有功能不动）。**真因**：shadcn `Button` 基类自带 `inline-flex items-center justify-center`，设备名按钮外层 `flex flex-col` 容器没写 `items-start`，按钮被跨轴拉伸满宽后 `justify-center` 把设备名挤到行中间（跟设计稿"紧贴圆点左对齐"不符）——DESK-07/08 迁移时引入，DOM 结构像素基准测试没测到这个视觉细节。**修法**：设备名 `Button`/改名 `input` 都加 `self-start`（改名 input 是同款拉伸隐患，一并修）+ `Button` 补 `justify-start` 双保险；另发现卡片到提示文字间距 `mt-[10px]` 叠加 `.page` 自身 `gap:22px`，跟标题到卡片的间距不一致（设计稿是整段 20px 等距），去掉多余 mt 统一交给容器 gap。**验证方式**：`pnpm tauri dev` 实机窗口截图（仅截 App 窗口矩形，非全屏，避免误拍其它窗口）修复前后对照，非目测确认。 |
| **DESK-08 四页迁移收官** | 2026-08-15 | merged `ab1688d` | ✅ 已实现（照片/活动记录同条件 0.0000%、总览 0.0000%、设置 0.05% 按钮文字次像素、设备页 19 项基准复验过、console 零错） | 总览→照片→活动记录→设置全部迁到 shadcn Button/Card + Tailwind；手写 CSS 删 74 条（style ~25000→10886 字符）。关键坑：flex 容器不折叠 margin（卡高 +12px）、flex-col 拉伸按钮整行宽（self-start）、first-of-type hint、button.danger 纸底。残余差异均为 mock 跨日伪差或按钮文字次像素抗锯齿。 |
| **DESK-08 总览页迁移** | 2026-08-14 | merged `a4afa87` | ✅ 已实现（w1280/w1000 与迁移前像素级一致 0.01%，残余=按钮文字次像素抗锯齿不可见；w1440 三卡正常；console 零错误） | 总览页迁移 Tailwind + 组件库（DESK-08 第一页）：水位卡/添加设备卡/最近动静卡/配对横幅/离线卡换 shadcn Button/Card + 工具类，数据流一字未动。**两个地基级修复**：①`@layer components` 包裹 App.svelte 全部 `<style>`——Svelte 作用域类提升元素选择器特异性 + 无层规则压过 utilities 层，导致工具类在按钮上全部失效（设备页名字/移除按钮 min-height 一直是 44px 基类而非设计值，DOM 检查未覆盖）——包裹后工具类正常压过手写规则；②`.grow`→`.cols-grow` 改名——Tailwind 自带 .grow 工具类（flex-grow:1）与 App 类撞名，layer 包裹后 settings 弹性分布被改。设备页潜在修正：名字按钮 flex-none + leading-[1.38]、行右状态色三元表达式。照片/活动记录/设置三页未迁（排队中），迁移前后零回归（0.0000%）。 |
| **设计稿 v2 对齐** | 2026-08-14 | merged `2769157` | ✅ 已实现（vite build 绿；log/settings 像素级零变化，overview/photos 仅有意区域变化；设备页 19 项基准确认零回归） | 归档最新设计稿（`docs/design/2026-08-14-layout-v2/`，xixi Discord 附件原样落库，取代 v1 成为 UI 唯一基准）后逐页对照的桌面端对齐轮：①照片页 lede 加「在 Finder 中打开」、副标题改「N 张 · 按原始文件存在 <库路径>」（真实 library_dir）、底部提示对齐设计稿原文；②添加设备卡按钮「显示配对二维码」、hint 对齐设计稿、卡内补「无法扫码？复制配对串」退路（copyPairQuiet 静默取串，不打开弹窗）；③总览配对横幅点名刚扫码的设备（「「X」刚扫了这台电脑的二维码。是家里人吗？」）。**挂账（需拍板/后端，见 NEXT）**：开机自动运行开关（需 daemon autostart 查询/设置接口）、这台电脑的名字（需产品决策 + hostname 后端）、活动记录「保存 90 天」（与「审计只增不删」既有决策冲突）、本周「重试成功」统计（数据源未定义）。向导「保持醒着」电源检查步已存在（power_hint），设置页磁盘空间已存在（T-092），均无需新增。 |
| **DESK-07** | 2026-08-14 | merged `5507cf9` | ✅ 地基+家人与设备页已迁（vite build 绿 192 modules；19 项像素基准 DOM 实测全过 + 反证有效 + CI Desktop 绿；**其余页面未迁，排后续卡**） | 桌面壳迁移 Tailwind CSS + shadcn-svelte（L2 第一轮，用户 2026-08-14 拍板拆多轮，本卡只做地基 + 一个页面验证）。**兼容性前置确认**：shadcn-svelte 1.5.0 peer dep 即 `svelte ^5`，Svelte 5 支持是主线（无硬性不兼容，未换方案）。**地基**：`tailwindcss@4.3.3` + `@tailwindcss/vite`（vite.config.js 插件 + `$lib` alias）+ `shadcn-svelte init`（Vega preset，components.json，`src/lib/utils.ts` cn 工具）；主题桥 `src/app.css` 用 **`@theme inline` 把所有 `--color-*`/`--font-*`/`--radius-*` 直接映射到 `assets/design/tokens.css` 的 `var(--pp-*)`**——工具类（`bg-ink`/`text-act`/`border-divider`/`rounded-sm`…）运行时解析 token，不抄数值、零平行调色板（shadcn 语义槽位映射：primary=ink/paper、destructive=act、secondary/muted/accent=linen/idle-bg，绿=安全状态色不是按钮主色）。**迁移页**：App.svelte「家人与设备」页换 shadcn `Button`/`Card` + Tailwind 工具类，数据流/交互逻辑一字未动；设备页专属手写 CSS（.dev-main/.dev-sub/.dev-remove-btn/.removed-*/.roomy/.edge 等）已删，overview 仍用的 .device-rows/.statusdot/.dev-name/.dev-right 保留。**验证（Playwright 无头 + mock Tauri 桥，多视口）**：①19 项像素基准迁移前后 DOM 实测全等——标题 28px/副标题 14px+mt6/提示 13px、列表容器零 padding 行自 padding 18px 22px、分隔线贴圆角边缘（行 x=255 vs 卡 x=254）、移除=纯文字链接（act 色、无边框无底色、radius 12px 非胶囊）、<1080px 侧栏收起 64px；②**反证**：故意给移除按钮加 `border-2 border-act` → 测量抓到 borderStyle=solid/2px（验证方法真在比对，非摆设）；③全页回归：其余四页迁移前后**像素级 identical**（中途发现并修掉两个 preflight 副作用——`line-height: 1.5` 全局继承导致内容下移、`code/kbd/samp/pre` 字体栈被换，都在 base 层还原）；④双视口 console 零错误；⑤改名闭环（点击→输入→Enter→flash「已改名为」→刷新显示新名）。**跨卡声明禁令遵守**：本卡不写「桌面壳已全面迁移」，其余页面（总览/照片/活动记录/设置）排后续卡。**挂用户**：真机观感验收（浏览器渲染已像素级对齐，Tauri 实际窗口确认）。 |
| **桌面壳设计稿走查** | 2026-08-13 | 本 commit | ✅ 已实现（vite build 绿 176 modules；用户实机走查中） | 用户对照最新离线版设计稿导出（非本仓归档版，本仓 `docs/design/2026-08-05-layout-v1/` 已过期）逐页走查发现多处偏差，本轮修复：①**CSS 层叠顺序 bug（根因）**——响应式 `@media` 块写在若干无条件 `.page`/`.cols` 规则之前，被同优先级的后置规则覆盖，导致宽度/等高相关修复全部不生效（"右边一直留死区"的真实原因），媒体查询统一挪到 `<style>` 末尾；②总览页：两卡不再等高（`.cols` 撤销 T-082 时代的 `align-items:stretch`）、标题接真实照片数、副标题接真实"最近一次备份"、水位卡改成"告警全显+正常限量 2 个+一切正常还有 N 台"绿色链接、添加设备卡补"复制配对串"退路、"最近动静"摘要卡（≥1440px）改单行紧凑格式；③照片页：≥1440px 豁免居中限宽，铺满可用宽度（缩略图网格没有"一行多少字"的阅读考量）；④家人与设备页：字号/"移除"按钮（改纯文字链接）/行内边距（分隔线贴边）三项精修 + 补齐缺失的"「经中继」="提示句；⑤活动记录页：改回卡片列表（撤销 DESK-05 的真表格方案，理由已不成立）+ 补"本周"统计条（只做能从真实数据推出的两项，不编造"重试成功"）+ 列表自身内部滚动（不是整个内容区跟着滚——真正的游标分页需要 `activity.list` 后端加 cursor 参数，本轮只做前端内部滚动这一半，如实挂账）；⑥设置页：`.setting-row` 分隔线贴边、"停止后台服务"按钮边框改配色和危险卡一致；⑦macOS 图标补 ~10% 透明安全边距（Big Sur+ 规范，之前顶格铺满 1024 画布，程序坞里比其它 App 图标明显偏大）。**挂用户**：<1080px 断点"添加设备降成横条卡"未做（先保证竖排不裁切这条底线）；活动记录游标分页未做（需要后端配合）。 |
| **DESK-06** | 2026-08-13 | 本 commit | ✅ 已实现（vite build 绿 176 modules；**桌面照片墙真机验收挂用户**） | 照片墙同步补漏（L1，xixi 2026-08-13 反馈「移动端订阅状态有了，desktop 照片反而没有同步」）：SYNC-01/WATCH-01 的 `timeline.invalidated` 事件桌面端没订阅——`onDaemonEvent` 只对 `activity.appended`/`device.changed` 重置照片墙缓存，Finder 删照片后移动端实时刷新、桌面端照片墙停在首次加载快照（60s 兜底轮询也不重拉照片墙，无手动刷新入口）。**修法**：①`timeline.invalidated` 加入照片墙失效重置，重置逻辑抽 `resetPhotosWall()` 统一入口；②照片墙 lede 右侧「刷新」按钮兜底（resetPhotosWall → `$effect` 自动重拉第一页，photosLoading 时显示「刷新中…」）；③活动记录人话化——`backup.finished` 的 `ingested=N duplicates=M` 正则解析成「备份完成：新增 N 张，去重 M 张」（解析失败回退原文绝不吞）、`asset.removed_external`/`external.delete`/`backup.commit` 用 `shortName()` 只留文件名（全路径噪音过滤，DESK-05 同款原则）。daemon 零改动（事件早已发出，纯消费端补漏）。**挂账（用户三条）**：Finder 删照片桌面墙秒级消失、手动刷新重拉、活动记录人话显示。 |
| **DAE-04** | 2026-08-13 | 待推 main | ✅ 已实现（桌面 lib 6/6——新增 4 项 DAE-04 单测；diag i18n 对称 8/8；vite build 绿 176 modules；桌面 clippy 零警告 + 主仓 fmt 干净；**跨版本手动验收挂用户**） | 桌面壳更新后手动重启后台服务（L1，2026-08-13 用户提问「自动更新能不能也更新常驻服务」挖出的真实缺口：`downloadAndInstall()` 只换 .app 包内容，旧 daemon 进程（launchd 常驻）带旧代码一直跑到重启/手动点平时根本不出现的「启动服务」按钮；行业调研 Docker vmnetd/tailscaled/Clash Verge Rev 无更巧解法）。**实现（纯手动最简方案，自动检测另立卡）**：①桌面壳新增 Tauri 命令 `restart_daemon_process`——照抄 `stop_daemon` 的 `pkill -f ppf-daemon`（Win `taskkill`）杀旧进程，**绝不碰 autostart 注册**（uninstall 会阻止复活；`SuccessfulExit=false` 下体面 exit(0) 反而不复活 → 必须真「杀」，step_down/claim 机制明确不用）；Windows 无 KeepAlive 复活语义 → 杀后显式一次性重拉（start_daemon spawn 分支）；②杀后每 500ms 轮询 status 最长 12s（实测信号杀 4~5s 复活）确认进程复活且版本号真的变了——变了才报成功，没变=磁盘文件没更新明说失败（Clash Verge Rev #5451「报告成功但没换好」教训）；③设置页「软件更新」卡新增按钮，仅当壳版本（tauri.conf.json）与 daemon `status.version` 核心三段不同（忽略 v 前缀与 -test.N 后缀，release 里 daemon 报 "v0.3.3-test.1"、壳报 "0.3.3" 是同一份）才显示，一致时不出现避免误杀；④i18n 10 个 `ui.restart_service_*` 键 zh/en 对称 + diag keys.rs 注册（ALL 79→89）。**测试**：`restart_outcome` 纯函数 4 项（版本变化=真成功/同版本=未变更/杀前离线杀后起来=有进展/无新版本=未验证兜底）。**挂账（用户，三条手动验收）**：①临时改 daemon 版本常量编译安装造「版本不一致」→ 按钮出现 → 点击 → ps 前后 PID 对照 + launchd 数秒拉起 + 壳读回新版本号；②反证：破坏 sidecar 路径让复活失败 → 按钮流程捕获失败明确提示；③正常场景强制调用命令不误伤。 |
| **SYNC-06** | 2026-08-13 | 待推 main | ✅ 已实现（android 178/178 单测绿——新增 12 项；assembleDebug 绿；**真机验收挂用户**） | 订阅连接生命周期上提到 App 前台级别、脱钩 tab 切换（L1，2026-08-13 用户 review：SYNC-04 把 `timeline.subscribe` 绑在 `PhotosScreen` 组合可见性上，切到设置 tab 订阅就断、切回重建还有空窗）。**修法**：订阅状态（items/next/loading/error/subscribeAttempt/exhausted/connected/hadFailure）和驱动循环从 PhotosScreen 抽到新 `TimelineSubscriptionHolder`（ui/TimelineSubscriptionHolder.kt），MainActivity 跟 `ForegroundHeartbeat` 并列持有、复用同一条 `LifecycleEventObserver`——ON_RESUME 起 / ON_STOP 停（PRES-01「后台绝不心跳」红线同款判断，后台零网络活动），前台期间不管显示哪个 tab 订阅保持、信号照收照刷，回前台重建订阅 + 整页刷新补齐错过的变化。**设计**：纯函数状态机（`SubscriptionSessionState` + 转换函数，JVM 可测；退避决策原样复用 `nextSubscribeRetry`）+ `TimelineChannel` 依赖面（生产 = `LoaderTimelineChannel` 包 TimelineLoader 薄包装，协议层 SYNC-03/04 一字未动）+ 配对监视循环（前台每 2s 读 pairing.json，重新配对/断开/换 token 自动重建会话，未配对空闲）+ 60s 兜底轮询保持 REV-01#2「仅追加」语义；翻页（appendNextPage）也收进 holder，PhotosScreen 只渲染。**测试**：纯状态机 7 项（tab 0→1→0 零转换 → 订阅发起次数 0 变化；旧接线对照——每次切回 tab +1；wasLive 清零退避；耗尽+手动重试）+ holder 协程级 5 项（计数 fake 通道，kotlinx-coroutines-test 虚拟时间：tab 切换不重连/start 幂等/ON_STOP 关 ON_RESUME 重建/耗尽后手动重试重新发起/未配对空闲+配对落盘自动起订）。**真机验收挂用户（两条，卡内禁令：未经确认不得宣称「已对齐前台」）**：①停在设置 tab 时 daemon 侧变化 → 切回照片 tab 立即最新态、无「重新连接中」；②反证：还原旧行为（绑定组合可见性）→ 切 tab 来回观察订阅确实重建。 |
| **ICON-01c** | 2026-08-13 | `3113f62` | ✅ 已实现并出包（v0.3.3-test.4，release 内 icns md5 与源一致 18cfe0a6；兽面墨色宽度 65.8% ∈ macOS 规范 60-66%） | macOS 图标安全区缩排（L1，xixi 反馈「Cmd+Tab/程序坞 icon 不对、不符合规范、显得特大」）。根因：ICON-01 接入时 Android 侧做了 66% 安全区缩排（ICON-01b），**macOS icns 漏做**——icon-carbon.svg 全幅渲染，兽面含笔画横向占画布 ~86%，Dock/Cmd+Tab 显示超标。修法：generate.sh 新增步骤 0 生成安全区缩排版 SVG（以画布中心 (512,512) 为原点 scale 0.77，876px→676px≈66%；纸底 rect 保持铺满——macOS 系统圆角遮罩负责形状，背景必须不透明），macOS icns / Windows ico / Tauri PNG 各档全部切缩排版（托盘模板图与 Android 前景层维持各自原有逻辑不动）。验证：缩排后兽面墨色宽度 65.8%、高度 48.5%、居中；连续两次生成字节一致（幂等）；本地 `tauri build --bundles app` 后 bundle 内 icon.icns 与源 md5 相同；v0.3.3-test.4 发布包实测同 md5 + 65.8%。CI Desktop 绿。**挂账**：R2 发布镜像 403（pre-existing，见 NEXT）。 |
| **REV-01** | 2026-08-13 | 待推 main | ✅ 已实现（daemon 全量绿含新增 IPC 链路测试 + arch-check/clippy/fmt 干净；android 166/166 绿） | SYNC-03/04 code review 遗留 5 项 backlog 全部修复（用户当时本地无手机直连，改排本卡）：①`serve_subscription` register 提到 ack/initial push 之前，吊销窗口覆盖整个订阅生命周期；②**真 bug**——60s 兜底轮询误用整页覆盖语义打断翻页/逐出已加载缩略图缓存，改回旧版「仅追加」语义，订阅信号（整页覆盖）与兜底轮询（仅追加）职责分开；③新增 `device_revoke_over_ipc_closes_the_quic_subscription`（Router+IpcServer 共用同一份登记表，走完整 IPC JSON 链路，反证已跑——临时注释 close 调用确认测试变红）；④订阅 effect 两处 `catch (_: Throwable)` 补 `CancellationException` 前置重抛；⑤`wasLive` 计时起点从 effect 开始改为 `onConnected` 触发那一刻。 |
| **MOB-06** | 2026-08-12 | 待推 main | ✅ 已实现（android 166/166 绿含 StringsSymmetryTest；assembleDebug 绿） | 查看页右上角「分享」（L2，用户 2026-08-12 询问「分享 vs 用其他应用打开是不是一回事」）：**不是**——Android 里这是两种 Intent。「分享」= `ACTION_SEND`（把文件作为内容/附件发给目标 app，接收方新建消息/上传附件，系统弹分享面板：微信/QQ/邮件/云盘/Nearby）；「用其他应用打开」= `ACTION_VIEW`（让目标 app 以打开模式处理文件本身，修图/播放/查看，系统弹打开方式选择器）。底层 90% 共用：FileProvider URI + FLAG_GRANT_READ_URI_PERMISSION + cacheDir/share/ 临时文件即用即清（RET-01 管线）。常规做法：查看页右上角放分享图标，「打开」留底部动作区。实现：`AssetActions.shareIntent`（ACTION_SEND + EXTRA_STREAM + createChooser）+ 分享图标（当时自绘 ic_share.xml 以免引 material-icons-extended 控体积；**ICON-02 于 2026-08-19 换成 `Icons.Filled.Share`**——material-icons-**core** 本来就随 material3 传递进 APK，换完 APK 反而小了 759 字节）+ PhotoViewer/VideoScreen 右上角分享图标（深色背景 Paper tint，busy/未取到禁用）+ 动作枚举化（布尔参数 → ViewerOp/VideoOp，三动作共享下载管线）。挂账（真机，用户）：照片/视频右上角分享图标 → 系统分享面板 → 微信收到原图；面板关闭后 cacheDir/share/ 无残留。 |
| **UX-11** | 2026-08-12 | 待推 main | ✅ 已实现（android 全量单测绿；真机走查挂用户） | daemon 请求无超时——真死机后手机永久卡"正在读取"（L1 严重，用户真机反馈：desktop 服务已停，Photos tab 永久 loading 不报错）。`DaemonClient.call`/`connectRaw` 直接 `ep.connect` 零超时——iroh `connect()` 本身不带超时，对手真的不在时可能无限期悬挂，`PhotosScreen` 的 try/catch/finally 永远走不到。修法：`call()` 用 `withTimeout(15_000)` 包住整个往返，超时抛自定义 `DaemonUnreachableException`（继承 `IOException`，**故意不继承** `CancellationException`——否则 `BackupUiStateHolder` 的"暂停语义"catch 会把超时误当成用户主动取消，静默吞掉，制造同类卡死 bug）；`connectRaw` 只给建连步骤加界（会话本身不设限）。挂账（真机，用户）：该真机当前正处于桌面服务已停状态，天然验证条件，确认 ~15s 内从 loading 变报错。 |
| **UX-12** | 2026-08-12 | 待推 main | ✅ 已实现（android 全量单测绿；真机走查挂用户） | 设置页规则卡行高/间距不统一（L0，用户走查反馈）：Switch 行与纯文字行分别用 8dp/14dp 垂直 padding 想凑齐行高，但 Switch 组件自带触控尺寸更大，两条不同 padding 反而放大差异。统一为 `heightIn(min=56dp)+水平padding`，六处行同规格；规则卡整列加 8dp 上下 padding，第一行/最后一行不再贴 20dp 圆角。挂账（真机，用户）：视觉确认。 |
| **UX-10** | 2026-08-12 | 待推 main | ✅ 已实现（android 全量单测绿；真机走查挂用户） | 相册选择页封面缩略图（L1，用户产品反馈）：`MediaScanner.Bucket` 加 `coverUri`（跨图片/视频两个 collection 取全局最新一条），`BucketScreen` 每行 Checkbox 前插入 48dp 封面（API 29+ `loadThumbnail`，更早设备优雅退化空白）。⚠️ 过程debug：第一版新开独立 LruCache 撞上 `CacheRedlineTest`「全工程 LruCache 声明只能有 PhotosScreen.kt 一处」的红线断言，改为复用该缓存（key 加 `bucket:` 前缀）而不是放宽测试。挂账（真机，用户）：视觉效果确认。 |
| **UX-09** | 2026-08-12 | 待推 main | ✅ 已实现（android 全量单测绿；真机走查挂用户） | 备份/照片 tab 三处走查反馈（L1，用户真机反馈）：①「立即备份」点了没反应——`statusLineOf` 早算出的 `Pending`/`AllSafe` 裁决从未接上 UI（半成品：逻辑+字符串资源+锁死测试都在，唯独 HomeScreen 没用），空闲态恒显示通用 `idle_auto_hint`；补 `idleStatusText` 把四种裁决分别接到对应文案。②hero 空闲态「选择相册」大按钮删除（低频操作，onboarding 已选过一次，设置卡「备份范围」行本就有等价入口，未删功能），腾出的宽度给状态文案占满整行。③`tab_backup`→`tab_settings`（「备份」→「设置」，tab 内容其实是开关/规则/版本/断开）。④`PhotosScreen` 新增前台轮询（停留期间每 15s 拉一次首页，只插新 hash 到最前，不触发整页失效逐出）——之前零轮询零事件订阅，一直停在照片 tab 不切换新照片永远不会自己出现。挂账（真机，用户）：四项验收待确认。 |
| **MOB-05** | 2026-08-12 | 待推 main | ✅ 已实现（android 全量绿含 TriggerPolicyTest 11/11；真机验收挂用户） | 部分授权误判死循环修复（L1，用户真机报告）：MOB-02 引入的 `isPartialMediaAccess` 判定式写反——旧假设「完整授权只给 images 不给 visual_selected」不成立，真机上 `READ_MEDIA_VISUAL_USER_SELECTED` 一旦授予过就不会随后续升级到完整授权被撤销，导致 `imagesGranted && visualSelectedGranted` 几乎恒真，把完整授权误判成部分授权，用户永远进不了相册选择页、选择被静默丢弃、被反复推去系统设置（用户看到的"只能选照片"系统限量选择器就是这个误判的后果）。修法：改为 `!imagesGranted && visualSelectedGranted`（先判 images 授予=完整，否则才判 visual_selected=部分，与官方 developer.android.com/about/versions/14/changes/partial-photo-video-access 检测顺序一致）。`grep PartialMediaAccess` 确认唯一消费点 `MainActivity.hasPartialMediaAccess`，无旁路。测试同步改写反证（旧语义两条断言方向互换）。**挂账（真机，用户）**：确认死循环解除、选相册后返回 Home 引导卡消失。 |
| **DESK-05** | 2026-08-12 | 本 commit | ✅ 已实现（vite build 绿 176 modules） | 桌面走查反馈三项（L1，xixi 2026-08-12 反馈）：**①向导第一步默认填充路径**——`libraryDir = configuredLibraryDir || defaultDir`，新装不再要求先点「用默认位置」才能继续；路径 ≠ 默认时旁挂「↺ 回到默认」按钮，= 默认时不显示；「选一个文件夹…」更新路径后按钮出现（DESK-04 的「下一步」禁用逻辑保留兜底）。**②活动记录改真表格**——设备/事件/时间三列（auditLine 拆 auditWho/auditText，配对类 detail 兜底设备名）；`ingest.*` 逐文件行过滤不展示（全路径噪音，backup.finished 的 ingested= 汇总保留），数据层 audit 流不动。**③照片墙 staleness 修复**——`photosLoaded` 一次加载永不重置 → 备份落地后照片库显示不出新照片；daemon 事件 `activity.appended`/`device.changed` 到达时重置 photos/photosLoaded/photosNext 强制重拉第一页。 |
| **CI-01** | 2026-08-12 | `5b8cb88` | ✅ 已实现（actionlint 8 workflow 零告警；--asset-base 双分支本地实测；R2 ppf-dl + custom domain 已建；CI 实跑验收留推后确认） | 流水线分块重构（L2，用户点名 2026-08-11）。pr.yml 拆三域 workflow：ci-rust（crates/** Cargo.* config/** assets/i18n/** tools/arch-check.sh）/ ci-android（apps/android/** assets/i18n/**）/ ci-desktop（apps/desktop/** assets/**），每 workflow concurrency cancel-in-progress，纯 docs/.claude 提交零 CI；release.yml 加 platforms dispatch 输入（android/macos/windows 逗号组合，tag push 恒全量）+ 三平台 job if 门控；T-070 scenarios 并轨 e2e.yml nightly+tag 门禁；CF 联动（secret 门控）：R2 发布镜像 ppf-dl/dl.p-pass.hawkeye-xb.com（manifest --asset-base 切镜像域，验签零变化）+ ci-workers.yml 自动部署（临时 toml custom_domain 保真）；CLAUDE.md 底线①口径更新（盯受影响域，nightly 红次日第一优先）；缓存治理确认 Windows 独立 key 前缀。**等用户**：GitHub Secrets 加 CLOUDFLARE_API_TOKEN 启用 CF 三项。 |
| **DESK-04** | 2026-08-12 | `9072735` | ✅ 已实现（vite build 绿 176 modules） | 桌面向导低成本对齐（L1，T-042 流程不重做）。文案按产品语言过一遍（步骤名「照片存在哪/电脑会睡吗/加手机」，去「常驻服务/访达/整体拷走」等词）；视觉全 token 化（grep 零硬编码残留）；第三步接 T4 新配对弹窗流——daemon-event 事件驱动 + 3s 轮询兜底，pending 出现即时切确认列表（逐行允许/拒绝），不再停留常驻 QR。挂账（真机）：三步截图对照、走完向导→配对→确认列表即时出现。 |
| **DOG-02b** | 2026-08-12 | `a0792fe` | ✅ 已实现（android 161/161 绿含 WhitelistNudgeStoreTest 11 项） | 契机式电池白名单提醒（L1，decisions ④）——该跑没跑成才提醒。独立 store（lastFailedAt/lastSuccessAt/lastNudgedAt，崩溃安全）+ shouldNudgeWhitelist 纯函数（未加白/有失败/≤2天/失败后无成功/去重 72h）；BackupWorker 搭便车（成功一轮 recordSuccess 清零，失败 recordFailure，finally 判定）；通知进 App 见 DOG-02 Home 引导条。挂账（真机）：mock 条件满足→通知一次+点开引导、加白后不再通知。 |
| **SENT-01** | 2026-08-12 | `29af0ff` | ✅ 已实现（android 150/150 绿含 SentinelStoreTest 10 项） | 手机盯电脑哨兵（L1，decisions ⑤）——备份静默失败必须被发现。机制红线：**搭后台任务便车非心跳**（校准返回可达性 Boolean，run 成功=硬证据，finally 统一判定）；shouldNotifySentinel 纯函数四条件（确认可达过/距今>72h/期间 ≥1 次失败尝试/去重 72h）；通知走 UX-02 通道「3 天没连上电脑了——照片没丢」，发过 markNotified。挂账（真机）：mock 全失败跨阈值→通知一次不重复、恢复可达清零。 |
| **RET-01** | 2026-08-12 | `4a92aae` | ✅ 已实现（android 140/140 绿含 AssetActionsTest 8 项） | 单张照片取回=使用动作（L2，链 2 首卡，decisions ①③）。查看页两动作：「保存到相册」（MediaStore API 29+ RELATIVE_PATH+IS_PENDING 免权限 / 26-28 DATA+权限+扫描广播，DATE_TAKEN 保原拍摄时间）+「用其他应用打开」（FileProvider+ACTION_VIEW，断网/无应用人话错误）；MOB-04 红线：原图按需下载 cacheDir/share 即用即清（使用前清旧残留+面板关闭回调+系统兜底）；sniffMimeFromHeader 文件头魔数嗅探真实 MIME（asset.mediaType 只有粗类，纯函数 JVM 可测）；防循环钉子显式断言（存回=同 hash 重入→offered 12/ingested 0/duplicates 12）。挂账（真机）：家人照片保存到相册可见+时间元数据、打开面板+临时目录零残留、断网点两动作人话错误。 |
| **SITE-01** | 2026-08-11 | 本 commit | ✅ 已实现（本地 build 绿 + tokens/icons 断言绿 + 零第三方请求断言绿；Pages 部署/DNS 挂验收人） | 站点脚手架——landing+blog（L2，架构档案 docs/product/2026-08-11-site-architecture.md 照单全收）。**site/**：Astro 5 纯静态（landing 只说三件事：照片回家/为 60 岁的家人设计/开源·端到端加密，文案从定位档案改写不自创卖点；CTA=GitHub Releases latest；blog 列表/文章/RSS；404）；`src/styles/tokens.css` 由 assets/design/tokens.json 构建期生成（scripts/generate-tokens.mjs 幂等 + `--check` 断言），图标从 docs/design/2026-08-11-icon-v1/ 构建期同步（sync-icons.mjs，亮/夜双版 picture 切换）；暗色跟随系统（只用既有 token 反转，不发明新色）；移动端单列自适应；零 tracker——无字体 CDN 无统计，CI 内零第三方请求断言（allowlist 仅本站域+github.com 下载外链）。**.github/workflows/site.yml**：paths 过滤 `site/**` 与主 CI 完全隔离，npm ci → tokens/icons check → build → 零第三方断言 → GH Pages 部署。`public/CNAME` 入库（p-pass.hawkeye-xb.com）。**挂账（验收人）**：①Pages 部署后三路由 200 ②Lighthouse ≥90 ③DNS CNAME p-pass.hawkeye-xb.com → hawkeye-xb.github.io（CF zone 65dec62bc61b00e5d22fedc40b774bdc，当前记录指向旧 p-pass-landing.pages.dev 占位）。 |
| **SITE-02 修复** | 2026-08-11 | 本 commit | ✅ 已实现（本地 build 绿 + 暗色模拟截图验证可读） | 三篇博文上线后用户审稿修复批次：①**日期按真实事件时间线**——why 篇改 2026-07-31（文章自称"写于第一个里程碑收官之后"，M1 即 7-31 收官）、icon 篇改 2026-08-10（图标 v1 定稿日 086347b）、轮询篇保持 2026-08-11（ipc-02 f6f734a 落地日）——原三篇全 8-11 造成"一天决策"观感；②**暗色模式修复**——`--canvas` 未随暗色重映射：pillars 卡片保持浅米底 #EFE9DF + 暗色下 `--text-secondary` 变浅字 → 对比度 ~1.2:1 不可读（浏览器模拟暗色实锤）；修法 global.css 暗色块 `--canvas: var(--ink-hover)`（既有 token，不发明新色）+ `--hairline` 换浅色 rgba + `:root` 加 `color-scheme: light dark`；③**icon 篇删瓦当变体段+图**（用户指令，图是同一变体草稿 k.svg，留文字成孤儿）。 |
| **PRES-01** | 2026-08-11 | `71a34da` | ✅ 已实现（Rust 149/149 + clippy 0 + fmt + arch-check 绿；Android 单测绿 + vite build 绿；CI 4/4 绿） | 前台 30s 轻心跳 + 三档在线态 + hello 进活动流（L2，队列里照卡面）。**心跳复用 hello 不加协议动词**：Android `ForegroundHeartbeat`（ON_RESUME~ON_STOP 间每 30s 轻 ping，**后台绝不心跳=耗电红线**，失败静默）→ daemon hello 落点 `touch_last_seen`（只碰已配对未吊销设备，revoked 不刷新、未配对静默）+ `device.connected` 审计（同设备 10 分钟去重防锁屏重连刷屏）。**三档在线态**：`presence.rs` 纯函数（在线=活跃连接或 <2min 心跳 / 刚刚在线 / 离线=哨兵 >5 天口径不动），devices.list 直出 presence；桌面设备行按三档渲染（online 优先展示已直连/经中继路径事实，relativeTime 新纯函数），活动流「XX 连接了」。**红线自查**：hint/心跳绝不参与鉴权（revoked hello 仍被拒）。**测试**：presence.rs 边界单测 + presence_flow.rs 5 个集成（hello→审计/10min 去重/跨窗口重记/未配对零副作用/revoked 被拒零副作用/devices.list 三档含活跃连接覆盖旧 last_seen），反证注释（去重去掉必红）。**挂账（验收人）**：真机锁屏 10 分钟活动流不刷屏、桌面「3 分钟前在线」观感。 |
| **DESK-03** | 2026-08-11 | `71a34da` | ✅ 已实现（Rust 149/149 + clippy 0 + arch-check 绿；desk_flow 三方对照测试全过；vite build 绿；CI 4/4 绿） | 桌面照片墙（L2，与手机同一数据源——**终结 Finder 对账**）。**daemon**：本地 IPC 查询平面落地（此前 timeline/thumb 只在 iroh 网络平面，桌面壳调不到）——`IpcServer` OnceLock 注入 Router 同款 QueryEngine（main 在 transport bind 后 set_query，未注入答 unsupported 老测试零波及），`timeline.page`/`thumb.get`/`asset.meta` 响应形状与网络平面逐字段一致；新增 `asset.path`（originals 原文件绝对路径，Finder 揭示用）+ `asset.original`（原图字节内存展示不落盘，>12MiB 降级 1024 缩略图，video 拒）；`status.photo_sources`。**桌面壳**：照片页（侧边栏第五项 + i18n）——缩略图墙（PhotoThumb 组件，IntersectionObserver 进入视口才拉 + 200px 预载）、今天/本月/更早分组、底部哨兵分页（60/页）、点开=大图内存查看（asset.original，关闭即弃）+「在 Finder 中显示」（revealItemInDir）。**测试**：desk_flow.rs 三方对照（墙上数==IPC photo_count==sqlite 直查 + thumb 可解码 JPEG + asset.path 指真实原文件 + original 字节校验 + 未注入回归）。**挂账（验收人）**：真窗口 500 张滚动流畅度、大图/Finder 揭示走查。 |
| **IPC-02** | 2026-08-11 | 本 commit | ✅ 已实现（Rust 全量 237/237 + clippy 0 warning + arch-check 绿 + vite build 绿；桌面联调挂验收人） | IPC 事件订阅——桌面壳告别 3s 轮询（L2，用户裁决：轮询是「体验、实现、内存都不友好」）。**daemon**：新增 `events` 模块（broadcast 事件总线，4 事件：pairing.pending_changed / status.changed / activity.appended / device.changed；emit 无订阅者静默丢弃，Lagged 跳过——事件是加速器不承诺零丢失）；IPC 新增 `events.subscribe`（握手后连接转事件流，newline JSON 事件帧，支持 types 过滤，连接上仍可应答普通请求；`events.unsubscribe` 或断开即关）；触发点接在真实变化处——pending 入队（IpcServer pending_rx 循环）/confirm 出队/device.revoke（IpcServer）/backup.commit + unpair（Router）/配对落定（Pairing，with_events 可选注入，未注入静默）。**桌面壳**：src-tauri `DaemonHandle::subscribe_events` 长连接阻塞读事件 → `start_event_stream` command（setup 启动，2s 退避自动重连，老 daemon 握手失败静默降级）；前端 `listen("daemon-event")` 全量 refresh，3s 轮询降级 **60s 兜底对账**（防漏事件，不再是主通道）。**测试**：ipc_flow +3（订阅后注入配对请求 → pending_changed **<100ms**（实测 36ms，对照轮询 3s）；类型过滤反证——只订阅 status.changed 收不到 pending 事件；unsubscribe 反证——连接被服务端关闭）。**挂账（验收人）**：①扫码 → QR 弹窗即时关/授权列表即时出（时序日志）；②断 daemon → 壳自动重连重订阅状态恢复；③反证：订阅失效 → 兜底轮询仍工作。 |
| **SYNC-01** | 2026-08-11 | 本 commit | ✅ 已实现（Rust 全量 234/234 + arch-check 绿；集成测试 4 步断言全过） | 外部删除对账（L2，三星真机 2026-08-12 实锤：Finder 删 originals 后手机时间线依旧看到旧照片——thumb 独立存储 + 索引没清，三处不同步）。**修法**：daemon 启动时 + 每小时 re-diff 磁盘（originals）↔ 索引（asset 表）——磁盘上没了的条目 = 外部删除（无法归因，actor=NULL 如实记审计）：清 asset 行 + thumb 文件（t256/t1024）+ 审计 `asset.removed_external`。选低频轮询而非目录监听的论证见 reconcile.rs 模块注释（收敛延迟 ≤1h vs FSEvents/inotify 双平台复杂度；blob 不删——iroh-blobs 0.103 无公开 delete API，孤儿 blob 内容寻址惰性无害，空间回收另立卡，docs/product/2026-08-12-cache-redlines.md 同源备忘）。**实现**：storage 新增 `list_asset_paths`/`delete_asset`（+22 行，只增不改既有语义）；daemon 新增 `reconcile` 模块（Reconcile::run_once 单条失败不中断整轮，索引不可读静默跳过本轮）；main.rs 接线（启动跑一轮 + spawn 每小时循环）。**测试**：`sync_flow` 集成测试走真实 upload 链路——5 张入库 → 干净盘 no-op 反证 → 磁盘删 2 张 → 对账前索引仍 5（反证 b）→ 对账移除恰 2 → 索引 3/thumb 文件消失（t256+t1024）/幸存者 thumb 在位/audit 2 条 `asset.removed_external`（actor=NULL、target_hash 匹配）/timeline 只剩 3。**挂账（验收人）**：三星真机对账后拉 timeline 被删照片消失（手机端 exist-check 回落链，卡验收 2）。 |
| **DEV-01b** | 2026-08-10 | `5870324` | ✅ 已实现（android 全量绿；巡检轮 126/126 复验） | 重装识别入口先隐藏（L0，用户拍板 2026-08-12 走查批次）：**UI 入口删净**——Android 设置页「重装识别」开关行隐藏、桌面允许对话框「替换旧的 X」选项默认关（编译期 flag）；**底层不拆**——pair.request 的 device_hint 照发照存（数据继续积累，未来开 flag 即用）。巡检轮抽检（f12cfd8）✅ PASS：UI 入口删净、device_hint 照发照存、桌面 flag 保留反证路径。 | 
| **DESK-02** | 2026-08-10 | `2c4feba` | ✅ 已实现（Rust 233/233 + Android 126/126 + arch-check 绿；巡检轮抽检 PASS） | 桌面走查修复三项（L1，2026-08-12 走查批次）：**①更新通道选项删除**——环境由构建推导（PPF_BUILD_VERSION 含 `-test.` → test 通道，页脚完整版本串 + 琥珀「测试版」徽标，正式构建只显版本号；Android 设置页通道行一并删除，推导函数单测两分支，stable URL 红线不变）；**②已移除设备不再展示**——devices.list 默认过滤 revoked（include_revoked 参数默认 false + 语义单测），桌面零改动；**③二维码弹窗不让路 → 移交 IPC-02**（本卡不做临时轮询）。⚠️ 纪律：直推前没跑 fmt → main 红 Format check（8/7 同款，验收人 5ec6ea6 修复）；nit：徽标文案写死组件未走 i18n 归 T-042 收编债。 | 
| **ICON-01b** | 2026-08-10 | `fb2f6fd` | ✅ 已实现（三星真机实锤修复；巡检轮像素级 PASS） | Android 自适应图标安全区缩排（L1，三星真机 2026-08-12 反馈：launcher 图标像被放大、脸展示不全）：ICON-01 前景层全幅渲染（兽面占画布 ~77%）被系统遮罩只显示中心 ~66% 安全区 → 视觉=放大裁切。修法：前景层按 108dp 网格出图，兽面内容缩放到中心 66dp 安全圆内（相对全幅 ~0.61 缩放）；背景层纯色 paper 不变；monochrome 层同步复查。巡检轮抽检（f12cfd8）✅ **PASS（像素级实测）**：内容占比 0.52×0.39 落在 0.61 安全区内、纸底正确剥离给背景层；模拟器遮罩截图已补交（2026-08-11）。 | 
| **MOB-03** | 2026-08-10 | `1216eaa` | ✅ 已实现（android 全量绿；巡检轮 126/126 复验） | 相册选择页权限链修复（L1 加急，三星真机 2026-08-12 实锤：MOB-02 删手动备份按钮时把权限申请链一起删没了——无权限直接进列表 = MediaStore 空查询 = 全白，备份主流程死）：进入相册选择页前走完整权限链——未授权 → 发起系统权限请求 → 完整授权后进列表；部分授权 → MOB-02 §二引导态（「只授权了部分照片…」+去设置）；拒绝 → 人话引导不崩不白屏。onboarding「配对成功→选相册」入口同样过链。巡检轮抽检（f12cfd8）✅ **代码 PASS**（Home 与 onboarding 两入口统一走 enterBucketPicker 权限链，完整/部分/拒绝三分支齐、无白屏路径）；模拟器「全新安装零权限」截图证据已补交（2026-08-11）。 | 
| **ICON-01** | 2026-08-11 | 本 commit | ✅ 已实现（桌面 cargo check 绿 + Android assembleDebug 绿；视觉核对挂验收人） | 图标接入双端构建（L1，2026-08-11 出卡）。唯一基准 docs/design/2026-08-11-icon-v1/ 的 SVG。版本分工（用户钦定）：**主图标=碳纹版**——macOS `icon.icns` 全档位（16→1024 含 @2x，iconutil）、Windows `icon.ico` 6 档（16/32/48/64/128/256，PNG-compressed ICO）、Tauri 标准文件集（32x32/64x64/128x128/256x256 + Square 系列依赖的 32/64/128@2x + app-icon.png）；**≤40px/托盘/通知=beast 全实线版**——16px 碳纹糊成灰已视觉实证（四格对比图：碳纹 16px 右侧灰块不可读 vs beast 轮廓清楚），托盘 `tray-icon.png`（beast 纯黑+alpha）+ Tauri `icon_as_template(true)`（macOS 菜单栏按深浅色自动反色，只对 macOS 生效）；**Android 前景层分密度 PNG**（VectorDrawable 不支持 pattern——碳纹会丢，必须 PNG）：mdpi 108/hdpi 162/xhdpi 216/xxhdpi 324/xxxhdpi 432，`mipmap-anydpi-v26/ic_launcher.xml` 自适应图标（背景色 paper `#FBF8F2`）+ Manifest `android:icon/@mipmap/ic_launcher`（此前**完全没图标**=系统默认）。生成脚本 `scripts/icons/generate.sh`：rsvg-convert + iconutil + python3，**幂等**（67 产物两次跑 shasum 逐字节一致）；⚠️ bash 3.2 不支持关联数组（`declare -A` 在 macOS 默认 bash 直接 unbound）→ 并行数组。桌面 cargo check 绿 + Android assembleDebug 绿（IconRequest 无单独单测，构建接线由 aapt/bundle 兜底）。**挂账（验收人）**：①64px 碳纹 vs 16px beast 视觉核对；②macOS 托盘深浅色模板观感；③三星真机桌面图标/圆角裁切观感。 |
| **DEV-01** | 2026-08-11 | 本 commit | ✅ 已实现（daemon/storage/proto 全量绿含 3 新集成测试；真机重装流程挂验收人） | 重配对识别与合并（L2，2026-08-11 A 档）。**段①device_hint**：pair.request 加可选 `device_hint`=SHA-256(Build.MODEL+ANDROID_ID) 前 8 字节 hex——**不进 QR**（QR 内容零变化）、**免权限**（两字段都无需运行时权限）、**只作提示不作凭据**（authz 不读）；ANDROID_ID 自 API 26 按「签名+用户+设备」隔离=同签名重装不变。proto 演进：Rust `skip_serializing_if = "Option::is_none"` + Kotlin `explicitNulls=false`（null 不序列化）→ **旧帧字节不变**（金样本：无 hint 帧解析为 None、序列化不出现 device_hint 键、新旧帧互解）。Android 设置页「重装识别」开关（默认开，ReinstallHintPrefs 落盘；关掉=行为回到现状）。**段②合并**：daemon 收到带 hint 的 pair.request → `find_by_hint`（排除自身+revoked）→ PendingPair 带 hint_match → `pairing.pending` 每项 {name, hint_match}（桌面兼容老 daemon 字符串）→ 确认框多一组选项：**默认「替换旧的 <名字>」**（继承名字/备份记录/水位）+「作为新设备」（=现状全新流程）；`pairing.confirm` 带 `merge_node_id`（服务端校验 hex 必须匹配 hint_match——客户端伪造不成立为数据迁移）。合并语义：asset.src_device 归属迁移、backup_watermark 取 max、旧 device+watermark 行删除、审计 `device.merged`（from/to 双 NodeId）。**反证**：合并后旧 NodeId `backup.begin` 必须 NOT_AUTHORIZED（hello 对未配对节点本就允许——反证用 member-gated 方法）。**测试**：proto 金样本 +2（hint roundtrip / 旧帧 None）+ storage find_by_hint/merge_device 2 个 + daemon 集成 3 个（替换合并保留资产水位、作为新设备旧行原样、旧身份被拒）；ipc_flow pending 断言适配对象结构。**挂账（验收人）**：①真机重装→重扫→确认框默认「替换旧的」→旧行消失备份记录还在；②开关关闭→重装后出新设备行。 |
| **ICON-v1** | 2026-08-11 | 本 commit | ✅ 设计定稿归档（构建接入待 ICON-01 卡） | App 图标 v1 定稿：**碳纹版为主图标**（用户钦定），色阶版/屋脊兽版保留分工（屋脊兽=≤40px 退化基准）。设计=两个 P 面对面组成屋脊兽脸：P 圆弧作绿瞳眼（safe 绿=都存好了）、外挑双角、飞檐嘴，左实右虚（家/远端）、中心闪电在画布正中 (512,768) 分色（连接发生在两端正中间）。全部只用 tokens 色。九轮迭代过程廊 + 6 个 SVG 源 + 规格文档归档 `docs/design/2026-08-11-icon-v1/`。 |
| **REL-02** | 2026-08-11 | `96c61ae` `8b5362c` | ✅ 已实现（android 124/124 + vite build 绿；Worker 部署/真机双端验收挂验收人） | 更新通道分环境 test/stable（L2，用户方向 2026-08-10：构建→验收→人工 publish 才推给家人 + 开发设备有镜像环境）。**release.yml**：tag 含 `-test.` → 出包后自动 `gh release edit --prerelease`（GitHub latest 天然忽略 prerelease，绝不漏进 stable）；正式 tag 保持 draft 等人工 publish（人工 publish 就是验收后的发布动作）。**Worker**（infra/workers/update 升级为代理 Worker）：`/manifest?channel=test` → Worker 端解析最新 prerelease 的 manifest 字节原样透传（签名随字节不变，验签零改动），按 channel 缓存 300s；可选 GH_TOKEN 提限额。**Android**：设置页「更新通道」行 + 显式切换对话框（默认永远 stable，切通道立即重查）；test 通道 fetch Worker 静态 URL（`channelManifestUrl` 纯函数 + **stable 原 URL 锁死反证测试**——卡面「不准动」）；GitHub API 直连解析移除。**桌面**：设置页更新通道选择（localStorage，切通道即重查）；test 通道壳内 fetch Worker manifest + 弹窗 + 打开下载页（tauri updater endpoint 构建期写死/Update 无公开构造器——2.10.1 源码确认；且当前 manifest 只含 android-arm64 桌面壳待建，安装路径的诚实形态是下载页，卡面方案②+用户指正走 Worker 源）。**测试**：android **124/124**（+UpdateCheckerTest 3：stable URL 锁死/test 走 Worker/通道默认 stable）；vite build 绿。**挂账（验收人）**：①Worker 部署（wrangler deploy，生产配置 ppf-ops + DNS update.p-pass.hawkeye-xb.com）；②发一个 prerelease → test 通道检查到、stable 检查不到（双端对照）；③publish 正式 release → stable 检查到；④反证：test tag 留 draft → 双端静默无更新；⑤篡改签名 → 双端拒绝（既有测试不回归）。 |

| **UX-08** | 2026-08-11 | `07cd1b9` | ✅ 已实现（vite build 绿 + ipc_flow 8/8；UI 真窗口走查挂验收人） | 配对确认列表化 + 提示条治理（L1，用户真机反馈 2026-08-10：①「已允许 XX 加入」提示写进 message 后无清除机制一直挂着；②多台同时扫码确认弹窗一台台挤牙膏，用户不知道后面排几台）。**方向（用户拍板）**：pending 全部列出，一屏一个列表，每行设备名+允许/拒绝，处理完该行消失，全清后列表关闭。**daemon**：新增只读 IPC `pairing.pending`（`pending_names()` 全量返回；confirm 本已支持 `device_name` 逐台精确确认，不带则队首兼容，确认语义零改动）。**桌面**：`pendingList` 全量渲染（每行 name + deny/allow → `confirmPair(accept, name)` 带 device_name）；模态 `showConfirmModal && pendingList.length > 0`，全清自动关无残留；`flashMessage()` 统一全部 message 赋值（14 处 t() + 2 处硬编码）——**5s 自动消失 + 右侧 × 手动关闭**（反证：去掉定时器 → 提示条常驻）；CSS：pending-list/row/actions + message-close 弱化按钮（token 色）。**测试**：ipc_flow 8/8（新增 `pairing_pending_lists_all_waiting_then_confirm_by_name`——三台独立一次性 token 入队 → pairing.pending 全量三行 → 按名确认中间那台 → 剩两台 → 全清后 pending 空 + status.pending_pairs=0 + 设备表含被允许的 B；⚠️ 同一 token 只能被一台用，多台测试必须各自铸 token）；vite build 绿（173 modules）。**挂账（验收人）**：①模拟 3 台同时扫码真窗口一屏三行逐行处理截图；②提示条 5s 自动消失 + × 手动关闭实机观感；③反证：去掉自动消失定时器 → 提示条常驻（贴对照后还原）。 |

| **MOB-02** | 2026-08-11 | `e3931ba` | ✅ 已实现（android 121/121 绿；模拟器/真机验收挂验收人） | 备份触发模型重构（L2，2026-08-11 用户定稿，交互/文案照卡面不走样）：**§一首页**——「现在备份」主按钮删除，hero 空闲按钮=「选择相册」（主操作=选相册→BucketScreen 只到相册层级）；进度/暂停保留（UX-01 不动）；设置页低调「立即备份」（狗粮）；配对成功→引导进相册选择页→选完事件①触发首备份（配对本身不触发）。**§二权限**——manifest 补 `READ_MEDIA_VISUAL_USER_SELECTED`（部分授权态正确表达，免反复弹窗）；部分授权检测纯函数 `isPartialMediaAccess`（API 34+ 双权限同授）；部分授权不落死局：hero 变引导卡「只授权了部分照片——备份需要完整相册权限」+一键去系统设置，不保存范围、不显示假 0/0。**§三条件**——「需要充电/需要 Wi-Fi」两开关（默认开）；Wi-Fi 关闭二次确认（移动网络也会备份，可能消耗流量）；充电关闭后果文案「有新照片就会尝试备份（系统级监听，不额外耗电）」；设置页顶部合成句四种组合各有明确句子（`policySentenceKey` 纯函数）。**§四事件**——①选完/改完范围返回→用户在场档 `triggerUserPresentBackup`（只查 Wi-Fi 不查充电，`constraintsFor(USER_PRESENT)`），不满足排队+显示「将在连上 Wi-Fi 后进行」；②新照片落库→**ContentUriTrigger**（MediaStore 双集合，update 2min 安静窗口/max 15min 兜底=连拍聚合，unique work REPLACE 去重，零常驻监听零轮询）；③周期兜底 4h→6h；④App 进前台且距上次成功 >24h→用户在场档。**§五重试**——`BackupAttemptStore` 连续失败落盘（tmp+rename），短退避重试 2 次后 `Result.failure` 放弃本轮（成功/空扫/放弃清零，捞回交给下一触发事件），只在放弃时发 UX-02 失败通知；失败文案按定稿「本次备份没有完成，稍后会自动再试；也会随下次新照片或定时任务自动补上」。**§六新相册**——`BackupScopeStore.knownBucketIds` 基准 + `newAlbumIds` 纯函数：选过子集后新相册默认不包含 + BucketScreen「新」徽标；null=全量无徽标。**测试**：android **121/121**（107+14：TriggerPolicyTest 9 = 两档条件/重试裁决/新相册两分支/部分授权判定/content trigger delay 常量+文件级接线反证/unique REPLACE 去重/四组合合成句 + BackupAttemptStoreTest 3 = 递增落盘/成功清零/损坏读 0；TroubleTextTest 文案断言随用户定稿更新）绿 + assembleDebug 绿。**⚠️ 技术坑（记入 skill）**：work-runtime 2.10 的 content trigger API 在 Constraints.Builder（addContentUriTrigger/setTriggerContentUpdateDelay/setTriggerContentMaxDelay）不在 WorkRequest.Builder；mockable android.jar 的 SDK_INT=0 使 Constraints.build() 走 SDK<24 分支把 delay 强制 -1——WorkSpec 读不回 delay，验收 2 改用文件级接线反证（DOG-01d 同款手法）+ 真机连拍日志覆盖。**挂账（验收人）**：①模拟器 onboarding 全流程逐屏截图；②三星真机走完 选相册→授权→自动首备份 无死局；③连拍 20 张→只触发一次备份（观察 WorkManager 日志）；④部分授权引导卡实机观感。 |

| **MOB-01** | 2026-08-11 | `8d0b4b4` | ✅ 已实现（CI 全绿 android 107/107；模拟器截图/真机复核挂验收人） | 全页面安全区适配（L1，三星真机 2026-08-11 反馈：内容被底部导航键区遮挡/顶到状态栏，「不应该出现这种低级的兼容问题」；连带嫌疑 ScanScreen「手动输入」按钮被盖住被用户判为「功能没了」）。**根因**：targetSdk 35 强制 edge-to-edge，但全 App 零 insets 处理——内容画到系统栏底下。**修法**：①MainActivity `enableEdgeToEdge()`（API 35+ 行为统一，低版本主动开启）；②新增 `ui/PPScreen.kt` 全应用唯一安全区容器——Box + 背景铺满整屏 + `safeDrawingPadding()`（status bar / navigation bar / display cutout / IME 全让出，手势与三键导航由 WindowInsets 天然区分，不写死高度），一处封装全页面套用，不许逐页手搓；③系统栏图标深浅随背景亮度自动切换（`WindowCompat` inset controller——深色页面浅图标，Paper 页面深图标，enableEdgeToEdge 后默认只跟系统主题会隐形）。**覆盖全部页面**：Welcome/Scan/Joined/PairStatus（向导）+ TwoTabs 壳（照片时间线/备份页/设置/断开全在内）+ Bucket（相册选择）+ PhotoViewer + VideoScreen。**测试**：android 全量 **107/107** 绿 + assembleDebug 绿（唯一 warning 为既有 LocalLifecycleOwner 弃用，非本次引入）；CI PR Checks **success**（run 31366637154）。**挂账（验收人）**：①模拟器三键/手势导航逐屏截图（本机 VM 无嵌套虚拟化，HVF 不可用，TCG 软件模拟冷启动 >10min 超时，按用户指令跳过本地截图）；②三星真机逐屏复核 + ScanScreen「手动输入」三键导航下完整可见可点；③反证：去掉 insets 容器 → 三键导航下底部按钮必被遮（截图后还原）。 |

| **FIX-T6** | 2026-08-10 | 待推 main | ✅ 已实现（android 107/107，真机验收挂账） | 备份范围语义修复（L1，2026-08-10 巡检轮立卡，依赖 PERF-01 合并后做）：**①空集语义反转**——MediaScanner 用 `!bucketIds.isNullOrEmpty()` 做过滤开关，空集与 null 同义=全量：用户全取消相册 → 手动+自动都备份整库。修：空集直接返回空结果/0 不发查询（消「空 IN ()」风险），scanSince 空集水位不推进；手动备份空集显式反馈「没有可备份的相册」（新 BackupUiState.NoAlbums + StatusLine.NoAlbums，绝不显示假话「照片都存好了」），自动备份 no-op。**②三元组口径打架**——N=countAll(scoped) 按范围算、M=confirmedStore.count() 全库确认数：先全量备份再缩范围显示「手机 10 张 · 已备份 51」K 恒 0 谎报。修：ConfirmedStore 加 bucketOf（hash→bucketId，备份记录时从 MediaItem 带过来，手动+自动双通道 recordRun 都传）+ countInScope(bucketIds)（null=全量、空集=0、非空只数范围内；存量旧条目无 bucketId 视为范围内，随下次备份/exist-check 校准补齐）；computeTripletSafe 改用 countInScope——N/M 同口径一处定义。**验收③**：tripletOf 的 m clamp 到 n（UI 永不出现 M>N）。**测试**：ConfirmedStoreTest +4（A3/B5→M=3、旧条目视为范围内、M≤N 属性断言、recordRun 幂等带 bucket）+ MediaScannerScopeTest +3（空集 scan 空且水位不动、count=0、null≠空集走查询路径——反证：删守卫 → null resolver 空集路径触碰 resolver 必抛）；android 全量 **107/107**（100+7）绿 + assembleDebug 绿。挂账（真机，验收人补跑）：全取消→「没有可备份的相册」、缩范围后 N/M 同口径。 |
| **FIX-T3** | 2026-08-10 | 待推 main | ✅ 已实现（android 100/100，弹窗截图挂验收人） | 配对码升级顺序地雷（L0，2026-08-10 巡检轮立卡）：旧 APK（≤0.3.0-test.2）的 parsePairingQr 只从 `a=` 取 daemon 地址，H-10b-QR 后新码只带 `r=`——旧手机扫新码 addr=null 拨不出去静默失败（当时只验了「新 App 读旧码」，反方向没测）。**修法三件**：①桌面配对弹窗 QR 下加小字「手机 App 需 v0.3.1 或更新」（新 i18n key `ui.qr_phone_version`，四份 JSON 同步 + keys.rs 注册 ALL 65→66）；②Android PairFlow 缺地址分支文案改为「配对码无法解析，请把电脑端和手机 App 都升级到最新版」（非崩溃非静默，把话说清）；③CHANGELOG [Unreleased] 记升级顺序：先升手机 App 再扫新码。**测试**：PeerAddrTokenTest +1（`qrWithoutAnyAddressIsDetectable`——无 a= 无 r= → addr=null 且 relayUrl=null，上层据此给人话错误）；android 全量 **100/100** 绿（含 i18n 对称零漂移）+ diag 8/8 + desktop vite build 绿。挂账：桌面弹窗文案截图（模拟器/真窗口归验收人）。 |
| **FIX-SC2** | 2026-08-11 | 待推 main | ✅ 已实现（本地复现 + 根因 + 修复 + 反证；40/40 压力验证 + 149/149 全量绿） | blobs_resume 300s 超时 flake 根治（L2，三步走完）。**复现**：全量套件并行 + CPU 加压第 1 轮即撞 restart 卡死 115s；细化打点锁定卡点 = `Blobs::open`（FsStore::load），bind 秒过。**根因（栈实证）**：触发 = harness 竞态（in-process abort ≠ 进程死亡，redb 锁由独立 runtime 的 store actor 异步释放，固定 100ms 睡眠负载下不够 → 重开撞锁 DatabaseAlreadyOpen）；放大 = iroh-blobs 0.103 上游 bug（store 打开失败路径上 Actor::new future 被 drop → 连带 drop 所持 Runtime，RtWrapper::drop 在自身 runtime 线程上 block_in_place(drop(Runtime)) → BlockingPool::shutdown 自锁挂死，错误被吞 → 挂起而非 panic——所以之前「锁竞争=error」的排除推理被推翻：错误传不到 unwrap）。**修复**：100ms 固定睡眠 → 文件锁释放轮询（File::try_lock 探测 blobs.db，10ms 间隔 30s 上限）——把「等锁」变成事实而非赌时序。**验证**：同条件压力循环 40/40 全绿（修复前 2 次复现 + 死锁栈 = 反证）；本地全量 149/149。**上游报告**存档卡尾（未代发 issue）。**挂账（验收人）**：是否代发上游 issue；CI 复验连续绿。 |
| **FIX-SC1** | 2026-08-10 | 待推 main | ✅ 已实现（scenarios 本地 ALL GREEN，CI 复验中） | testclient 配对解析器没跟上 &r= QR 格式（L1，巡检定位：scenarios job 自 8/8 起 15+ run 全红，根因 H-10b 把 QR 从 `&a=` 完整 PeerAddr 改成 `&r=` relay URL 时，`tools/testclient/src/main.rs` 的 pair() 还停留在 `split_once("&a=")`——新 QR 无 `&a=` 时把整个 rest（含 `&r=` 尾巴）当 token → pair.request 带坏 token → daemon 拒 → confirm 队列空 → `err.unsupported`）。**修法**：新增 `parse_pair_qr`——`&r=` → `build_addr_token`（node+relay → base64url JSON，与 Android `buildAddrToken` 逐字段一致）重建 PeerAddr token；旧 `&a=` 原样透传兼容；无地址段 → None。testclient 加 base64 = "0.22" 依赖（与 transport 同版本）。**测试**：5 个新单测（新格式 token 不污染 + 重建 token PeerAddr 往返一致 / 旧格式透传 / None / 坏串拒绝 / relay host 匹配），testclient 7/7 绿；⚠️ 陷阱：node hex 必须用真实公钥（PublicKey::from_str 校验曲线点）。**实证**：本地 `huge_file.sh`（64M）+ `crash_recovery.sh` **ALL GREEN**（disk_full 平台跳过属预期）。fmt/clippy 绿。 |
| **PERF-01** | 2026-08-10 | 待推 main | ✅ 已实现（android 99/99 绿，真机验收挂账） | 备份哈希缓存（L1，2026-08-10 巡检轮立卡，**队列先做**）：T6 把手动备份改成 since=0 全量重扫+全量 blake3 重哈希后，千张库每次点「现在备份」都分钟级卡在 Hashing。**实现**：新增 `backup/HashCache.kt`——key = (MediaStore _ID, 修改信号)，API 30+ 用 GENERATION_MODIFIED、API<30 退 DATE_MODIFIED+SIZE（MediaItem 补 `dateModified` 投影字段）；value = blake3 hex；持久化 filesDir/hash-cache.json（tmp+rename 崩溃安全，损坏当空不崩，ConfirmedStore 同款套路）；`hashWithCache` 纯函数（miss 才 open 重算并回写）。**接线**：BackupUiStateHolder.runBackup（手动）+ BackupWorker.doWork（自动）hash 阶段先查缓存，缓存命中不再 openInputStream（open 工厂仍留给传输阶段 pushFile）；校准时刻（calibrateFromDaemon/calibrateIfReachable）顺手 `pruneHashCache` 清孤儿——跟随 MediaStore 现存 _ID 集合（MediaScanner 新增 `allItemUris()`，只投影 _ID 便宜查询）。**清理策略**：照片被删/相册被清后，孤儿条目随下次校准（App 打开/备份前，daemon 可达与否无关）清除；MediaStore 查询失败跳过，不影响备份。**验收①-③ + 反证**：HashCacheTest 7 个——第二次跑同一批 open 必须 = 0（内存态 + flush 后重开实例双验证）、generation 变化必须重算（open=1）、损坏缓存当空全量重算不崩、反证（空缓存 → open 全量 20 次，填满后第二次 0）、缓存 hash 与流式 blake3 逐位一致、prune 只留现存 uri、API<30 key 含 dateModified+size。**测试**：android 全量 **99/99**（92+7）绿 + assembleDebug 绿。挂账（真机验收，验收人补跑）：同一库第二次手动备份 Hashing 阶段秒级（贴前后耗时）。 |
| **H-10b-release** | 2026-08-09 | `9c66c76` | ✅ 已合并（0.3.1 正式发布） | bump 0.3.1（xixi 拍板 2026-08-09，正式发布）：T1-T7 全量（版本号显示、相册级备份范围、配对状态机、QR 瘦身、审计事件流、dmg 拖拽布局、macOS 签名公证、Windows NSIS 图形界面）；bump-version.sh 三端同步（Cargo/Android/desktop，versionCode 3→4）。0.3.1 的 Android 真机六项验收 + T-082/091/092 桌面真窗口走查挂验收人（NEXT「等用户」欠账不变）。 |
| **H-10b-T7** | 2026-08-09 | `5838e1c` `d802780` `2bb5f5f` | ✅ 代码已合并（真机验收待验收） | Windows GUI——桌面壳 NSIS 安装包进 release 管线（xixi 拍板 8/9）：Windows job 增建桌面壳（Tauri+svelte）NSIS 安装器，daemon.exe 作 externalBin sidecar、UPDATE_SIGNING_KEY 签 updater 产物、安装包进 SHA256SUMS 和上传；未签名（Authenticode 证书属 H-02，SmartScreen 会警告，文档如实说明）。**两个 test tag 实锤修复**：①`d802780`——Tauri externalBin 解析 `binaries/ppf-daemon-<triple>.exe`（x86_64-pc-windows-msvc），裸 `ppf-daemon.exe` 报 resource path doesn't exist（test.8 实锤）→ 带 triple 名复制 daemon；CHANGELOG 补 0.3.1 条目。②`2bb5f5f`——upload-artifact v4 多顶级路径时**按 top-level path 展平**，加 nsis 路径破坏了 release job 的 `windows-x64/daemon.exe` glob（test.9 实锤 no matches found）→ 拆两个 artifact（windows-x64 binaries / windows-x64-installer nsis）。验证=CI Windows job 本身（本 mac 无法本地构建 Windows）。验收状态：待验收（Windows 真机走查归 H-09/H-10b 验收人）。 |
| **H-10b-T6** | 2026-08-09 | `c4cfe94` | ✅ 代码已合并（真机验收待验收） | 相册级备份范围——选相册、再备份（两个动作）（xixi OPPO 实机反馈 8/9：「只能固定选照片或视频文件，要么全量，无法按相册处理」+「选择备份内容和备份是两个动作」+ T2「再点备份不能没有任何反应」）：MediaScanner `listBuckets()`（BUCKET_* 相册 id/名/count）+ `scanSince(watermark, bucketIds?)` + `countAll(bucketIds?)` 按选中相册过滤（null=全量，旧行为）；`BackupScopeStore` 持久化选中相册 id；UI 设置行「备份范围」→ BucketScreen（相册列表+复选框+全选/清空+「备份这 N 个相册」），Home 显示「全部相册/N 个相册」；手动备份重扫**选中相册全部**（since=0 忽略水位）后按确认缓存过滤只传新图，显式「已是最新」反馈（T2）；水位 commit 后推进，自动备份续跑；BackupWorker 自动路径同范围。**⚠️ review 实锤 3 个问题另立卡**（空集语义反转、三元组口径打架 → FIX-T6；性能 → PERF-01）。验收状态：待验收（T6 范围语义修复 FIX-T6 未合并前不验）。 |
| **H-10b-T5** | 2026-08-09 | `2922540` `924e121` | ✅ 代码已合并（真机验收待验收） | 审计事件流（xixi 反馈「log 居然不包含设备连接时候的数据，只审计了传输」）：audit_log 表本来就 extensible（action/detail TEXT）只是没人喂——补 pair.requested（每次扫码落审计）/ pair.denied（owner 拒绝/UI 超时也审计，pair.accepted 已有）/ backup.started+finished（session 级，ingested=N duplicates=M，互补 asset 级 commit 审计）+ `audit.list` IPC（{ts, action, actor, detail}，只读，上限 1000）；桌面「活动记录」页改渲染 audit.list 事件流（pair.requested/accepted/denied、backup.started/finished、device.revoked/unpaired、backup.commit、external.delete，人类可读行+相对时间，最新在前，未知 action 回退原始类型不吞），activity batches 保留兼容但页面以审计驱动。daemon 82/82。验收状态：待验收（桌面活动页真窗口走查归 T-082/091/092 验收人）。 |
| **H-10b-T4** | 2026-08-09 | `e565417` | ✅ 代码已合并（真机验收待验收） | 配对状态机（xixi 反馈「二维码在我连接完成后还持续展示」+「允许完成之后这个状态不消失隐藏」）：QR 改弹窗（点「添加设备」→ 360px QR popup，2x 渲染），非常驻卡片；关闭即弃码（下次打开新铸）；扫码落地（pending 0→>0）时 QR 弹窗自动关、允许/拒绝弹窗自动出；处理完请求（刷新见 pending==0）弹窗关——无残留状态、无常驻卡片；确认弹窗未起时保留 fallback pending 卡。验收状态：待验收（真窗口走查归验收人）。 |
| **H-10b-T3** | 2026-08-09 | `dec4f46` | ✅ 代码已合并（真机验收待验收） | 配对 token 32B→12B（QR ~170→~120 字符）：一次性配对 token 32B（64 hex）过度设计（10 分钟 TTL 一次性），12B（96-bit 熵）足够——token hex 64→24 字符，QR 总长 ~120，QR version ~11（61x61）→~8（49x49），模块密度约减半；IPC socket token 保持 32B（不同用途不动）；Android 透传 token（parsePairingQr→pair.request）零改动。daemon 82/82（含 12B token 的 qr_string_carries_node_and_token + pairing_flow expiry/used-token 用例）。验收状态：待验收（新码真机扫码实测归验收人）。 |
| **H-10b-T1** | 2026-08-09 | `3429966` | ✅ 代码已合并（真机验收待验收） | 版本号显示（xixi 反馈「没有版本号信息，每次都不知道安装的什么版本」）：桌面固定 footer「P-Pass v0.3.0」（tauri app API getVersion）；Android 设置行「版本 0.3.0 (3)」（BuildConfig.VERSION_NAME/VERSION_CODE）——报 bug 能报出确切构建。验收状态：待验收（目视，归验收人）。 |
| **H-10b-fix 批次** | 2026-08-08 | `ca75b82` `b480244` `052c890` | ✅ 代码已合并（真机验收待验收） | H-10b 真机反馈三修：①`ca75b82` **QR 密度**（xixi 实机扫不出）——`&a=` 完整 PeerAddr（id+relay+直连 IP，base64 100-180 字符，QR 总 300+）改 `&r=` 只带 relay URL（明文 ~30 字符，总 ~170）；Android 端 buildAddrToken(node, relay) 重建存储 token（backup manifest 解析零风险），旧 `&a=` 码双向兼容；daemon Pairing 加 relay_provider（transport PeerAddr::relay_url() 惰性）；桌面 QR 320px + 纠错级 L；**手机补手动输入入口**（ScanScreen「手动输入」粘贴配对码→校验 ppf://pair 前缀→同一配对流，strings en/zh）。②`b480244` **dmg 拖拽布局**（「dmg 不是无脑拖拽到 application 那种吗？」）——bundle-desktop-macos.sh 第 6 步重做：可写 UDRW 卷→挂载→丢 /Applications 符号链接→Finder 摆窗口布局（图标位置/图标视图/隐藏工具栏）→.DS_Store 烤进镜像→转 UDZO；osascript 失败非致命（无头 CI/TCC），Applications 链接已足够让拖拽路径明显。③`052c890` **QR 刷新按钮**（「二维码还无法刷新」）——token 活 10 分钟但步骤 3 无重铸入口，唯一出路是关向导或复制死 token；抽 generateQr()（首取和新按钮共用）加「刷新二维码」进向导导航，minting 中禁用。验收状态：待验收（新码扫码/拖拽安装真机走查归验收人）。⚠️ 2026-08-10 巡检发现 `ca75b82` 改 QR 格式但 testclient 解析器没跟上 → FIX-SC1（已修，见上）。 |
| **DOG-01d** | 2026-08-06 | 待 PR | 🔄 PR 待 review | countAll 真机崩溃修复（L1 加急，堵狗粮周；12:10 验收人插播：test.2 APK 三星首启必闪退，logcat FATAL `IllegalArgumentException: Invalid column count(*)` @ MediaScanner.countAll ← BackupUiStateHolder.refreshTriplet 启动即跑）。**根因**：countAll 用 projection `["COUNT(*)"]` 查 MediaStore——真机 provider（scoped storage）拒绝 projection 里的 SQL 函数，异常未接住 → 启动必崩（JVM 单测摸不到真 MediaStore provider，所以之前没炸）。**修法**：①countAll 改合规写法——projection 只放 `MediaColumns._ID`，用 `cursor.count` 取数（scoped storage 不许 SQL 函数投影）；②全链 Throwable 级兜底——`refreshTriplet` 生产实现抽成 `computeTripletSafe(resolver, store)`（internal，测试共用，DOG-01c 教训：语义测试走生产调用链），媒体查询/缓存读取任何异常 → 返回 null（UI 不显示三元组），绝不崩 App；③反证测试 `MediaQueryFailureTest`——null resolver（JVM 无法实例化 android.jar ContentResolver，构造即 Stub!；checkNotNull 抛 IllegalArgumentException 与三星 provider 拒绝同型）→ `computeTripletSafe` 不抛、返回 null（贴输出）。**验收**：android 全量 **74/74**（73+1 新测试）绿；文件级反证：`COUNT(*)` 仅存注释、`arrayOf(MediaColumns._ID)` 在 countAll、兜底 catch 在位。真机启动验收挂验收人。收尾（卡面指示）：合并后直接打 v0.2.1-test.3（versionCode 不动同 2 覆盖装；PPF_BUILD_VERSION 带 test.3，DAE-01 接管口径 test.3>test.2 已支持）。 |
| **DAE-02** | 2026-08-06 | 106cb57 | ✅ 已合并（11:47 真机双验收过：信号杀 5s 复活 / step_down 15s 不重拉） | daemon 常驻纪律补遗（L2，09:47 巡检轮验收人留卡，清理实战挖出的两个设计缺陷）：**缺陷① KeepAlive 无条件重拉退位实例**——plist `KeepAlive=<true/>`：StandDown/step_down 都是 exit(0)，launchd 照样每 ~10s 重拉 → 每次重拉又退位 → 永久空转 churn（升级接管场景必现）。修法：KeepAlive 改 `<dict><key>SuccessfulExit</key><false/></dict>`——主动退位（exit 0）不重拉；崩溃/被杀（非零/信号）照样复活（pkill 3 秒复活验收不回归）。plist 生成抽成纯函数 `macos::agent_plist`（pub(crate)，平台测试可断言）。**缺陷② QUIC bind 先于版本握手**——main.rs 里 transport bind 在 `claim_single_instance` 之前：用户 config 钉固定端口（41145）时，新实例 bind 失败直接退出（"Failed to bind sockets"），版本握手根本走不到，接管永不发生（验收人实测：0.2.1 新实例 vs 0.1.0 在位，bind 先炸）。修法：**claim 前置到 transport bind 之前**——socket_name 依赖 node_id，从 identity.key 直接派生（transport 新增 `node_id_from_secret_key`，不 bind endpoint），addr_provider 改 OnceLock 惰性填充（bind 后 set），claim 裁决后（StandDown 退出 / TookOver 重装 autostart / Proceed）才 bind，bind 后校验真实 node_id 与预派一致（防身份文件被换）。**测试**：dae_flow +1 集成 `fixed_port_incumbent_takeover_then_bind_succeeds`（在位实例真实 QUIC bind 固定端口 + serve IPC → 新实例**不 bind** 仅凭 secret 预派 node_id claim → TookOver → 前任退位（close+drop，模拟 exit(0)）→ 轮询重试 bind 同一端口成功——旧顺序在此直接失败退出）；transport +1（`node_id_from_secret_key` == bind 后 endpoint node_id 逐字节一致）；platform +1（plist 含 SuccessfulExit=false 且无 `<true/>`）。反证：把 KeepAlive 改回 `<true/>` → plist 断言必红（验收④真机项挂账：退位后 launchd 不重拉需真机 sleep 15 验证）。dae_flow 5/5 + workspace 209/209 + arch-check 绿 + clippy 零警告。期间处理环境问题：本机磁盘 100% 满（/tmp 场景遗留 5G + target incremental 9G 清理后恢复 7.4G）。 |
| **BUMP-01** | 2026-08-06 | 待 PR #43 | 🔄 返工已修，待 review | bump-version.sh 微卡（L0，05:47 巡检轮验收人留）：脚本末尾追加 `cargo update -w -q`（同步 Cargo.lock 的 workspace 成员版本——TAG-01 0.2.1 时脚本只改 Cargo.toml、首次构建弄脏 lock 靠手工 `6bb3239` 补，现在自动化）+ 干净断言（`git status --porcelain` 只允许 Cargo.toml / build.gradle.kts / Cargo.lock / 脚本自身在列，其余脏文件直接 exit 1——防杂散构建产物混进 bump commit）。**正演**：bump 0.2.2 → exit 0 + "ok: Cargo.lock workspace members synced; tree clean"，lock 15 个成员版本同步为 0.2.2，git status 恰好 4 个预期文件。**反证**：临时删掉 `cargo update -w -q` 行 → bump 后首个 cargo 命令把 lock 弄脏（git diff 10 行成员版本 0.2.1→0.2.2，TAG-01 事故复现），贴输出后还原。断言缺陷 #1：脚本自身未提交时被误判 dirty → 白名单补 `tools/bump-version.sh`（开发者可能带未提交脚本改动跑 bump）。**返工（07:47 轮，验收人裁决）**：`git status --porcelain` 把未跟踪文件（验收人机器 `?? .claude/`）也算脏 → 改 `--porcelain -uno`（只看已跟踪改动，未跟踪本就不会被显式 add 带进 commit）。**返工验证**：正演——带未跟踪文件（模拟 .claude/）跑 bump 0.2.2 → exit 0 + lock 成员版本同步；反证——README.md 弄脏 → exit 1 报 unexpected dirty files；bash -n 绿。 |
| **H-10a** | 2026-08-06 | 待 PR | 🔄 PR #26 返工已修，待 review | 10 分钟上手 quickstart 返工（重派卡，验收 = 文档资产名与 draft 逐字一致 + 不承诺不存在的东西）：README.md/README.zh.md 的 "Get started in 10 minutes" 章节对照 **v0.2.1-test.2 真实资产**改写——① 下载文件名写实（macOS `P-Pass-macos-arm64.dmg`、Android `app-release.apk`，逐字对照 draft 9 资产验证）；② **删掉假承诺**：原稿「Windows 选 .zip / unzip and run the installer」是假的（真实 Windows 资产只有 daemon.exe/testclient.exe 命令行工具，无 GUI 安装包）→ 改诚实说明「Windows 桌面版开发中，当前无可安装内容」；③ **draft 可见性提示**：release 目前是草稿（仅维护者可见），普通用户打开 release 页面看不到文件 → 新增提示「测试阶段发布可能标记为草稿，页面无下载=正式版未发布，过段时间再来或提 issue」；④ 旧说法清零（`.zip`/`unzip and run` 无残留，grep 验证）。分支同步：`docs/h10a-quickstart` merge origin/main（落后 30+ commits，ROADMAP 冲突块按规则取 main 侧 + H-10 行更新为当前事实：H-10a reworked / H-10c DONE / H-10b pending）。挂账：截图占位待人类补（H 任务）。 |
| **TAG-01** | 2026-08-06 | `756332b` + `9fb339f` | ✅ DONE | 打狗粮周 test tag（L1，出包卡）：`tools/bump-version.sh 0.2.1`（0.1.0→0.2.1，versionCode 1→2，diff 恰好只碰版本行）→ commit `756332b` 进 main → tag v0.2.1-test.1 **红（run 30949374415）**：Release 草稿 job「Sign update manifest」step 挂 `failed to decode base64 secret key: Invalid symbol 10, offset 348`——根因 = CI `echo "$UPDATE_SIGNING_KEY" > key` 追加尾换行（key 文件 348B 单行 base64，offset 348 恰为 echo 补的 \n，tauri signer base64 解码不 trim）→ 修复 `9fb339f`：`printf '%s'` 逐字节还原 + 重设 secret 无尾换行 + 本地 signer 签名预验证（cmp 字节一致）→ **v0.2.1-test.2 全绿（run 30950901275）**：四 job success——Android signed APK（**Assert APK contains libiroh_ffi.so step success**）、macOS arm64（zip + .app + dmg）、Windows x64、Release 草稿（**Sign update manifest step success**）；draft `v0.2.1-test.2` 9 资产：app-release.apk / daemon.exe / testclient.exe / BUILD_INFO-windows-x64 / ppass-macos-arm64.zip / P-Pass-macos-arm64.dmg / SHA256SUMS-macos-arm64 / SHA256SUMS-windows-x64 / **manifest.json**——SHA256SUMS 两平台齐、manifest.json 在资产 ✅。验收记录已写回 docs/NEXT.md 第三节卡体。下一手：验收人真机批量验收 + 本机 B 类孤儿清理 + 家人装包 → 压缩版狗粮周。 |
| **UX-06b** | 2026-08-05 | — | 🔄 PR #42 待 review | 断开连接时清确认缓存（UX-06 收尾微卡，L0）：断开确认分支在 `pairings.clear()` 旁新增 `clearConfirmedCacheForRemote(filesDir, daemonNodeId)`——删除该 remote 的 DOG-01 确认缓存目录 `backup-state/<daemonNodeId>/`（只删该 remote，不动别的），重配对到同一台电脑后 M 从 0 重新计数，不沿用旧缓存（电脑端删过库时 M 虚高，首屏是错的；漂移校准虽会修正但滞后）。生产函数与测试共用（DOG-01c 教训：测试走生产调用链）。**测试**：ConfirmedStoreTest +2——正演（写两个 remote 缓存 → 断开 A → A count()==0、B 原样 3）+ 反证（删除行缺失时 count() 仍 > 0；另附真·反证：临时注释生产函数删除行 → `disconnect_clears_confirmed_cache_for_that_remote_only` FAILED，贴输出后还原）。android 全量 **73/73**（main 71 + 2）。 |
| **UX-07** | 2026-08-05 | — | 🔄 PR #41 待 review | daemon ephemeral 模式（尽量项，L1，杜绝 A 类孤儿）：`--ephemeral` flag——stdin EOF 即整体退出（3 秒内）：stdin 循环 EOF 时 oneshot 发信号，serve 处 tokio::select! 竞争，EOF 分支**显式 close iroh endpoint**（flush 关闭帧；drop 清理要 ~6s 超验收线）。不带 flag 行为零变化（launchd 常驻不变）。`tools/dogfood-smoke.sh` 切 `--ephemeral` + FIFO stdin（cleanup 关写端 → daemon 自退 + wait，替代 kill；night 脚本从不 spawn 不动）。验收：EOF→exit **2.37s**（限 3s）exit 0 无孤儿；dogfood-smoke 全剧本 **ALL GREEN** 且收尾 pgrep 零残留；fmt/clippy 绿。挂账：android-*.sh 等其余 spawn 脚本后续逐个切。 |
| **DOG-01** | 2026-08-04 | — | 🔄 PR 待 review（DOG-01b 返工已修，真机验收挂账） | 备份恒真三元组 + per-device 水位（狗粮周阻塞卡，L2）：**daemon**——`storage.list_device_watermarks`（device LEFT JOIN backup_watermark + asset.src_device 计数子查询，revoked 排除）+ IPC `device.watermarks`（每设备 {node_id, name, last_backup_at, asset_count}，验收③数据源）；storage 测试 2 个（对照 + revoked 排除）。**android（DOG-01 原版）**——`TripletStore` + `tripletOf`（N=单次 offered、M=ingested+duplicates）+ HomeScreen 显示 + strings en/zh 对称。**DOG-01b 返工（2026-08-05，增量当全量 blocker）**：①**状态缓存表** `ConfirmedStore`——key=(hash, remote_id)，落 per-remote 目录 `backup-state/<daemonNodeId>/confirmed.json`（tmp+rename 崩溃安全；损坏当空不崩）；备份成功即写入，不依赖单次运行报告。②**口径重算**——N=MediaScanner 新增 `countAll()`（MediaStore COUNT(*) 全量，无 generation 过滤，范围常量一处定义）；M=缓存该 remote 确认条数；K=N-M clamp ≥0；`tripletOf(n, confirmedCount, lastSuccessAt)` 纯函数化。③**exist-check 校准**——`BackupReport` 新增 `missing`（manifest「给 hashes 回 missing」只查不传语义的产物），成功后 `recordRun`：missing 从缓存移除（电脑端库被删/换库漂移）、其余候选（daemon 确认存在含 duplicates）加入；手动（BackupUiStateHolder）+ 自动（BackupWorker）双通道同步。UI 启动即算一次三元组（断网走本地）。**测试**：ConfirmedStoreTest 6 个（**回归**：全量 100→增量 5 两次运行 N=105 M=105 非 N=5；**反证**：清缓存+全 missing → M=0 K=N；重开存活；漂移移除；损坏不崩；K 不为负）+ android 全量 **55/55** + storage 12/12（水位保留项复验）。**DOG-01c（2026-08-05，missing 时序错位 blocker）**：`recordRun` 不再减 `report.missing`——它是**上传前** manifest 应答，commit 成功后本次候选全部确认（`confirmedAfterCommit`，回归测试：首次 100 全 missing 全上传成功 → M 必须=100，反证改回旧语义必红已贴输出）；漂移校准与备份运行解耦为只查不传 exist-check（`BackupRunner.existCheck`：begin+manifest 不 push 不 commit，`removeMissing` 删 daemon 已无的 hash；缓存 100 → 回 30 missing → M=70）；接线：BackupUiStateHolder（App 打开 + 手动备份前）+ BackupWorker（跑前），daemon 不可达跳过；顺手删误入分支的 tmp-pr-t042b.md；附送 ipc_flow.rs harness 竞态修复（token 文件先于 bind 落盘 → 并行下 connect ENOENT，改轮询 connect，72/72 稳定）。android 全量 **56/56** + workspace **200/200**。挂账（真机验收）：①三星实测备份→杀 App 重开不归零、新拍两张重开 K=2 ②断网重开显示缓存值 ③ipc device.watermarks 与 sqlite 直查对照。 |
| **H-10b-QR** | 2026-08-08 | — | 🔄 已推 main（待 test.5 实测） | H-10b 真机实测两缺口（xixi 2026-08-08）：①**QR 太密扫不出**——配对码 `&a=` 是完整 PeerAddr（id+relay+直连IP，base64 100-180 字符），QR 总长 300+；改为 **`&r=` 只带 relay URL（明文 ~30 字符）**，总长 ~170；Android 端从 node+relay **重建** PeerAddr token（`buildAddrToken`，backup manifest 解析兼容零风险），旧 `a=` 码仍可解析（双向兼容）；daemon `Pairing::new` 加 `relay_provider`（transport `PeerAddr::relay_url()` 惰性取）；桌面 QR 渲染加大（320px + 低纠错 L）。②**手机无手动输入入口**——ScanScreen 加「手动输入」模式（粘贴配对码 → 校验 `ppf://pair` 前缀 → 同一配对流程）；strings en/zh。测试：Android 92/92（新增 newQrWithRelayParses/oldQrWithAddrStillParses/buildAddrTokenRoundTrips）+ Rust 104/104。 |
| **UPD-01** | 2026-08-04 | — | 🔄 PR 待 review（返工已修 2026-08-05） | 自更新通道（M3）：①**release.yml**——release job 产出 tauri 风格 `manifest.json`（`tools/make-update-manifest.mjs`：compose 模式收集平台资产 URL/sha256；sign 模式用 UPDATE_SIGNING_KEY 对资产 Ed25519 签名，seed→PKCS8 DER→KeyObject，base64 64B 签名）→ 作为 release 资产上传；签名 step 门控 `HAS_UPDATE_KEY`（secret 只进该 step env），无凭据路径 signature 留空 + notes 标注。②**android 自研更新流**——`update/UpdateChecker.kt`：启动时 GET `releases/latest/download/manifest.json`（draft/无 release 404=静默无更新）→ semver 三段比较 → 弹窗 → 下载 APK → **FileProvider + 系统安装器**（PackageInstaller 强制同签名校验兜底，不嵌公钥）；MainActivity LaunchedEffect 接入。③**desktop 已闭环（2026-08-04 晚）**——tauri-plugin-updater 接入（pubkey 真钥、createUpdaterArtifacts、updater:default）+ update.rs OFFICIAL_PUBLIC_KEY 真钥替换（21/21 测试含篡改必拒）。**密钥已完成**（用户授权代执行：tauri signer rsign 格式，UPDATE_SIGNING_KEY secret 已设）。**UPD-01 返工（2026-08-05，review 裁决）**：①i18n 捆绑字典漂移——`ui.update_*` 3 key 同步进 Android 捆绑副本，DiagTextTest 零漂移断言绿；②Android `downloadAndInstall` 主线程网络异常被吞——改 suspend + Dispatchers.IO（调用点 rememberCoroutineScope + launch）；③App.svelte 404 静默——tauri check() 对 404 是 reject 不是 null（只有 204 算无更新），原 catch 把 404 显示成「更新失败」；改为 check 阶段任何错误静默、仅安装阶段（用户主动触发）上文案；④`npx @tauri-apps/cli` pin 到 2.11.4（与 desktop pnpm-lock 一致，防 signer 格式漂移出坏签名）；⑤RELEASING.md §3.5 新增更新通道说明（darwin 挂账：updater 资产须 `.app.tar.gz` 含 lib/，H-10c 衔接；windows 挂账）；⑥ROADMAP 文案更新（密钥已完成、桌面已闭环，旧"等用户生成密钥"文案删除）。**测试**：UpdateCheckerTest 6/6 + android 全量 55/55（JDK 21）+ update.rs 21/21（含 `official_key_rejects_tampered_artifact` 反证）+ desktop `vite build` 绿。**UPD-01c（2026-08-05，i18n 注册 blocker）**：keys.rs 注册 `UI_UPDATE_AVAILABLE / UI_UPDATE_INSTALLED / UI_UPDATE_FAILED` 三键进 ALL（len 61→64）——此前四个 json 有键、注册表没键，diag 测试 panic "unregistered key"；四份 json（根 en/zh + Android 副本）与 ALL 字节级一致（零漂移断言兜底）；反证：临时删 en.json 的 ui.update_failed → `all_keys_translated_in_en_and_zh` FAILED（lib.rs:32），还原后 8/8 绿；diag 8/8 + android 55/55 + workspace 200/200；分支 CI 推后核绿。附送 ipc_flow.rs harness 竞态修复（同 DOG-01c，main 树既有 flake）。挂账：darwin/windows 桌面更新资产（H-10c/H-09）。 |
| **UX-01** | 2026-08-05 | — | 🔄 PR 待建（真机验收挂账） | 备份中可暂停（尽量项，L1，产品档案 §二「可干预」）：备份进行中主按钮变「暂停」且可点——`BackupUiStateHolder` 跟踪 backupJob，进行中再点 = `job.cancel()` 取消当前批（状态回 Idle）；`BackupRunner` 推流循环加 `coroutineContext.ensureActive()` 协作取消点（下个文件边界立即中断）。幂等管线保证安全：中断不 commit、水位不推进，已到家的 blob 下次 run 去重，再点 = 续传收敛缺 0。strings `backing_up` → `backup_pause`（en Pause / zh 暂停，StringsSymmetryTest 对称）。android 全量 **49/49**。挂账（真机）：①三星实测暂停→续传收敛缺 0 ②反证：暂停后 sqlite 无半条 asset 记录（ingest 只发生在 commit，设计保证）。 |
| **UX-02** | 2026-08-05 | — | 🔄 PR 待建（真机验收挂账） | 失败通知，成功沉默（尽量项，L1，产品档案 §二.6「失败通知是 100% 完成率承诺的另一半」）：自动备份（BackupWorker）批次失败才发系统通知——「N 张照片没备份成功，打开看看」（N=本次 batch offered 数，点开 PendingIntent 落 MainActivity）；成功零通知（FGS 静默通知随 worker 完成自动移除）。独立 channel `ppass.backup.failed`（IMPORTANCE_DEFAULT）；strings en/zh 对称。android 全量 **49/49**。挂账（真机）：①mock 一张失败→通知出现 ②全成功→零通知（dumpsys notification 对照）。 |
| **UX-04** | 2026-08-05 | — | 🔄 PR #38 待 review | 「已直连」徽章降级（尽量项，L0，产品档案 §二事实核查「OnlineDirect 是状态机默认值，是假话」）：桌面顶部徽章只说服务态二元——运行中（新增 `ui.service_running` 键，keys.rs 注册 len 61→62 + 四份字典同步字节一致）/ 后台服务未运行（复用 ui.offline_banner）；连接状态（直连/中继）不再上徽章，STATE_KEYS 映射从徽章路径移除（归属未来设备行，届时恢复）。验收=徽章文案不再出现「直连」字样（App.svelte 已无 stateLabel→online_direct 路径）。diag 8/8 + android 49/49 + workspace 198/198 + vite build 绿。附送 ipc_flow.rs harness 竞态修复（同 DOG-01c/UPD-01c，main 树既有 flake）。 |
| **UX-03** | 2026-08-05 | — | 🔄 PR #37 待 review（真机验收挂账） | 后台规则一行+极简设置（尽量项，L1，产品档案 §二.5「缺：备份页一句话说明规则 + 极简设置」）：备份页底部规则一行「插电 + WiFi 时自动备份，无需打开 App」+ 两开关（仅充电/仅 WiFi）。`BackupSettings`（filesDir JSON，tmp+rename 崩溃安全，损坏回默认，3 JVM 测试）持久化；`scheduleAutoBackup` 的 Constraints 改由设置构建（wifiOnly→UNMETERED else CONNECTED；chargeOnly→requiresCharging）；改开关 → 落盘 + `rescheduleAutoBackup`（REPLACE——KEEP 不更新既有任务约束，周期计时重置是用户主动改设置的代价）；启动路径仍 KEEP 幂等。android 全量 **52/52**。挂账（真机）：改开关后 dumpsys jobscheduler 约束随之变化（贴对照）。 |
| **UX-02** | 2026-08-05 | — | 🔄 PR #36 待 review（真机验收挂账） | 失败通知，成功沉默（尽量项，L1，产品档案 §二.6「失败通知是 100% 完成率承诺的另一半」）：自动备份（BackupWorker）批次失败才发系统通知——「N 张照片没备份成功，打开看看」（N=本次 batch offered 数，点开 PendingIntent 落 MainActivity）；成功零通知（FGS 静默通知随 worker 完成自动移除）。独立 channel `ppass.backup.failed`（IMPORTANCE_DEFAULT）；strings en/zh 对称。android 全量 **49/49**。挂账（真机）：①mock 一张失败→通知出现 ②全成功→零通知（dumpsys notification 对照）。 |
| **UX-06** | 2026-08-05 | — | 🔄 PR #40 待 review（真机验收挂账） | 移动端「暂停自动备份」+「断开连接」（尽量项，L1，产品档案 §二双端共通「任一端可单方停止」）：①暂停开关——取消周期任务（cancelUniqueWork）+ `AutoBackupPrefs` 持久化暂停态（filesDir JSON tmp+rename，损坏回默认，5 JVM 测试）；启动路径尊重暂停态（重开 App 不自动恢复）；手动「立即备份」不受影响。②断开连接——警示页说清后果（备份进度重算/家庭相册换库/本机照片不动/原电脑照片仍在）→ 确认后**设备自我撤销**（新协议动词 `device.unpair`：authz 放行任何已配对角色撤销自己、未配对/已吊销拒；router 标 revoked + 审计 device.unpaired；hello 随后被拒，新 token 重扫走 T-041 rejoin 门）→ 清 pairing/watermark/暂停态 → 回 Welcome。Rust 202/202（+2 authz +2 pairing_flow，反证移除放行必红已贴）+ android 55/55（+5 AutoBackupPrefs + DaemonUnpairTest live env-gated）+ clippy/fmt 绿。真机验收挂账：断开重扫重建 + 暂停 dumpsys jobscheduler 对照。 |
| **UX-05** | 2026-08-05 | — | 🔄 PR #39 待 review（文案截图挂账） | folder.set 诚实化（尽量项，L0）：改库位置确认文案如实说「重启后台服务后生效；已备份的照片不会迁移——新位置从零开始」——此前「重启生效」只写在保存后 toast（ui.change_saved），确认对话框（ui.change_body）没提。四份字典同步字节一致（零漂移测试覆盖）。diag 8/8 + android 49/49 + vite build 绿。验收（截图）由验收人执行。 |
| **DOG-02** | 2026-08-04 | — | 🔄 PR 待 review（真机验收挂账） | ROM 电池白名单引导（狗粮周阻塞卡，L1）：`battery/BatteryWhitelist.kt`——`isIgnoringBatteryOptimizations` 检测 + 厂商 intent 回退链（标准 REQUEST 对话框（需新权限）→ 三星智能管理器 BatteryActivity → 鸿蒙手机管家启动管理 → 通用列表，resolveActivity 过滤、全失败静默）；备份页引导卡片（未加白显示，加白后 ON_RESUME 刷新消失）；strings en/zh 同步（StringsSymmetryTest 拦漂移）。测试 49/49 绿。**真机验收挂账**：dumpsys deviceidle whitelist 前后对照 + adb 移除白名单反证（卡片重现）。 |
| **DAE-01** | 2026-08-04 | — | 🔄 PR 待 review（DAE-01b 返工已修） | daemon 常驻纪律最小集（狗粮周阻塞卡，L2，治 B 类孤儿「旧 daemon 值班、新 daemon 上不了岗」）：①**单实例锁**——`ipc.rs claim_single_instance` 替代 unlink-before-bind：先试连接（token 认证 + status 握手）→ 活实例在按版本裁决（`version_cmp` 数字段 + 正式>预发布，newest wins；同版本先来者留防 launchd 重拉循环）→ 新版接管：`daemon.step_down`（新 IPC 方法，响应后 200ms 优雅退出，可注入 hook 供测试）→ 等 socket 释放 → bind；死 socket 清理重绑。②**稳定路径**——`install_autostart` 拒绝 `/target/`、`/tmp/` 路径（不写坏 plist）；接管时胜者重装 autostart。③**status 扩展**——version/pid/started_at/exe_path（验收①数据源）。**测试**：version_cmp 单测（7 断言）+ `dae_flow` 集成 3 测试（新接管老退位 / 同版+低版让位 / 无竞争 proceed）+ **反证**（临时反转版本比较 → 2/3 红断言命中，贴输出后还原）。**DAE-01b 返工（2026-08-05）**：① blocker① token 错位——claim 改为**读前任 token（data_dir/ipc.token）握手**，绝不拿本实例新随机 token 探测（生产必 auth 失败被误判死 socket 抢绑 → 前任变幽灵占库锁）；token 改为 claim 成功后才生成（serve 写入）。新增**原始连接预检**区分死 socket 与活 peer：活 peer 不可认证（无 token 文件 / token 漂移）→ **StandDown 绝不抢绑**（反证测试：错 token → StandDown 且前任全程存活，恢复 token 后正常接管）。② blocker② 版本口径——CARGO_PKG_VERSION 无 -test.N 后缀（test.7/test.8 都自报 0.2.0 → Equal 永不接管）。选方案 a：`crates/daemon/build.rs` 读 `PPF_BUILD_VERSION`（release.yml 两平台构建步骤在 tag 事件注入完整 tag、去前导 v）→ `daemon_version()` 统一解析（PPF_DAEMON_VERSION > PPF_BUILD_VERSION > CARGO_PKG_VERSION），status/telemetry/握手同源；`version_cmp` 扩展**同核心双预发布按数字段比较**（test.8 > test.7）。**测试**：dae_flow 改 4 测试（两实例独立 token + 前任 token 落文件复现生产时序 + 反证）+ version_cmp 预发布段 6 断言 + build.rs 注入实测（带 env 二进制含 tag、无 env 不含、env 切换触发重建）；`cargo test -p daemon` 全绿。挂账：本机 B 类孤儿清理 + launchd 换正式接管由主会话在合并后执行（卡收尾）。 |
| **E2E-01** | 2026-08-04 | — | ✅ 验收 PASS（PR 待 review） | android live 剧本进 CI（M3）：`.github/workflows/e2e.yml`（新增）——nightly cron 03:30 UTC + **release tag 产物构建前门禁**（被 release.yml 以 reusable workflow 调用，macos/windows/android 三 job `needs: [e2e]`）+ PR 打 e2e label / 手动 dispatch；**每 commit 不跑**。三剧本脚本最小适配：`PPF_BIND_ADDR` 0.0.0.0:0 → 127.0.0.1:0（回环）+ **trap 改 `kill $DPID` 精确杀**（pkill -f 匹配不到环境变量会残留孤儿 daemon）+ 去 gradle -q（失败详情进 CI 日志）+ 失败时 dump daemon 日志尾部。**CI 实测抓出三个平台差异（本地 macOS 全绿但 CI 必炸）**：① **iroh 1.1.0 uniffi class 是 JDK 21 字节码（major 65）**——JDK 17 加载 UnsupportedClassVersionError（pr.yml android job 用 17 因 DaemonHelloTest 无 QR 跳过所以一直绿）→ e2e job 用 JDK 21；② **Linux IPC socket 在抽象命名空间**（ipc.rs GenericNamespaced：Linux `\0`+名 / macOS /tmp/文件）——DaemonPairTest/DaemonBackupTest 的 python ipcConfirm 写死连 `/tmp/` → 加平台分支（T-070 同款先例）；③ daemon 连 n0 relay + QUIC GSO 降级是 INFO 无害日志非失败。挂账：`tools/device-backup.sh` 有同类 /tmp 硬编码（不在 E2E-01 范围）。**验收**：正向 run 30886819356 全绿（HELLO OK / PAIR OK / BACKUP OK pushed=12 ingested=12 rerun dup=12 见于日志）+ **反证 run 30887278528 红**（临时改坏 SERVER_CAPABILITIES thumbnail.v1→v9 → AssertionError DaemonHelloTest:28，贴输出后 revert 92aa7b8）；actionlint 1.7.7 双 workflow 零报错。 |
| **REL-01** | 2026-08-04 | — | 🔄 PR 待 review | 版本与发布规范（M3，trunk-based 成文）：①`docs/RELEASING.md`（en 主 + zh 双语）——main 永远可发布、tag=SemVer release、hotfix 才开 `release/vX.Y`、draft→人工 publish、每 release 前 bump+changelog、**绝不覆盖/挪动已有 tag**（用户裁决"每个版本的问题都是独一无二的"）；②`CHANGELOG.md` 初始化（keep-a-changelog，首个正式 release 前全在 Unreleased，不造死链版本段）；③`tools/bump-version.sh`（100755）——一次同步 Cargo.toml workspace version ↔ Android versionName/versionCode（versionCode 单调 +1）。**防版本覆盖三闸**：已打精确 tag 的版本号拒绝（`git tag -l "v<ver>"`）、非严格递增拒绝（显式相等检查 + sort -V——相等时 sort -V 两行相同，head/tail 双端判断会放过，必须先判 `[ "$NEW" = "$CUR" ]`）、非法 SemVer 拒绝。⚠️ BSD awk 坑：`-F'[= ]+'` 把行首缩进当第一个分隔符 → `$2` 是 "versionCode" 而非数字，改 gsub 提取。**验收（五态测试全过）**：bump 0.3.0 成功且 `git diff` 恰好只改版本号行（Cargo 2 行 + gradle 4 行）；v0.2.0-test.7（已打 tag）拒绝；0.3.0（相等）拒绝；0.1.0（下降）拒绝；"1.2"（非法）拒绝。 |
| **H-10c** | 2026-08-03 | — | 🔄 进行中 | 面向人类的 release 资产（M3，分支 feat/h10c-human-assets）：**macOS**——`tools/bundle-desktop-macos.sh`（新增，复用 bundle-macos.sh 产出；不动其现有行为）：sidecar=bundle 后 daemon（rpath @executable_path/lib）→ `pnpm tauri build --no-bundle` + `tauri bundle` → **lib/ 塞进 .app/Contents/MacOS/lib**（daemon 依赖必须同包）→ codesign --deep 重签（无凭据路径 ad-hoc）→ hdiutil `P-Pass-macos-arm64.dmg`（21M）。**Android**——release.yml 新增 android job（JDK 17 + `assembleRelease`）→ `app-release-unsigned.apk`（无签名配置；正式签名 T-071 后续；⚠️ 本机 JDK 26 跑 lintVital 崩 `IllegalArgumentException: 26.0.1`——AGP 内置 Kotlin 编译器不认识 26，CI 用 17 无此问题）。**release job**：needs 加 android，dmg+apk 进 draft 资产；dmg/apk sha256 单独列 notes（**不进平台 SUMS**——zip 内 SUMS 与 release 资产必须逐字节一致，T-071 三重核对①）。**pnpm 11**：apps/desktop/pnpm-workspace.yaml 新增 allowBuilds esbuild（CI 可复现，desktop-build.md 已有坑记录）。本地验证全过：dmg 挂载出 .app（含 p-pass-desktop+ppf-daemon+lib/）、.app 内 daemon 隔离目录启动正常、**反证实验**：sidecar 改名错 → `resource path doesn't exist` exit 1（贴输出后还原）。待：PR → test tag 验收。 |
| **T-061b-fix** | 2026-08-03 | — | DONE | telemetry 破坏性变更对齐（T-061b 补充卡，PR #24 分支）：worker 只收 `/ingest` 后默认配置没跟上——客户端 `telemetry.rs` 直接 POST `&self.url` 不拼路径，默认 daemon 全部遥测 404 静默丢失。①`config/endpoints.default.toml` 默认 url 补 `/ingest`（+注释说明破坏性原因）；②`config.rs` layer1 测试断言 `cfg.telemetry.url.ends_with("/ingest")`；③`schema.ts` toDataPoint switch 补 `default: assertNever(event)` 穷尽保护（新增事件类型忘写 case = 编译错误而非运行时 `doubles = undefined`；反证：临时加 `fake_event` 到 union 不写 case → tsc 报 TS2345 `not assignable to parameter of type 'never'`，撤掉恢复）；④文件头旧注释更新（doubles 描述从"ts + every numeric field"改为 T-061b 固定列位，头部补 T-061b 标记）。验收：cargo nextest 5/5（含新断言）+ vitest 14/14 + tsc --noEmit 绿 + 反证报错贴出。 |
| **M2 收官** | 2026-08-03 | dd29243 | DONE | **T-056 真机最后一厘米 + verify-m2 总验收全绿，M2 全卡完成**（gate=全家狗粮一周仍开放，待正式产物）。①真机点开视频抓到**真 bug**：线格式 media_type 是金样本钉死的规格化值 `"video"/"photo"`，Kotlin 端判 `startsWith("video/")` 永不为真 → 所有视频落进图片查看器；修为 `startsWith("video")` 双兼容。修后三星实播用户 7/31 自录桌面视频（Mac 库拉回，连拍两帧 DIFFERENT 证在动）+ 3s 测试视频，双视频路由正确。②`just verify-m2`：185 Rust 测试 + Android 全测 + debug APK + 三 live 剧本（hello/pair/backup，BACKUP OK 12/12 幂等 0）。途中修复：三个 android-*.sh 的临时 daemon 继承用户 config 固定端口 41145 与常驻 daemon 相撞（固定端口改动的回归，CI 无用户配置不炸）→ 剧本显式 `PPF_BIND_ADDR=0.0.0.0:0`。**新挂账**：daemon 端视频缩略图生成失败（两条 mp4 thumb_state=2 → 灰色占位瓦片），M3 修。 |
| **T-071** | 2026-08-01 | — | DONE | release workflow（M3）：`.github/workflows/release.yml`——tag `v*` 触发（+dispatch 手工）。**macOS arm64 job**（macos-14，`environment: release-signing` 批准门）：build → bundle-macos.sh 自包含打包 → **codesign 门控**（`APPLE_CERT_P12` 等 secret 缺失即跳过，notes 标注"未签名"——无凭据路径即卡面验收）→ notarize+staple 门控 → SHA256SUMS → **SLSA attestation**（attest-build-provenance）→ artifact。**Windows x64 job**（windows-latest）：libheif 走 `media-codec/vendored`（源码内嵌，无 vcpkg）→ daemon.exe/testclient.exe + SHA256SUMS + attestation（Authenticode 证书属 H-02，当前标注未签名）。**release 草稿 job**：双平台分目录下载（避免 SHA256SUMS 覆盖）→ notes 组装（版本/构建 SHA/签名状态/双平台 SHA256/**VT 提交门控**/验证三步指引）→ `gh release create --draft`。**secret 槽位**：gh secret set 预建 APPLE_* / VT_API_KEY 空值（门控 `!= ''` 双兼容），获取指引待 H-02。验收 ✅：测试 tag v0.2.0-test.1 三轮拉锯后全链走通——macOS 6m48s（无凭据路径 codesign 步干净跳过）+ Windows 22m25s（vcpkg static-md 静态 libheif 从源码编译成功，daemon.exe/testclient.exe 产出）+ SLSA attestation + 草稿 Release（11 资产 + 双平台 SHA256 notes）。三轮修复：① vendored 特性未传播 → Windows 改 vcpkg（x64-windows 动态版 triplet 不匹配 → ② static-md）；③ secrets 误填字面量（echo "$s=" 把 "NAME=" 当值）→ 清空所有槽位；④ dispatch 时 GITHUB_REF_NAME=main 导致草稿打错 tag → event_name 感知。凭据路径待 H-02（证书在本机钥匙串，导出需用户交互授权）。 |
| **T-072** | 2026-08-01 | — | DONE | i18n 全量 + 拦截指引（M3）：①**桌面壳吃 diag 字典**——`App.svelte` 的 stateLabel 从硬编码中文表改为 import 仓库根 `assets/i18n/*.json`（vite fs.allow 覆盖，零副本零漂移），按系统语言选语言表（单语显示既定决策），新增 `t(key, vars)` 渲染器；②**安卓端 msg_key→人话**——`i18n/DiagText.kt`（纯函数 `resolveFromJson` + Android `resolve`，`{placeholder}` 格式化，未知 key 返回 null 绝不崩溃），捆绑字典到 `app/src/main/assets/i18n/`，`MainActivity` 的 PairFlow.Refused 从通用文案改为按 msgKey 渲染具体原因（未知回退通用）；③**覆盖测试三件套**（验收"assert_all_keys_translated 覆盖 UI 层新 key"）：`DiagTextTest`（en/zh key 集一致+双语文案非空+占位符格式化+未知 key null+**捆绑资产与仓库源零漂移**字节级断言）、`StringsSymmetryTest`（strings.xml en/zh 键集一致+无空值——UI 层新增文案漏一种语言即红）、Rust 侧 `assert_all_keys_translated` 原样（10 key 双语文案，CI 既有）；④**`docs/troubleshooting/blocked-by-av.md`**——被拦截怎么办（官方态度：SHA-256+attestation 三步验证先行；Defender/SmartScreen/第三方杀软三场景 + 误报申诉流程；截图占位标记 `[截图: …]` 由 H 补图）。范围线：桌面壳按钮/标签类文案仍单语 zh（T-042 向导重构时统一收编）；**备份失败路径的 msgKey 透传**（BackupRunner 现在 check() 即崩、不上报错误码）挂账——需要产品决策（失败展示语义）。验收：桌面 `vite build` 0 退出；安卓 `testDebugUnitTest` 全绿（CI 跑，本机装 JDK 后真跑确认）。 |
| **T-070** | 2026-08-01 | — | DONE | 故障剧本自动化（M3 gate 第一项，五剧本）：**进程内两剧本**（`crates/daemon/tests/scenarios/`，`#[path]` 挂载——cargo 集成测试只认 tests/*.rs 顶层，mod.rs 子目录不会被当作测试目标）——①**时钟前跳**：Router 新增时钟缝 `with_clock`（Arc 闭包，默认墙钟；本剧本不碰系统时钟），墙钟前跳 11 分钟（>令牌 TTL 600s）→ 在途配对令牌即时过期被拒（NOT_AUTHORIZED）、daemon 健康、钟恢复后**同一令牌复活**（钉住"过期在请求时评估"契约 pairing.rs:140；并发现已配对设备走 pair.request 会被 authz 配对之门拒——T-030 语义）；②**吊销中断传输**：begin+manifest 后吊销 → commit 在门禁处切断（NOT_AUTHORIZED）、水位不推进、零入库、后续请求全拒、他设备 hello 正常（钉住"commit 一旦分发无二次鉴权，中断发生在门禁"的架构语义）。**进程级三剧本**（`tools/scenarios/`，dogfood-smoke 模式）：③**4GB 大文件**（默认 2G 保 CI 磁盘——峰值≈3×size=blob+staging+originals，卡面 4G 用 `PPF_SCENARIO_SIZE=4G`；稀疏文件零实际占用+全零内容保证跨运行 hash 确定→幂等保留；testclient 新增 `--file-size`（set_len 稀疏+blake3 update_reader 流式哈希））→ 备份 2G 全链 200s、落盘逻辑大小校验、幂等缺 0；④**崩溃恢复**：512M 备份中 SIGKILL → 同 data_dir 重启 → 重跑收敛（missing 现算补 1）→ 幂等缺 0 → 落盘存在（rebuild 守护语义的进程级复现）；⑤**磁盘满**：6MB tmpfs 挂载、data_dir 全在 tmpfs 上，备份爆盘 → daemon 不崩、IPC 仍响应（Linux 专属，macOS 显式 SKIP；CI ubuntu 真跑）。**配套**：justfile `scenarios` 配方 + pr.yml 新增 scenarios job（release 构建 + 三剧本，卡面"五剧本 CI 绿"= 本卡授权该 CI 步骤）。验收：本地 2/2 进程内 + 2/3 进程级全绿（disk_full CI 跑）+ clippy/fmt/arch-check 绿。 |
| **决策** | 2026-07-31 | — | DONE | **relay_urls 默认改空列表**（用户裁决）：`config/endpoints.default.toml` 三区域域名（relay-us/eu/ap.p-pass.hawkeye-xb.com）在 H-07 部署前解析不到，会毒害路径协商（dogfood 冒烟实证，此前靠 `PPF_RELAY_URLS=""` 手动缓解）→ 默认 `relay_urls = []`，注释保留恢复清单；H-07 上线后恢复三区域。配套：`config.rs` layer1 测试断言同步（契约对齐非弱化，注释写明裁决）。验收：config 5/5 测试绿。 |
| **T-064** | 2026-07-31 | 2026-08-03 | DONE (T-063b) | 官方 relay 部署模板（P6）：`infra/relay/`——`cloud-init.example.yml`（VPS 初始化：装 docker+拉仓库+起 relay，占位符域名） + `kuma.example.yml`（3 区域 relay + rendezvous/telemetry/update-manifest 探针模板，expectedBody 校验）+ README（区域规划表 US/EU/AP + H-07 使用步骤 + relay-down runbook 指针）。**全占位符，无真实 IP/域名/凭据**；真实值在私有仓 `ppf-ops/deploy/relay/`。**T-063b 真机修复（2026-08-03，Vultr SG）**：cloud-init 现在创建 .env（旧版从不建）、sed 就地编辑（旧版重定向掉 -i 输出）、ufw 真正 `allow`+`--force enable`（旧版只写 profiles 从不启用）、compose up 前 certbot standalone 签 Manual 证书；kuma 探针改 `/healthz` 端点（真机实测 200）。 |
| **T-063** | 2026-07-31 | 2026-08-03 | DONE (T-063b) | 自建全套（P6，卡面最大）：`infra/selfhost/`——`docker-compose.yml`（iroh-relay + rendezvous 自建容器 + caddy TLS 反代；pkarr 以 `profiles: ["discovery"]` 预留，默认不开——客户端 QR 自带地址零发现依赖，Phase 2 再启用；端口布局：80/443→caddy、8443→relay HTTPS、7842/udp→relay QUIC）+ `rendezvous/Dockerfile` + `Caddyfile` + `.env.example` + `relay-config.example.toml` + `SELFHOST.md`（双语从零 VPS 指南）。**环境硬限制**：本开发机是虚拟机（VZ 报 "Virtualization is not available"），docker 无法本地实跑——**T-063b 真机闭环（2026-08-03，Vultr SG）**：①`.env` 缺省 compose 解析崩 → `${RENDEZVOUS_DOMAIN:-默认值}`；②relay 内置 LetsEncrypt 在 80/443 被占时签不出 → 改 certbot standalone + Manual 证书（真机实测）；③healthcheck exec-array 把 `>` `/dev/null` 当 wget URL 且 `/` 404 恒失败 → CMD-SHELL + `https://:443/healthz`（真机 200）；④**官方 relay 镜像 musl panic**——`n0computer/iroh-relay:v1.0.3` 是 Alpine/musl，noq-udp 1.1.0 cmsg 对齐断言 panic（QUIC 一跑 SIGSEGV，容器 Restarting(139)，真机复现）→ 新增 `relay/Dockerfile`（debian/glibc + 官方 GitHub release 二进制，healthcheck 装 wget）；⑤rendezvous `node:22-alpine` 上 workerd spawn ENOENT（musl 缺 glibc interpreter，真机复现）→ 换 `node:22-slim`，healthcheck 用 node fetch（slim 无 wget）；⑥SELFHOST.md 按实测重写。**验收（真机）**：relay 容器 healthy 稳定、Restarts=0、公网 `https://relay-ap.p-pass.hawkeye-xb.com:8443/healthz`→200、rendezvous `{"ok":true}` healthy、`PPF_RELAY_URLS=<自建 relay>` dogfood-smoke **ALL GREEN**（relay 日志实证本机连接转发）。 |
| **T-062** | 2026-07-31 | — | DONE | 更新清单（P6）：`infra/workers/update/`——`manifest.example.json` + 双语 README（格式规范 + 签名约定）。格式：`{version, notes, pub_date, platforms: {<os>-<arch>: {url, sha256, signature}}}`，架构名统一 arm64/x64；`manifest.json.sig` = 对发布字节的分离式 Ed25519 签名（防篡改 by construction）；公钥内嵌客户端；每个产物 `signature` 字段钉死下载。**daemon 侧小改**（卡面点名）：`crates/daemon/src/update.rs`——纯函数模块：`Manifest::parse`（deny_unknown_fields 严格解析）/`platform_key`/`select_platform`/`is_newer`（semver 严格比较，预发布低于正式版）/`verify_manifest`（ed25519-dalek verify_strict）/`check_update`（验签→解析→比较→平台产物，返回 UpdateInfo|None；平台缺失=显式 NoPlatform 错误而非静默 None）。**故意不接 main.rs**——抓取循环/重试/UI 归 T-071 发布管线。新依赖：semver@1 + ed25519-dalek@3（**均已在树上**，iroh 传递，直接声明，Cargo.lock 零新增，与 T-031 getrandom 同先例）。验收：**11/11 单测绿**（解析/未知字段拒绝/平台键/版本比较含预发布/验签/篡改字节必败/错钥必败/垃圾签名/check_update 全流程）+ fmt/clippy -D warnings/arch-check 全绿。 |
| **T-061** | 2026-07-31 | — | DONE | 遥测入口（P6）：`infra/workers/telemetry/`——zod 严格校验（手册 §8 字典）→ Analytics Engine 写入。schema 与 T-035 Rust 客户端线格式逐字段对齐（`crates/daemon/src/telemetry.rs` 为唯一事实来源，含"客户端只发一个 ver"的行为）；`.strict()` 拒绝未知事件类型与未知多余字段；**整批严格**——一个非法事件拒绝整批 400（客户端本就丢弃失败批次，响亮失败暴露漂移）；硬上限 body ≤1MiB→413、batch ≤100→400。AE 映射：`indexes=[event]`（按类型分组）+ `doubles=[ts, 数值字段]` + `blobs=[完整事件 JSON]`（自描述无损）。`ingest(ae, batch)` 依赖注入——测试用录制假 AE 断言写入次数，HTTP 层走真绑定（SELF）。`wrangler.toml` 声明 `[[analytics_engine_datasets]]` 绑定（dataset ppass_telemetry，占位提交）。验收：**12/12 vitest 绿**（合法四事件→4 次写入且 blob 无损/doubles 只含数值/未知事件拒/未知字段拒/类型错拒/空批拒/超 100 拒/HTTP 200+400+413+健康）+ `tsc --noEmit` 干净。 |
| **T-060** | 2026-07-31 | — | DONE | 会合服务（P6 第一张，实施计划 §P6）：`infra/workers/rendezvous/`——CF Worker + 单实例 Durable Object（`idFromName("global")`），异地配对短码信封交换。API：`POST /code {code_hash, sealed}`（TTL 600s）→ 201/400/429；`GET /code/:hash` → 200 `{sealed}` 一次性读取（二次读 410）/404（从未存在）/410（已消费或过期）；`GET /` 健康检查。安全语义按详细设计 §2.2/§6：服务器只存 code 的 SHA-256 hex + 不透明信封（≤2048B），永不解析信封——NodeId 由客户端用短码派生密钥加密保护；防爆破=每 IP 限频（POST 10/min、GET 30/min）+ 错 5 次销毁（同一 IP 一分钟内 5 次失败查询 → 该 IP 本窗口封禁 429）。限频计数走内存（DO storage TTL 已被 CF 平台移除；单实例一致性，重启仅重置滥用计数，附 1024 条上限窗口清扫）。alarm 按 TTL 清扫过期码。`wrangler.toml` 占位提交（无真实 account_id，dev/test 不需要），`wrangler.toml.example` 模板；生产部署配置归私有仓 `ppf-ops`（隔离方案 §2）。README 双语：API 表 + 客户端流程 + 跨语言契约（code_hash 约定 = 6 位短码 UTF-8 补零的 SHA-256 hex，Kotlin/Rust 客户端必须一致）。技术栈：TypeScript 零运行时依赖 + vitest-pool-workers 0.20（**新 API 三坑**：`./config` 入口移除改 Vite 插件 `cloudflareTest`；workers-types v5 的 DO 基类改 `import { DurableObject } from "cloudflare:workers"`；DO 类须从入口 re-export + `additionalExports` 钉导出类型；DO storage TTL 参数移除）。验收：**7/7 vitest 绿**（存取/独立 hash/过期/5次销毁/限频/校验/健康，真 Miniflare Worker+DO，SELF 绑定走 HTTP）+ `tsc --noEmit` 干净。 |
| **T-041** | 2026-07-30 | — | DONE | Tauri 托盘壳（ADR-012 字面兑现：壳内零业务逻辑）：apps/desktop（Tauri v2 + Svelte 5，**独立 workspace**——巨型依赖树不进主仓 CI）；Rust 侧仅一个 `daemon_call` 转发命令连 T-034 IPC（interprocess 阻塞客户端，每调用一连接）；托盘图标+菜单（打开/退出）、关窗即隐入托盘；设置窗：状态徽章 3s 轮询（人话状态映射）、配对 QR（qrcode.js）+允许/拒绝、设备列表+原生确认框移除、库文件夹选择（原生目录选择器+路径回显）、诊断包导出（**自动在 Finder 中选中**）。产物：P-Pass.app + **3.2MB dmg**。**人工走查（8 步）抓修 4 个真问题**：①vite6×vite-plugin-svelte4 不兼容→Svelte 编译成 SSR 版白屏（升 plugin@5+加"前端错误直显"兜底页）；②Tauri v2 ACL 拦截 dialog 插件（补 capabilities/default.json 权限清单）；③**产品 bug：被移除设备永远无法重新加入**——authz 给 revoked 设备留 pair.request 一扇门（新令牌在 owner 手里=授权），确认后显式 unrevoke（storage 新 API，与"upsert 不解除吊销"防误触并存），审计标注 rejoined，集成测试钉死；④UI 反馈缺失（文件夹路径回显、诊断包 Finder 展示、opener 插件+权限）。走查全过（人类验收）。**产品债记账**：daemon 需手工指定 data_dir——T-042 向导内置"启动/托管 daemon"实现双击即用。 |
| **T-040** | 2026-07-30 | — | DONE | platform trait + 双实现（架构 §4 原样）：`lib.rs`——PlatformAdapter（自启注册/查询/注销、service_mode、key_store、assert_awake RAII、power_hint、notify、data_dir）+ ServiceMode/PowerHint 枚举 + **pmset/powercfg 纯解析器跨平台单测**（6 测试：sleep=0/取最小正值/displaysleep 不算/hex 秒转分/0=永不睡/垃圾=Unknown）。`macos.rs`——LaunchAgent plist（RunAtLoad+KeepAlive=免看门狗）+launchctl bootstrap/bootout；**防睡眠=caffeinate -i 子进程 RAII**（零 FFI，pmset assertions 可见，IOKit 归 Phase 2 注记）；Keychain（security CLI generic password，hex 存储）；数据目录=~/Library/Application Support/P-Pass。`windows.rs`——HKCU Run 键（winreg）、SetThreadExecutionState RAII、DPAPI 密钥文件（CryptProtect/Unprotect + LocalFree，unsafe 注释齐）、powercfg SUB_SLEEP/STANDBYIDLE 查询；**CI 新增 x86_64-pc-windows-msvc 交叉 check** 保证 Windows 代码持续可编译（真机冒烟归 H-09）。**新依赖（Windows target 专属）**：winreg@0.55、windows-sys@0.61。验收：`just platform-smoke`（examples/smoke.rs 人工验收剧本）**macOS 真机 ALL GREEN**——自启注册→查询→注销干净、**防睡眠断言计数 2→4→2**（持有升释放降，计数法免疫无关 caffeinate）、Keychain 存取删全通、power_hint 实测解析出本机"10 分钟睡眠"；全仓 **166 测试绿**；just ci + deny 绿。 |
| **家庭狗粮首跑（办公→家跨网）** | 2026-07-30 | 7ffe443 | DONE | **产品真实形态第一跑**：家里干净 Mac（受限 Agent Sandbox，无 brew/无 Xcode/无 git）跑自包含 bundle daemon——①**自包含包问题根治**：libheif 的 cmake 会动态链接构建机上所有编解码器，`tools/bundle-macos.sh` 递归收集 12 个 dylib、改写加载路径到 @executable_path/lib、临时重签、校验残留外部依赖=空（curl 即装，零依赖）；vendored feature 同时落地；Actions macOS job 改产 bundle。②家侧本机全剧本 ALL GREEN。③**办公→家跨网全剧本**：配对+远端 IPC 确认 ✓；backup 200——**跨设备去重生效**（家侧已有 32 个同内容只传缺的 149，2m43s）；幂等缺 0 ✓；browse 181 项+缩略图 ✓；吊销后跨网 revoke-check/backup 双双正确被拒 ✓。④**连接路径实测=Relay（RTT 462ms）**——testclient 接入 ConnInfo 打印（诊断接口第一次真实使用），办公桌面网段无全局 v6 只能中继，**与 H-04 场景 7 复验结论精确一致**。⑤新账：每 blob 一次新连接在高 RTT 下开销放大（149×462ms 握手），**同 peer 连接复用**记优化账；H-07 自建 relay 价值再实证。 |
| **双机跨公网验证** | 2026-07-30 | fee8f3e | DONE | **第一次真实互联网双机全剧本**：阿里云 daemon（Ubuntu 24.04，产物二进制，UDP 41145 钉安全组）×办公 Mac testclient，跨公网全部通过——①配对（QR+远端 IPC 抽象socket 确认+白名单落表）；②**backup 200 文件 5.9s**（含去重协商+**阿里云反向穿透办公 NAT 拉取 200 blob**——观察地址+UDP 打洞，印证 H-04 v4 打洞结论）；③幂等重跑缺 0 零传输；④browse 181 项（=200 去重后）分页无重复+缩略图解码 OK（**Linux libheif 管线实战工作**）；⑤吊销→revoke-check 正确拒绝→backup 被拒；⑥logs.export；⑦磁盘 181 文件=索引。配套基建：**artifacts.yml**——push 即出 Linux 二进制强推 `bin-linux-x64` 孤儿分支（纯 git 分发，云机 `git clone -b` 秒级拿产物，替代 2 核小机 40 分钟编译）；`PPF_BIND_ADDR` 配置钉端口。**新发现记账**：①QR 初始地址段是内网 IP（iroh 启动瞬间未完成公网地址探测——与 H-04 Android probe 缺陷④同源！需 PPF_ADVERTISE_ADDR 或等 relay ready 再出 QR，本轮手工构造公网地址验证）；②Linux 的 IPC socket 在抽象命名空间（连接用 `\0`+名字，非 /tmp 文件——冒烟脚本需适配）；③自报地址（同网直连）与观察地址（跨 NAT 打洞）两机制互补，各有生效场景。H-04 旧 iroh-probe 监听端已停替换为 daemon。 |
| **狗粮冒烟 #1** | 2026-07-30 | 19ae7c2 | DONE | **第一次生产形态真机运行**（release 二进制、真实网络栈、三进程分饰：daemon=狗粮机/testclient=手机/IPC=托盘 agent），实验室测试永远暴露不了的 5 个真 bug 全修：① 首启崩溃（.ppf 目录未建）；② **后台运行自动秒拒一切配对**（stdin EOF 被当"非 y"——现 EOF 即退出控制台确认，只走 IPC）；③ 无日志（tracing subscriber 接 stderr/RUST_LOG）；④ **QR 无地址段**——办公网屏蔽 n0 发现服务扫码连不上；PeerAddr 获得字符串序列化（base64url JSON），QR 加 `&a=<addr>`，扫码即连零发现依赖；⑤ 反向拉取依赖"入站观察地址"时序敏感——**BackupManifest 加 provider 字段（自报地址，线兼容）**，testclient 身份持久化（testclient.key）+ daemon 地址 sidecar。产出 `tools/dogfood-smoke.sh`：配对→备份→幂等→浏览→吊销→日志导出全剧本一条命令，**agent 可无人化执行**（狗粮机验收方式，人类裁决落地）。真机通过：配对+IPC 确认、backup 50 去重 46、幂等重跑零传输、browse 分页+缩略图、吊销即拒、logs.export 脱敏。**已知问题（记录在案）**：同机反向拨号在配置的 relay 不可达时间歇超时——T-004 默认端点写了 H-01 规划域名但 H-07 未部署，**未部署的 relay 域名会毒害路径协商**（`PPF_RELAY_URLS=""` 缓解）；真双机验证移交 Mac mini 部署。 |
| **T-035** | 2026-07-30 | — | DONE | 遥测客户端（手册 §8 事件字典 v1 原样实施）：`telemetry.rs`——四事件逐字典（conn{path,ipver,ms,fail_stage,country,isp_hash}/backup_session{files,bytes,dur_s,resumed,trigger}/first_byte{ms,kind}/daemon_alive{uptime_h,os,ver}），每事件带公共字段 anon_id/ver/ts；**anon_id 首启随机 16B 持久化**（纯随机，与硬件/用户/路径零关联）；批量队列每 5min flush；发送失败丢弃不重排（尽力而为，坏端点不能撑爆内存）。**`enabled=false` 的零网络承诺做到根上**：record 门口即丢、flush 直接返 0、run 不起定时器、**连 anon_id 都不铸造**（有测试钉死）。main.rs wiring + 24h daemon_alive 心跳。**新依赖待人类追认**：reqwest@0.12（rustls，无默认 tls）。验收（卡面两点全中）：**mock HTTP server 收到批量并逐字段 schema 校验绿**（数组 4 事件、公共字段齐、字典字段抽查、无路径样字符串）+ **关闭开关后零请求断言绿**（record+flush 后 mock 计数=0）；全仓 **161 测试绿**；just ci + cargo deny 绿。 |
| **T-034** | 2026-07-30 | — | DONE | IPC 本地服务 + 诊断聚合（ADR-012）：`ipc.rs`——interprocess 本地 socket/named pipe（跨平台无 cfg，守 B.2），**每次启动随机 32B 令牌写数据目录 ipc.token**（内容=socket 名+令牌，UI 凭它发现并认证 daemon）；线格式=行分隔 JSON（首行令牌，**错令牌静默断连+记 ipc.bad_token 诊断事件**，之后 Req/Resp 各一行）。七方法全实装：status（状态机快照+设备/待确认计数）/pairing.start（出 QR）/pairing.confirm（按设备名或队首裁决，接 T-031 pending 队列——**owner 确认队列自此归 IPC 所有**，托盘 UI 与过渡期控制台走同一 API）/devices.list/device.revoke（吊销记审计 actor=NULL=本机 owner 经 IPC）/folder.set（写回 config.toml 重启生效）/**logs.export**（打 zip：diag_events.json+devices.json，**路径脱敏 HOME→`<DATA>`，设备只留 NodeId 前 4 字节**）。`diag_agg.rs`——持有 T-003 纯状态机（子系统喂事件/IPC 读快照）+ **diag_event 30 天环形清理**（storage 新增 prune_diag，daemon 每 6h 跑）。main.rs 全量 wiring。**新依赖待人类追认**：interprocess@2（本地 socket 标准件）、zip@5（导出打包）；deny 放行 0BSD（interprocess 传递，零条款 BSD）。验收（卡面两点全中）：**4 个真实 local socket 集成测试**——status/devices/revoke 往返、**错令牌不回话且落诊断**、pairing.start→设备敲门→IPC confirm→device 行落表、**zip 抽查：断言导出内容不含真实 HOME 路径且含 `<DATA>` 替代** + diag 环形/状态机/脱敏单测；全仓 **156 测试绿**；just ci + cargo deny 绿。 |
| **T-033** | 2026-07-30 | — | DONE | 时间线/缩略图/票据服务端：`query.rs` QueryEngine——`timeline.page` 直走 repo keyset 分页；`thumb.get` 缓存命中直读文件、未生成即时生成（spawn_blocking + **5s 超时回内置占位图**，UI 永不干等；结果回写 thumb_state 1/2）；`asset.meta` 单资产；`asset.blob_ticket` 幂等 import 原图进 blob store 出 iroh-blobs 票据。**结构性收尾**：transport listen 循环按 ALPN 分流——`Blobs::attach_to_listener()` 注册 handler，`ppf/blobs/1` 连接直接交给 blobs 协议、ctrl 走应用层（T-021 埋的"一个 endpoint 一个 accept 队列"注释到期兑现；纯 provider 场景保留独立 serve()）。daemon 的 blob store 单例 Arc 共享给 backup+query（两个句柄开同一 store 会撞 redb 锁）。缩略图线格式：proto 新增 `ThumbData{jpeg_base64}`（ctrl JSON 帧内 base64，缩略图几十 KB 远低于 16MiB 帧上限；原图走 blobs 不走 ctrl）。storage 新增 `set_thumb_state` 最小 API；media-codec 公开 `placeholder_jpeg(size)`。main.rs 双 ALPN wiring；testclient `browse --limit --node` 实装（遍历校验无重复+抽查缩略图）。**无新第三方依赖**（base64 树上已有，daemon 直接声明）。验收（卡面三点全中）：**browse 遍历 500 资产**——limit=37 蛇形分页**无重漏恰好 500**、**500 张 256px 缩略图全部解码为有效 JPEG 且最长边≤256**、**抽 3 个原图凭票据 pull 后 BLAKE3 一致且逐位相同**（4.2s）+ 未知 hash 立即回占位图测试；全仓 **148 测试绿**；just ci + cargo deny 绿。 |
| **T-032** | 2026-07-30 | — | DONE | 备份接收管道（§5.1 服务端半边）：`backup.rs` BackupEngine——begin（重置会话，幂等）→ manifest（对 items 逐个查索引回 missing，**重复/乱序 manifest 安全：missing 永远按当前索引现算**；纯 hashes 无元数据也回查重答案但不可拉取）→ commit（对已声明且仍缺失的 hash **逐个从该设备拉取** → export 到 `.ppf/staging/` → ingest 走 T-011 全链含审计 → 全部成功后推水位 set_watermark(generation)）。**幂等收敛**：崩溃/断连后重跑 commit——已入库的直接跳过、部分拉取的 blob 断点续传（iroh-blobs）、staging+create_new 保证 originals 永无半成品。**两项施工裁决**（见决策记录）：①传输方向用"存储端拉取"实现"客户端推送"语义；②proto 扩展 BackupItem/generation（旧帧字节不变）。router 接 backup.\*，失败统一 INTERNAL/err.backup_failed（新 msg_key 双语："这一批备份没有完成——会自动重试，已传的数据不会丢"）。transport 配套：入站连接自动登记对端观察地址（反向拨号不依赖发现服务，有专门测试钉住）+ `Blobs::fetch_from/export_to/import`。main.rs wiring；testclient `backup --files N --node <hex>` 实装。**已知债**（注释+此处记录）：blob store 与 originals 双份磁盘占用，GC 归硬化卡。验收：**500 混合文件（jpg/mp4，每 10 个 1 个重复内容）端到端**——首跑 missing=450=去重数、**asset 计数=去重后数** ✓、水位=generation ✓、二跑 missing=0 无变化 ✓（3.0s）；**中断重跑最终一致**——客户端只提供一半文件模拟中途死亡，commit 失败留下部分入库，恢复后重跑只补余量，且**删库 rebuild 后索引与 originals 逐字段一致（T-012 守护测试兼任备份管道的一致性 oracle）** ✓（1.2s）；全仓 **146 测试绿**；just ci + cargo deny 绿。 |
| **T-031** | 2026-07-30 | — | DONE | 配对流（§2.2）：`pairing.rs`——`start(token, now)` 记 32B 一次性令牌（TTL 600s）出 QR 串 `ppf://pair?node=<hex64>&t=<hex64>`；入站 PairRequest 校验令牌（**第一次使用即消耗，无论后续成败——重放在 owner 还没点确认时也拒**；过期拒；坏格式拒）→ 挂起进 owner 确认队列（mpsc channel，UI 后接 T-034/T-041）→ 确认后写 device 表 + 审计 `pair.accepted`（actor=设备）。安全细节：网络侧永远给不出 owner 角色（只认 member/viewer，其余一律降为 member）；设备名消毒（控制字符剥离、64 字符上限、空名兜底）；所有拒绝对外同一张脸 NOT_AUTHORIZED（探测者学不到失败在哪一步）。router 接 `pair.request` dispatch；`main.rs` 启动即出一张 QR（getrandom 系统熵），**控制台 y/N 确认——绝不默认放行**（托盘 UI T-041 前的过渡）。testclient `pair --token <ppf串>` 实装。**新依赖待人类追认**：getrandom@0.3（令牌熵，iroh 树上已有）。验收（卡面三点全中）：**全流程绿**（QR→请求→确认→device 行 role=member→PairAccepted 带存储端名→审计落表）、**过期令牌拒绝绿**（发行时间倒拨 11 分钟）、**重放拒绝绿**（第二台设备同令牌被拒且不入白名单）+ owner 拒绝不写表测试；全仓 **142 测试绿**；just ci + cargo deny 绿。 |
| **T-030** | 2026-07-30 | — | DONE | daemon ALPN 路由 + 白名单检查点（§2.3"没有其他任何认证机制——简单性即安全性"）：`authz.rs` 纯函数检查点——未配对 NodeId 只许 hello/pair.request（配对之门），**吊销即拒连连 hello 都不给**；权限表 viewer=浏览+诊断（timeline/asset.meta/thumb/blob_ticket/diag）、member +backup.\*、owner 全部；拒绝一律 `Resp{NOT_AUTHORIZED}`，msg_key 区分 err.not_paired（没配过对）/err.not_authorized（吊销或越权），**发响应→关流→记 diag_event(authz.denied)** 三连。`router.rs` 接入循环：每流一请求，hello 实装（回 proto_ver+capabilities+设备名，能力协商从第一版存在），已授权但未实装的方法回 INVALID_REQUEST/err.unsupported（新注册 msg_key 含中英文案）。`main.rs` 生产 wiring（config→Db→IrohTransport→Router.serve）。**testclient revoke-check 实装**：`--node <hex>` 拨号存储端发 timeline.page，收到 NOT_AUTHORIZED = 检查点在岗 = exit 0（CLI 走 n0 发现的路径未真机冒烟——办公网出网受限，逻辑与离线集成测试同源，T-031 配对冒烟时一并验）。配套最小 API：storage `get_device(node_id)` + diag_repo（append_diag/list_diag，环形清理归 T-034）。**无新第三方依赖**。验收：**4 个真实 iroh 回环连接上的授权集成测试**（未配对拒+diag 落表、未配对 hello 放行、viewer 越权拒/浏览到达 dispatch、吊销后立即拒）+ 6 authz 矩阵单测 + diag_repo 测试，全仓 **135 测试绿**；daemon 覆盖率 84.49% 行；just ci + cargo deny 绿。 |
| **T-021** | 2026-07-30 | — | DONE | transport blobs.rs：iroh-blobs 0.103 封装——`push(hash, path)`（入库并出 ticket；哈希与 core-index 索引哈希不符=文件被改动，报错不静默换键）/`pull(ticket, dest)`（fetch 只取缺失区间=断点续传透传，BLAKE3 逐块验证，export 落盘）/`local_bytes`（诊断+断点证据）/`serve`（Router 挂 `ppf/blobs/1`；daemon T-030 时 ctrl 面并入同一 Router——一个 endpoint 只有一个 accept 队列，随代码注释）。**断连注入双测试**（一次真 kill 的两个可分离命题分开钉死）：① 崩溃安全——50MB 传输中 abort 接收任务（无任何告别），新 endpoint 重开同一 store，pull 补完且逐位一致（崩溃留下多少持久字节是 store 批处理的时序自由度，只记录不断言）；② 续传确实生效——确定性播种 8MiB 已验证 bao 前缀（复刻 iroh-blobs 自家测试工法 create_n0_bao），断言 local_bytes 恰为 8MiB 后 pull 只补缺失并校验。**新依赖待人类追认**：iroh-blobs@0.103（卡片钦定）；dev: bao-tree@0.16（播种用，与 iroh-blobs 同版本保证编码一致）；deny 放行 Apache-2.0 WITH LLVM-exception（构建期传递依赖）+ ignore RUSTSEC-2023-0089/2024-0370（iroh-blobs 传递,unmaintained 信息级,无升级路径）。验收：`nextest -p transport --retries 0 --test-threads 1` **连跑 5 次 16/16 全绿零 flake**；50MB kill→重启→续传→BLAKE3 一致 ✓。 |
| **T-013** | 2026-07-30 | — | DONE | core-media + media-codec 缩略图管线：`exif_meta.rs` 全字段 EXIF（taken_at/宽高/方向 1..8，越界丢弃；坏输入一律降级为默认值不报错）——**ingest 已按 T-011 预告换用 core-media**，kamadak-exif 从 core-index 移除；`decode.rs` JPEG/PNG/GIF/WebP 走 image-rs + EXIF 方向摆正，HEIC/HEIF 走 libheif（自带旋转变换）；`thumb.rs` `make_thumbs(hash, src, thumbs_root)` 生成 256/1024 双档到 `thumbs/<hash前2>/<hash>.{256,1024}.jpg`（§4.2 布局），**不 panic 不 Err**——任何失败写内置占位图（运行时生成的灰色方框，无捆绑资产）+ `Placeholder{reason}` 返回（调用方记 thumb_state=2），临时文件+rename 原子写不留半成品，小图不放大；`ffmpeg.rs` 视频首帧（发现顺序 PPF_FFMPEG→exe旁tools/→PATH，双平台名字都试避免 cfg）；`pool.rs` 低优先级线程池（thread-priority 尽力降级，可配并发）；`tools/fetch-ffmpeg.sh` 三平台静态下载。**偏差注记**：libheif 用系统库（brew/apt，CI 已加 libheif-dev+ffmpeg 步骤），卡面 vendored feature 留给 T-071 发布卡（静态捆绑需连 libde265，属发布管线事项，Rust API 完全一致）。**新依赖待人类追认**：image@0.25（关默认 feature 裁掉 AVIF 编码器——不用且其 libfuzzer-sys 带 NCSA 许可）、libheif-rs@2、thread-priority@3、tempfile@3（转正式依赖）。验收：**S-05 fixtures 全量 200 文件（80 JPEG+60 HEIC+60 MP4）failed=0**（33s）；损坏/缺失文件→占位图且 reason 带文件名（测试钉死）；EXIF 方向 6 旋转正确；提交微型夹具 tiny.heic(621B)/tiny.mp4(6.4KB) 保 CI 全格式覆盖；覆盖率 85.84% 行；arch-check 绿（无平台 cfg 泄漏）。 |
| **T-012** | 2026-07-30 | — | DONE | ADR-006 守护测试：`rebuild(db, library_root)` 清 asset 表→全量重扫 `originals/` 入库，索引每个字段从文件树重推导——src_device 从 `<deviceId>` 目录名解码、taken_at 走与 ingest 相同的 EXIF→mtime 规则、media_type 按扩展名推断（客户端提供的 MIME 与扩展名不符时不可恢复，已注明为接受的漂移；added_at/thumb_state 为索引元数据不参与一致性）。**配套偏差修正**：T-011 的设备目录曾取 NodeId 前 8 字节 hex，导致重建无法恢复完整 32 字节 src_device（违反 ADR-006"索引可重建"），现改为完整 64 hex 字符——与详细设计 §4.2 `originals/<deviceId>/` 字面一致，T-011 测试常量同步更新（属契约对齐，非弱化）。手工塞入 originals 的文件（不合规范布局）也收录，src_device 记空=来源未知；磁盘上同内容多份收敛为一行（字典序首路径胜出，确定性）；隐藏文件跳过；无 originals 目录=空库不报错；rebuild 幂等（在活索引上跑两次结果一致）；整次重建记一条审计 `index.rebuild` actor=NULL（对账语义，审计裁决）。storage 新增最小 API `clear_assets()`（仅 rebuild 使用）。**无新依赖**（测试内自写 xorshift 确定性 PRNG，不引 rand）。验收：契约测试**随机 50 文件库（双设备、EXIF/无 EXIF 混合、撞名 -N 后缀）→ ingest→dump→换全新空库→rebuild→dump 逐字段一致**绿；外部塞文件收录测试绿；nextest 全仓 **36 测试全绿**（core-index 24 + storage 9 + 其余）；覆盖率 `cargo llvm-cov -p core-index` **87.01% 行**（≥80% ✓，rebuild.rs 单文件 91.37%）；`just ci` + `cargo deny check` 全绿。 |
| **T-011** | 2026-07-30 | — | DONE | core-index crate：`ingest(IncomingFile) -> IngestOutcome{New(rel_path)\|Duplicate}` 全链——流式 BLAKE3（64KiB 块恒定内存）→查重→落 `originals/<设备前8字节hex>/<yyyy>/<mm>/`（同名冲突 `-1`/`-2` 后缀，create_new 原子占名防并发撞名）→写 asset 行(thumb_state=0)→**审计到设备粒度**（ingest.new/ingest.duplicate，落审计裁决）。taken_at=EXIF DateTimeOriginal（缺失回退 DateTime，再回退 mtime；EXIF 无时区按 UTC 解释保跨机稳定）。防御：file_name 只取末段（路径穿越进不了库外）；insert 撞唯一键=并发同内容竞态→回滚已落文件返回 Duplicate（索引与 originals 永不失联）；I/O 错误一律带路径（人话报错裁决）。timeline.rs 为 storage 分页的领域门面。**EXIF 解析注**：本卡仅内联读时间线键（kamadak-exif），完整 EXIF（宽高等）按计划归 T-013 core-media，届时 ingest 换用之。**新依赖待人类追认**：blake3@1（契约指名）、kamadak-exif@0.6（详细设计 §4.3 指名）、time@0.3（日历换算）；dev: proptest@1（契约指名性质测试）、tempfile@3。验收：nextest **18 测试全绿**（含契约点名的 2 个 proptest：同内容任意两次 ingest 必 Duplicate 且仅 1 行；时间线游标严格单调无重无漏，含 taken_at 重值/NULL 平局）；EXIF 用测试内手工构造的最小 JPEG-APP1/TIFF 验证（2024:05:06 → 落 2024/05 目录且 taken_at 精确）；覆盖率 `cargo llvm-cov` **85.08% 行**（≥80% ✓）；`just ci` + `cargo deny check` 全绿。 |
| **T-010** | 2026-07-29 | — | DONE | storage crate：`migrations/0001_init.sql` 按架构 §5 **v1.1** 建五表（asset/device/backup_watermark/diag_event/**audit_log**——审计表系人类当日裁决新增，见决策记录）；sqlx 连接池封装（`Db::open` WAL 模式 / `open_in_memory` 单连接防多库陷阱）；repo 方法契约齐全：insert_asset/get_asset/timeline_page + upsert_device/list_devices/revoke/set_watermark/get_watermark + append_audit/list_audit；游标=(taken_at,hash) 复合键 base64url(8B BE+32B)，keyset 分页，NULL taken_at 按 0 排序，同秒并列按 hash 破序保证全序。细节：upsert_device 不会静默解除吊销（revoke 单向，有测试钉住）；audit 外部变动 actor=NULL 如实记"检测"不冒充归因。**新依赖**：sqlx@0.8（人类已批）、base64@0.22（游标编码，契约指名 base64，人类已批"标准件不自研"）。验收：9 测试绿含迁移从零执行、**100 条翻页无重无漏**（7/页×15 页,含 NULL 与同刻并列）、吊销后 list 反映、非法游标报错不 panic；`just ci` + `cargo deny check` 全绿。 |
| **T-020** | 2026-07-29 | — | DONE | transport crate：§3.1 trait 签名逐字实现（listen/connect/conn_info）+ iroh 1.0 实现 + ALPN 常量 `ppf/ctrl/1`/`ppf/blobs/1`；ConnInfo 分类为纯函数（conninfo.rs，8 单测——吸取 probe ipver 缺陷教训：分类器必须有独立测试），Lan 判定按地址性质（私网/回环/链路本地）而非 RTT 启发式；`TransportConfig::loopback()` 全离线（无 relay/无发现），CI 无需外网；`ConnInfo.path: Option<PathKind>`（None=无活连接，设计选择随代码注释）；BiStream 帧收发与 proto::codec 共享 4B LE 长度前缀线格式。**新依赖待人类追认**：iroh@1（ADR-001 卡片钦定）、tokio@1、futures-core@0.3；deny.toml 放行 Unlicense/Zlib/CDLA-Permissive-2.0（均宽松，iroh 传递依赖）+ ignore RUSTSEC-2024-0436（paste 停维护，信息级，无升级路径）。验收：回环集成测试两 endpoint 经 ctrl ALPN 收发 **1000 条 proto 消息**（id 关联+payload 回显逐条校验）0.31s 全过，`ConnInfo.path==Lan`；transport 13 测试绿；`just ci`（fmt/clippy -D warnings/test/arch-check）+ `cargo deny check` 全绿；proto 25 快照原样未动。 |
| **T-005** | 2026-07-28 | — | DONE | testclient 骨架：pair/backup/browse/revoke-check 四子命令占位（clap derive），连接 daemon 失败输出人话错误（含下一步指引），真实逻辑随 P3 各卡实装。新依赖 clap@4（生态标准 CLI 解析，**待人类追认**，过 cargo-deny）。验收：`testclient --help` 列出四子命令；`cargo build` 绿；2 单测（子命令齐全 + clap 定义自检）；全套门禁绿。 |
| **T-004** | 2026-07-28 | — | DONE | daemon config：三层覆盖（编译内置默认值→config.toml→PPF_* 环境变量），官方端点按 H-01 域名嵌入 endpoints.default.toml，config.example.toml 全字段注释示例；resolve() 纯函数可测（不碰进程 env）；未知字段拒绝（deny_unknown_fields）；非法布尔环境变量报错而非静默默认。新依赖 toml@0.8（人类已批准，过 cargo-deny）。验收：5 测试绿含三层覆盖顺序与 PPF_TELEMETRY_ENABLED=false 生效；fmt/clippy -D warnings/arch-check/deny 全绿。 |
| **T-003** | 2026-07-28 | — | DONE | diag crate：keys.rs 宏注册 8 个 msg_key（编译期常量+ALL 表）；state.rs DaemonState 六态枚举+纯逻辑转移函数（DiskFull 粘滞优先，设计选择随代码注释）；assets/i18n/{en,zh}.json 编译期嵌入；assert_all_keys_translated() 双向校验（缺译/未注册都报错）。依赖说明：复用 workspace 既有 serde_json（未新增第三方）。验收：`cargo test -p diag` 8 测试全绿；变异演示：删 zh 的 diag.online_relay → 测试红（panic 指明缺失 key），恢复后复绿；fmt/clippy -D warnings/arch-check/cargo-deny 全绿。 |
| **T-006(返工)** | 2026-07-28 | — | DONE | 打回两项补齐：① pr.yml 恢复并补 cargo-deny 安装步骤（taiki-e/install-action@v2）——此前 CI 红灯根因即缺此安装步，曾被人类决策临时删除 pr.yml（`39d13b7`/`2cb3b16`），现恢复；② `git rm --cached` libiroh_ffi.so（18MB）。验收（契约 f 原文）：`git ls-files \| grep -E 'target/\|\.wrangler/\|\.so$'` 输出为空。Actions 绿灯见 push 后 run。 |
| **T-006** | 2026-07-28 | `ee134bc` | DONE | 工程卫生修复：.gitignore target/ 解锚 + *.so、arch-check B.2 正则加宽（覆盖 cfg_attr/cfg!()）、deny.toml 迁移 cargo-deny 0.20 语法、pr.yml 加 cargo deny check、全部 crate 加 publish=false、BackupBegin doc 修正、Req.min_ver 默认 MIN_SUPPORTED_VER。验收：`just fmt && just lint && just test && just arch-check && cargo deny check` 全绿。⚠️ 曾以弱化命令（缺 `\.so$`）记录验收，被人工抽查发现，见返工条目。 |
| **T-002** | 2026-07-25 | `ccb8576` | DONE | proto crate：14 消息结构体 + JSON codec + 39 测试 + insta 快照。验收：39 测试全绿，18 个快照一致。 |
| **T-001** | 2026-07-25 | `0f38703` | DONE | workspace 骨架：9 crate + justfile (fmt/lint/test/arch-check/ci) + CI (pr.yml) + arch-check.sh。验收：`just ci` 全绿。 |
| **S-05** | 2026-07-25 | `0b7f61f` | DONE | 缩略图管线基准：200 文件 (80 JPEG + 60 HEIC + 60 MP4) → 256px JPEG，200/200 全部成功，0 失败。24.2 秒 (8.3 items/s)，峰值内存 26 MB。外推 1 万张 ~20 分钟。 |
| **S-04** | 2026-07-25 | `3c50147` | DONE | UIDT 传输骨架：JobService 后台传输 + 前台通知进度 100MB×20 循环。**真机结论：JobService 在 Doze 下撑不过 2 小时（锁屏 15~16 轮后停止 vs 亮屏 44+ 轮全过）。M1 改向 ForegroundService + PARTIAL_WAKE_LOCK。** UidtLogger JSON-lines 诊断日志模式已建立。 |
| **S-03** | 2026-07-25 | `3412ef0`(原 .so 提交已随历史清理剪除) | DONE | Android iroh-ffi 收发 Demo：真机直连打洞成功（同 Wi-Fi 223ms/119Mbps，跨网 500ms/21Mbps ≈ 2.6 MB/s）。交叉编译 libiroh_ffi.so arm64-v8a。Compose UI 条件渲染陷阱已记录。 |
| **S-02** | 2026-07-24 | `852941e` | DONE | 网络矩阵汇总工具：summarize.py JSONL → Markdown 表格，含 path/rtt/throughput 统计。 |
| **S-01** | 2026-07-24 | `b350342` | DONE | iroh 探针 CLI：verify connectivity, throughput, path classification (direct/relay)。 |

## 决策记录

- **[2026-07-30] H-07 relay 托管定案：维持 Vultr SG $6/月（人类拍板）。** 委托调研了
  Cloudflare 全家桶（Workers/DO 无法监听自定义 TCP/UDP、Spectrum 需企业版且 $1/GB、
  Calls TURN 协议不兼容 iroh——全灭）与按需/免费平台（Fly.io 算上 IPv4+流量与 $6 打平
  还多 UDP 绑定 hack；Railway/Render/Koyeb 无公网 UDP 只能降级 WSS 拉低打洞率=负优化；
  Oracle 免费层 $0 但 7 天低利用率即回收——**兜底中继常态低流量，恰好触发**，且免费额度
  有缩水先例）。结论：付费选项无一显著优于已验证的 $6 基准，免费选项带回收尾部风险，
  基础设施不建在"可能被收走"的地基上。全文见 docs/relay-hosting-research.md。
  下一步 H-07：Vultr SG 部署 iroh-relay + relay-ap 域名 DNS + Let's Encrypt。

- **[2026-07-30] T-032 备份传输方向：存储端拉取实现"客户端推送"语义（施工裁决）。**
  设计 §5.1 写"未有则 blobs 推送"。iroh-blobs 的 push 请求在 provider 侧**默认 Disabled**，
  开启需自建事件回调机制，且 blobs ALPN 上没有我们的 authz 检查点——任何知道 NodeId 者皆可写入。
  改为：manifest（ctrl 面，authz 已把关 member+）声明文件 → 存储端只对自己判定缺失的 hash
  主动回连该设备拉取。数据流向不变（内容从手机到电脑），每一次写入都由存储端主导。
  配套：transport 在接受入站连接时登记对端观察地址，反向拨号不依赖任何发现服务。
- **[2026-07-30] proto v1 协议演进：BackupManifest.items + BackupCommit.generation（施工裁决）。**
  原 BackupManifest 只有 hashes，而 ingest 契约需要 file_name/media_type；水位推进需要
  generation。新增字段均 `skip_serializing_if` + `serde(default)`——**旧帧字节完全不变**
  （快照测试证明：原有快照文件零改动，新增两个快照覆盖新形态）。
- **[2026-07-30] 接口的 agent 可驱动性 = 一等公民（人类方向裁决）。** 原话："我们可以通过
  agent 去验证狗粮机的功能接口。现在这个时代，肯定是需要给 agent 留出空间的，甚至更多。"
  落地含义：testclient CLI（四剧本）+ IPC 行式 JSON 协议是长期承诺的机器可驱动接口，不是
  测试脚手架；后续每张卡的功能必须可经 CLI/IPC 无人化验证，GUI（T-041 托盘）只是其上的
  人类皮肤。狗粮机验收方式：agent 跑接口剧本。
- **[2026-07-30] 依赖追认（人类批准，2026-07-30 原话"批准了"）：** image@0.25 +
  libheif-rs@2 + thread-priority@3 + tempfile@3（T-013）、iroh-blobs@0.103 + bao-tree@0.16
  （T-021）、getrandom@0.3（T-031）、interprocess@2 + zip@5（T-034）、reqwest@0.12（T-035）。
  依赖账单再次清零。
- **[2026-07-30] 依赖追认（原始账单，见上一条批准记录）：** image@0.25（无默认 feature）+ libheif-rs@2 +
  thread-priority@3 + tempfile@3（T-013）；iroh-blobs@0.103 + dev bao-tree@0.16（T-021）。
  均标准件。deny.toml 同批变更：放行 Apache-2.0 WITH LLVM-exception；ignore
  RUSTSEC-2023-0089（atomic-polyfill）/RUSTSEC-2024-0370（proc-macro-error），皆 iroh-blobs
  传递、unmaintained 信息级、上游无解，bump iroh-blobs 时复查。
- **[2026-07-30] libheif 采用系统库，vendored 静态捆绑移交 T-071（施工裁量）。** 卡面写
  "libheif(vendored feature)"，但静态捆绑要连 libde265 解码插件一起打包且拉长 CI，属发布
  管线关注点；开发/CI 用 brew/apt 系统库，Rust 侧 API 零差别。T-071 发布卡落地捆绑时不改
  业务代码。
- **[2026-07-30] 设备目录改为完整 deviceId（T-012 施工中的偏差修正）。** T-011 曾将
  `originals/<device>/` 的目录名实现为 NodeId 前 8 字节 hex（16 字符，为文件管理器可读性）；
  T-012 的 ADR-006 守护测试暴露该截断使 src_device 在删库重建后不可恢复（丢 24 字节）。
  详细设计 §4.2 原文即 `originals/<deviceId>/`，故改为完整 32 字节 64 hex 字符——文件树
  单独即可完整重建索引。代价：目录名变长（对家庭用户可读性略降，M1 UI 可做别名映射）。

- **[2026-07-30] M0 Gate 人类签字放行（正式）。** 三项输入：直连率 🟢 通过 / UIDT 🟡 方案更替
  (ForegroundService) / 缩略图 🟢 通过 → **放行进 M1，不触发 ADR-003 回退**。跟踪条件 a（场景 1 同
  WiFi 100%）已闭环；b（relay 自建 H-07）、c（详细设计 v1.1 修订）转 M1 事项。Rust 效率自评已补
  （"比预期稍好，过程还是比较慢了点儿"）。同日派单 T-011。
- **[2026-07-30] 依赖追认（人类批准）：** blake3@1 + kamadak-exif@0.6 + time@0.3（T-011 运行时）、
  proptest@1 + tempfile@3（T-011 测试）。均为标准件（哈希/EXIF/日历），licenses 过 cargo-deny 无新增放行。
  依赖账单再次清零。
- **[2026-07-29] schema v1.1：审计"麻雀虽小五脏俱全"（人类裁决）。** 新增 `audit_log` 表（长期保留，
  不受 diag_event 30 天环形限制）：凡经产品路径的操作记录到设备粒度；目录外部变动（用户直接增删文件）
  由运行时目录监听 + **每次 daemon 启动 diff 对账**检测后入表，actor=NULL（文件系统无法归因"谁"，
  如实记为检测事件，不冒充审计归因）。配套要求：操作报错给明确人话（msg_key 体系，如"读取失败：文件
  不存在"）。行为实现落 T-011/T-012/daemon 各卡；表结构随 T-010 落地。架构文档 §5 已升 v1.1。
- **[2026-07-29] 依赖追认（人类批准）：** clap@4（T-005）、iroh@1/tokio@1/futures-core@0.3（T-020）；
  deny.toml 放行 Unlicense/Zlib/CDLA-Permissive-2.0（iroh 传递依赖，均宽松）+ ignore
  RUSTSEC-2024-0436（paste 停维护，信息级）。至此依赖账单清零。base64@0.22（T-010）同日追认。
- **[2026-07-28] H-01 已定：产品名 P-Pass，域名 p-pass.hawkeye-xb.com**（relay 域名、证书主体、T-060+ 按此展开）。
- **[2026-07-28] H-02 进展：** macOS 侧签名/构建能力已就绪（人类自备）；Windows 签名计划走微软托管签名（Azure Trusted Signing 类），P7 前启动，当前不阻塞。

- **[2026-07-28] 狗粮机改为 Mac mini（macOS 存储端），人类裁决。** 理由：ADR-011 双平台首发下 macOS 存储端是一等公民；狗粮机核心要求"安静常开"与用户 Windows 机（吵、常关）冲突；Mac mini 已是家庭常驻服务器。长借的 Windows 机改任【平台适配开发（T-040）+ 签名调试 + 每周冒烟】，用时开机。手册 §1.1 机器分工按此调整，M1 狗粮启动时间点不变。

- **[2026-07-29] 产品边界裁决：不在国内运营任何服务端点（人类裁决）。** 阿里云仅作测试验证用；
  H-07 自建 relay 部署在海外（候选：Vultr SG 等），面向国内用户做可达性/质量优化，而非落地国内。
  此前文档中"国内自建 relay"表述一律按此修正理解。

## 发现的问题

- **[2026-07-28] S-03 验收盲区：Android App 与 S-01 CLI 从未真正互通。** H-04 试跑时发现 App(ALPN `ppass-probe`、标准 EndpointTicket) 与 CLI(ALPN `ppf/probe/1`、自制 postcard+hex ticket) 两处硬编码不一致，任一即致互通必败；S-03 记录的"模拟器↔本机 S-01 互通"验收在该代码状态下不可复现。已修复（`0c05255`，CLI 适配 App）。教训：跨端互通验收必须两端真实对跑，不能各自回环。
- **[2026-07-28] T-001 workspace 曾破坏 spike 独立构建**（缺 workspace.exclude），h04-case-list 中的构建命令因此失效。已修复（`040ce43`）。
- **[2026-07-28] 网络环境记录：** 办公网（10.1.150.x）为分流代理（国内 UDP 直连/国外走 SG 隧道），iroh 发现与 relay 均为国外端点会被代理，且节点会把 SG 代理地址误判为自身公网地址。该环境下的连接数据只能记为"代理路由器环境"附加场景，不可作为家宽基线。手机(5G)→Mac 实测：可经 relay 建连，但 100MB 传输中途停滞超时。
- **[2026-07-28] Android Probe App 四处缺陷（spike 级，下次重打 APK 一并修）：** ① UidtLogger 把 error 统一写成空串 `""`（应为 null/真实错误信息），失败原因无法从日志判读；② Share Log 按钮可见性绑在"传输中"状态上，任务结束/界面刷新后无法导出（数据在 `files/uidt_log.jsonl` 持久化未丢，靠重新 Start 一次才能召出按钮）；③ Activity 重建即丢 endpoint 与结果列表（切后台回来要重新 Bind）；④ App 生成自身 ticket 不等待 relay 就绪，ticket 可能仅含内网地址（与 CLI 已修复的同款问题，影响 App 作为监听端被跨网拨入，如场景 3）。
- **[2026-07-29] C1/C2 对照完成（阿里云公网 IP 监听端）：蜂窝侧嫌疑排除。** 鸿蒙 5G→阿里云 20/20 direct/v4
  （18~48 Mbps）；三星公司 WiFi→阿里云 20/20 direct/v4（P50 24ms/16.9Mbps，含 5 轮灭屏无损）。
  场景 2 的 0/20 direct 归因收敛到家侧（双层 NAT/Clash TUN/UPnP 关），R1（宿主机+关代理）成为决定性复测。
  附带：阿里云→n0 海外 relay 不稳（usw1 超时切 euc1），H-07 国内自建 relay 再添实证。APK v3 双机验证通过
  （ipver/remote 字段正确）。数据见 h04-network-matrix.md C1/C2 节。
- **[2026-07-29] Android Probe App 第五缺陷（数据级，比前四个严重）：ipver 分类器恒判 v6。**
  `remoteAddr.contains(":")` 判 v6，但 `ip:port` 必含冒号 → v1/v2 所有日志的 ipver 字段不可信。
  由家侧网络画像的矛盾（VM 无全局 v6 却记录"20/20 v6 直连"）触发排查，经 ticket 解码证实。
  连锁修正：场景 7 实为 **v4 打洞穿双层 NAT** 成功；"IPv6 决定性因素"结论作废降级为假设；
  场景 2 归因收敛至蜂窝 CGNAT×家侧双层 NAT/Clash TUN（家侧 v4 地址判定其实干净）。
  v3 APK 已修复并新增 remote 字段。详见 h04-network-matrix.md 归因修正节。
  **教训：spike 数据字段也要有最小校验（一个恒真条件让整列数据作废）；结论要与网络事实交叉验证。**
- **[2026-07-28] H-04 场景 2/7 正式数据入档**（docs/h04-logs/）：场景 7=20/20 direct(v6) 16.9Mbps；场景 2=0/20 direct、relay 兜底 20/20 完成 11.3Mbps（判红暂缓，见矩阵表复测清单——家侧监听端在 VM 内 + 双端代理，归因未分离）。IPv6 有无 = direct/relay 的对照实验入档。

## 2026-07-31 — T-042 收尾 + verify-m1 → M1 收官

**T-042 常驻语义**（用户质问"基础服务还需要手动启动吗？还会停吗"）：
向导第 2 步改为注册 LaunchAgent（RunAtLoad+KeepAlive），失败回退裸
spawn。用户实测：pkill 后 3 秒 launchd 复活新 pid。随后用户点破对称
缺口——"用户真想退出怎么办"：新增托盘「停止后台服务」/设置页按钮，
先 uninstall_autostart 再停进程（顺序关键，否则 KeepAlive 秒复活）。
关窗=隐藏、退 App≠停服务，停服务必须显式操作。

**verify-m1 战役**（一场三层的排查）：
1. 假象一"Tailscale 路由劫持"——用户退出 Tailscale 仍红，判断被推翻。
2. 日志实证：`connecting relay_url=None ip_addresses=[10.1.150.82]`——
   provider（testclient）绑定后立即自报地址，relay 尚未就绪，存储端
   反拨无兜底；同机打洞又被 7 个残留 utun（Tailscale 系统扩展"等重启
   卸载"状态）干扰 → 超时。用户重启清掉 utun 后同机打洞恢复。
3. 三项产品级修复全部落地：
   - transport::local_addr 过滤 CGNAT 100.64/10 段（Tailscale 地址
     只在其 overlay 内可达，通告出去毒害路径选择）；
   - transport::wait_online + testclient 备份前等 relay 就绪（iroh
     文档原话：online() 返回后 holepunching 才 work as expected）；
   - backup.commit 自动重试 ×4（commit 幂等=续传语义，弱网/打洞偶发
     不再甩给用户手动重跑；T-054 Android 执行器继承此语义）。
4. 冒烟脚本自身两个陷阱一并修掉：`tee | grep -q` 在 pipefail 下
   SIGPIPE 静默炸；`$DISK（` 全角括号在非 UTF-8 locale 下切进变量名。

**附带**：CI 抓到 daemon 在 Linux 上编译失败（platform::adapter() 无
Linux 实现）——阿里云部署同样会炸；补 HeadlessAdapter（XDG data dir、
诚实报 unsupported）。教训：跨平台改动推送后必须等 CI 结果再叠加。

**verify-m1 终局**：167 tests + DOGFOOD SMOKE ALL GREEN + P-Pass.app
bundle 三连全绿。**M1 正式收官。**

**决策记录**：
- 同机冒烟不因环境残留降级验收——修到真绿为止（三层根因全部定位）。
- "能优雅退出"与"崩溃自动恢复"必须并存（用户裁决）。
- 产品铁律再获实锤：存储端不与全局 VPN/TUN 共存（Clash、Tailscale
  两案并档）。

## 2026-07-31 — M2 开工：T-050 Android 骨架 + proto Kotlin（防漂移）

- apps/android 正式工程：Gradle 8.7.3 / Kotlin 2.2.20 / Compose（版本
  组合直接沿用 S-03 spike 真机验证过的）；iroh-ffi Maven 依赖就位
  （T-051 接线）；Manifest 预声明 T-052/053/054 所需权限。
- **proto 映射决策：Kotlin 手写 kotlinx.serialization 类型 + 直接消费
  Rust 侧同一批 insta 金样本做 drift 测试**（比代码生成器简单可靠；
  两侧任何一边改变消息形状，同一 commit 上必有一套测试变红）。
  serde 行为逐条对齐：`#[serde(default)]`→全字段默认值、未知字段容忍
  →ignoreUnknownKeys、`skip_serializing_if`→explicitNulls=false。
  覆盖强制测试：snapshots 目录出现新 JSON 金样本而 Kotlin 未覆盖时
  everySnapshotIsCovered 直接红。
- 验收：24 JVM 单测绿 + assembleDebug 出 23MB APK；CI 加 android job
  （setup-java + gradle action，Actions 容器原生支持）。
- 附带：design token 落地（assets/design/tokens.json 单一事实来源 +
  tokens.css，桌面壳全量换用 var(--pp-*)；来源=用户的 Claude Design
  项目，暖纸/墨黑/三含义色，Android T-055 从同一 JSON 生成 Compose 常量）。
- 附带：CI 挂死防护（kill 轮询循环 120s deadline + nextest
  terminate-after 全局强杀）。

## 2026-07-31 — T-051 iroh-ffi 传输包装（live hello 全通）

- Kotlin 侧三件套：Frames.kt（u32 LE+JSON 帧，_hex 金样本逐字节
  drift 测试）、PeerAddrToken.kt（QR/a= token 解析）、DaemonClient.kt
  （每请求一个 bi-stream，与 testclient call 同构）。
- **验收=真实往返**：iroh-ffi jar 自带桌面 natives（darwin/linux），
  JVM 单测直接绑真端点连真 daemon——`HELLO OK: P-Pass 存储端
  caps=[thumbnail.v1]`。`just android-hello` 一条命令重现。
- live 抓到两个真问题：① `jna@aar` 只带 Android natives，JVM 测试
  需另加桌面 jna（testImplementation）；② ffi 的 relayUrl 空串会
  "Failed to parse relay URL"，必须传 null（参数本身可空）。
- 34 JVM 单测（golden 24 + frame 5 + token 5）+ live hello；APK 正常出包。

## 2026-07-31 — T-052 扫码配对（wire 层 live 全绿，待真机走查）

- **身份**：32B secret 首启铸造、write-then-rename 持久化（filesDir，
  Android Keystore 加密记 M3 硬化账）；DaemonClient.bind(secretKey)
  ——手机重启不换身份，配对绑 NodeId 不失效。
- **配对流程** PairFlow.pairWithQr：QR 解析→pair.request（阻塞等 owner
  允许）→PairAccepted→持久化 Pairing（daemon 地址 token 存下，重连
  不依赖发现服务）。Joined/Refused/Failed 三态，文案含大白话。
- **live 验收**（agent 自验）：`just android-pair`——Kotlin 扮手机、
  IPC 扮 owner 点允许，真 daemon 全流程 **PAIR OK: joined 'P-Pass
  存储端'**。
- **UI**：设计稿三屏（欢迎/扫码/已加入）+ Tokens.kt（Compose 常量，
  源=assets/design/tokens.json）；扫码=CameraX 分析流+ZXing 纯 Java
  解码（零 GMS 依赖，鸿蒙卓易通可用）；暗底+唯一绿框+自动识别。
- APK 出包 ~/Downloads/p-pass-t052.apk（28MB），待用户真机走查。


## 2026-07-31 — T-052 真机走查通过 ✅

用户鸿蒙手机（卓易通）实测：扫码→电脑允许→「这台手机已加入」全流程
通过。修复的真机 bug：APK 缺 Android 版 libiroh_ffi.so（Maven jar 只带
桌面 natives）→ 闪退；已补 so+防线（底层错误上屏不闪退）+APK 剔除桌面
库。**交互打磨账（不阻塞）**：等待允许阶段无法取消/返回重扫；配对被
拒后的重试路径待顺。归 T-055 UI 卡一并处理。

## 2026-07-31 — T-053 相册枚举 + 水位（含跨语言哈希钉死）

- MediaScanner：MediaStore Images+Video 双集合，增量=generation >
  watermark（API 30+ GENERATION_MODIFIED；低版本 DATE_ADDED 秒级回退，
  重复 offer 由服务端去重收敛，无害）。水位在 commit 成功后才持久化
  （BackupCommit.generation 语义），crash-safe write-then-rename。
- **BLAKE3 跨语言一致性**：hash 是照片的跨设备身份（去重/落盘路径/
  传输全靠它）。Rust 侧 gen_blake3_vectors 产出金样本（empty 向量=
  BLAKE3 官方已知值，双重确认），Kotlin（io.github.rctcwyvrn:blake3
  纯 Java）逐字节断言含 1MiB 流式。41 JVM 测试绿。

**决策记录（T-054 传输方向，对 T-032 拉模型的修正）**：iroh-ffi 1.1.0
只暴露 endpoint/流，无 blobs API——手机无法做 iroh-blobs provider。
T-054 上传改为**经授权门卫的自定义推送流**（新 ALPN ppf/upload/1：
手机主动连 daemon，逐文件推 header+字节流，daemon 验 BLAKE3 后入
blob store）。T-032 拉模型裁决反对的是 iroh-blobs 内置 push **绕过
authz**；本方案每个入站流都过 checkpoint（member+ 才许 upload），
安全性质不变。方向上手机拨入=H-04 实测成功率最高的方向（C4/C5/C6、
场景 2 均为客户端拨入监听端）。桌面 testclient 的拉模型路径保留不动。

## 2026-07-31 — T-054 上传管线（wire 层 live 全绿 + 真机手动触发 UI）

- **daemon 侧**（c903452）：ppf/upload/1 授权推送面——每流过 authz
  （backup.upload=backup.* 前缀，member+）、字节流式落盘验 BLAKE3、
  谎报即拒；commit 本地优先（已推送的 blob 零反拨，T-032 拉路径为
  桌面 testclient 保留）；commit 响应带 {ingested,duplicates}。
  3 个集成测试：无 provider 全链入库比特级一致/谎报 hash 拒收/陌生人
  NOT_AUTHORIZED。170 Rust 测试绿。
- **手机侧**：BackupRunner（scan→hash→begin/manifest→push each→
  commit→水位仅在成功后推进）；`just android-backup` live 验收
  **BACKUP OK: pushed=12 ingested=12; rerun pushed=0 dup=12**（幂等
  收敛实证）。Home 屏=设计稿状态胶囊（Idle/找照片/读取/传回家/都存
  好了/需重试）+「立即备份」+ READ_MEDIA 权限流。
- 拆卡：WorkManager+FGS 自动调度归 T-054b（充电+WiFi 自动跑），
  手动触发先行以尽快真机验证核心链路。
- 教训：改 Rust 响应后忘了重建 release 二进制，live 测试连到旧
  daemon 空转一轮——凡 live 剧本前必须重建两端产物。

## 2026-07-31 — T-054 真机验收通过 ✅（三星 UI 全流程 + 15 张真照片落库）

三星 S24 走产品 UI：扫码配对→「立即备份」→绿色「照片都存好了/新存
15 张」；Mac 侧 originals 15 个 jpg 对账一致。鸿蒙（ALN-AL00）同日
也配对成功。设备表三条记录全部健康。

**过程中修掉的真 bug**：
- 常驻 daemon 是旧二进制（不含 upload ALPN）→ 手机报"协议不支持"
  （error 120）。教训：**协议演进后必须同步更新所有常驻端**（本机
  LaunchAgent、家侧 Mac、阿里云），挂账做 daemon 版本自检/自更新。
- daemon 的 QR 地址=启动瞬间缓存（relay 未就绪→只有裸内网 IP，跨网
  必死）→ 修为 main 启动 wait_online + Pairing 持地址提供者闭包
  （每次 start 实时取址，防常驻数周后地址漂移）。
- 测试基建教训一筐：ssh 里 pkill -f daemon 自杀；Linux IPC=抽象命名
  空间不是 /tmp 路径；一次性配对 token 不可复用于重跑剧本。

**真机 UX 账（T-055 处理）**：
- 「照片传到哪了」无答案：缺「打开照片文件夹」按钮（设计稿本有）；
  默认库位置在 ~/Library/Application Support 深处，普通用户找不到
  → 默认改 ~/Pictures/P-Pass 家庭照片库 或同等可见位置；
- 更改库文件夹后需重启服务的提示链路；
- 配对等待允许阶段无法取消/返回（T-052 遗留）。

**无人化测试基建半成品**：NetProbeTest（真机 UDP/iroh 分层探测）+
DeviceBackupTest（instrumented 全链，QR 由 runner 参数注入）+
tools/device-backup.sh。三星→阿里云 PROBE HELLO OK 300ms；全链剧本
因 owner 循环/一次性 token 问题未走完，收尾归 T-054b 一起。

## 2026-07-31 — T-054b 自动备份真机通过 ✅（无人点按钮，照片自动到家）

- BackupWorker（CoroutineWorker）：与按钮同一条幂等管线，只决定
  WHEN——Periodic 4h（充电+unmetered WiFi 约束）+ App 每次打开
  catch-up 一次（家人不需要找按钮）；批次运行期升级 dataSync FGS
  （S-04 结论），失败 Result.retry() 幂等收敛。
- 真机验证：adb 推 3 张 PNG 进三星相册 → 重启 App → 零操作 →
  `auto backup: offered=3 pushed=3 ingested=3`，Mac 库 15→18。
  首次尝试失败自动重试成功，重试路径顺带实证。
- 真机崩溃修复：Android 14 要求 WorkManager 的
  SystemForegroundService 在 Manifest 声明 foregroundServiceType=
  dataSync，否则 setForeground 即崩（tools:node=merge 覆盖）。
- 验证基建教训：cmd jobscheduler run 需 -n androidx.work.systemjobscheduler
  命名空间；periodic+约束的强制触发不可靠，改验 app-open catch-up
  路径（同一 Worker）。

## 2026-07-31 — P0：daemon 身份持久化（真机逼出的三层连环）

三星时间线显示空库 → 排查发现**常驻 daemon 每次重启换 NodeId**，
所有已配对手机瞬间变孤儿（配对绑的就是 NodeId）——M1 漏项，真机
把它逼了出来。三层修复：
1. 身份持久化：.ppf/identity.key（0600，与 ipc.token 同信任域）；
2. **Keychain 方案被现实否决**：ad-hoc 签名的服务每次重启触发钥匙
   串授权弹窗（daemon 卡死等一个没人点的对话框）——无人值守服务
   在拿到正式签名前不能用 Keychain（T-071 迁移）；
3. 身份固定 → IPC socket 名固定 → 残留 socket 文件让新进程
   EADDRINUSE，IPC 面静默死亡 → bind 前 unlink（launchd 保证单例）。
验证：kickstart ×3，身份唯一、IPC 全通。LaunchAgent plist 补
stdout/stderr 重定向（没有它这次排查会盲飞——install_autostart
生成的 plist 也该加，挂账）。

**产品决策（用户裁决）**：UI 不再中英双语同显，按系统语言单语显示
（T-055 落实，i18n 资源已备）。

## 2026-07-31 — T-055 核心真机通过 ✅（三星时间线显示 Mac 照片库）

三星「Family photos · 20」网格全显 + 1024 大图查看器——缩略图/大图
全部从 Mac daemon 实时拉取（timeline.page + thumb.get base64）。
双 tab（Photos/Backup）+「重新扫码连接」入口。

**顺手修的产品语义 bug**：已是成员的手机重新扫码被拒
（err.not_authorized——member 不许 pair.request）→ PairFlow 先
backup.begin 试探，已被认识则直接更新本地配对（重连≠重配对，
不需要 owner 再点允许）。

**桌面 UX**：「照片库」文案统一（原「库文件夹/照片文件夹」双名
混淆，用户当场蒙了）；更改库位置加警告（旧照片不搬家）。

**T-055 打磨账**：单语显示（用户裁决：不双语同显，按系统语言）；
大图 0×0（ingest 未提取 width/height）；月份分组；重连入口做成
正经按钮；库位置迁移流程（用户改到 Desktop/NAS 未生效待决策）。

## 2026-07-31 — T-056 + T-055 打磨 + 常驻稳定性三连修

- **T-056**：download plane（ppf/download/1，viewer 即可下载=浏览语
  义）；Rust 测试比特级往返+陌生人拒绝；手机端下载进缓存+VideoView
  播放，时间线按 media_type 分流。流式 DataSource 归 M3。
- **T-055 打磨**：全 UI 单语化（用户裁决；strings.xml en/zh，双语行
  全部退役）；时间线月份分组（GridItemSpan 行头）；重连入口按钮化；
  ingest 提取图片尺寸（0×0 修复）。
- **常驻稳定性三连**（真机连环逼出）：
  ① config.toml 支持 bind_addr，家用机固定 0.0.0.0:41145——手机存
  的回连地址跨 daemon 重启有效（此前每次重启随机端口，存址即失效）；
  ② folder.set 把 data_dir 追加到文件尾=落进 [telemetry] 段 → TOML
  解析拒绝 → daemon 崩溃循环!顶层键现在重建于文件头；
  ③ 用户误改库位置到 Desktop/NAS 已回滚（迁移流程仍是产品缺口）。

## 2026-08-06 — 布局 v1 落库 + T-080/T-081 双端 UI 合并

- **设计闭环**：Claude Design「P-Pass 设计稿交付」全量归档进
  docs/design/2026-08-05-layout-v1/（主稿+运行时+设备外框+同步元数据+
  任务卡），仓库为唯一权威版本，claude.ai 项目可删。
- **T-080 Android**（9d13ce4f）：两 tab 对齐设计稿；杀掉两个真机缺陷
  （「都存好了」vs 待备份 31 矛盾、epoch 0 假日期）。单测 6/6+反证红过，
  模拟器假配对法视觉验收（run-as 注入 files/pairing.json）。
- **T-081 桌面**（632b7932）：侧栏四页+hash 路由；IPC 集合逐字未变。
  数据缺口全部诚实占位（不敢用绿点/不写承诺文案），对应 daemon IPC
  扩展挂账见 ROADMAP。

## 2026-08-06（下午）— UI 全量走查 + T-082/T-083 还原修复

- **教训固化**：合并后用户真窗口一看就翻车——「构建绿+单测绿」≠「UI 对」。
  新规矩：UI 卡验收必须双端全页面全状态真渲染走查（截图×设计稿原文×代码
  三方对照），设计稿是唯一基准，旧代码里设计稿没有的元素一律删。
- **T-082 桌面**（cc911c7d）：7 项走样修复。定性：token 无罪（64 处正常
  使用），设计稿无罪（等高/148QR/1140×720 都画了），是实施走样+窗口尺寸
  在上一卡禁区里没人动。
- **T-083 Android**（6d760cfc）：4 处旧代码遗留（副标题/立即备份黑按钮等
  设计稿不存在的元素）+ 1 处红线违反（红卡渲染原始 IrohError）。修后失败
  卡：单语人话先说「照片一张没丢」，原文只进折叠详情+logcat。
- 走查挂账重申：相册范围行、照片↑↓角标、大图页、onboarding 相册步、
  per-device 连接事实——全部等 daemon IPC / proto owner / 相册选择功能卡。

## 2026-08-06（傍晚）— 链 1 数据面全线打通（T-090/091/092）

- daemon：status+photo_count/磁盘水位、activity.list 聚合、connection 中性
  enum（iroh 不出 transport）；桌面：watermarks/last_seen/connection/活动
  批次/照片总数/磁盘条全部上屏，哨兵 >5 天亮红。
- 常驻 daemon 升级 v0.2.1：稳定路径 + launchd 受监护，配对未变。真数据
  实测：photo_count=51，SM-S9210 备份批次可查。
- **事故记录**：验收人给 daemon 传 --help 触发误接管致常驻停机数分钟
  （daemon 无参数解析）；已恢复。逼出三个产品缺口待立卡：①daemon
  --help/--version 参数解析 ②纯新启动不装 autostart ③异身份实例端口
  冲突报错不是人话。

## 2026-08-12 — metadata 新鲜度同步：裁决落库 + SYNC-02 daemon 侧节流

- 狗粮周暴露手机端删除不可见/QUIC 平面零推送等问题，讨论收敛为
  `docs/product/2026-08-12-metadata-sync-decisions.md`（8 条裁决）+
  SYNC-02..05 四张任务卡。
- **SYNC-02 完成**：`events.rs` 新增 `timeline.invalidated` + `Throttle`
  （固定窗口节流+批次收尾强制 flush，明确不是防抖，见决策档案 §⑤）；
  `backup.commit` 逐条 ingest 触发节流、收尾强制 flush；
  `Reconcile::run_once` 完成后直发一次（单轮操作不经节流）。反证：
  临时去掉节流逻辑，`window_merges_bursts_into_one_emit` 立刻变红，
  证明判据非恒真式。`cargo test -p daemon -p core-index` 全绿 + 新增
  集成测试 `commit_batch_emits_timeline_invalidated_exactly_once`
  （5 文件一批 commit → 恰好 1 次 emit）+ `just arch-check` 绿。
  **范围收窄**：`rebuild.rs` 的触发点未接——查证实际调用链后发现
  `rebuild()` 当前在 daemon 运行期零调用点（只在测试里跑），接一个
  没有真实消费者的空调用没有验证价值，留作后续若真正接入 rebuild
  运行路径时再补。
- **SYNC-03 完成**：`proto::methods::TIMELINE_SUBSCRIBE` + `authz.rs`
  放行（viewer 级）；新文件 `subscriptions.rs`（`SubscriptionRegistry`，
  用 `tokio_util::sync::CancellationToken` 而不是手搓 channel）；
  `router.rs` 的 `serve_stream` 拦截订阅方法转入推送态（ack+§③初始
  当前态推送+`timeline.invalidated` 转发）；`ipc.rs` 的 `device.revoke`
  和 `router.rs` 的自我 `unpair` 都接上主动断连。新集成测试
  `subscribe_flow.rs` 两条（真实 broadcast 转发；revoke 后连接必须在
  3 秒内关闭），反证：临时去掉 close 调用，后一条测试变红。
  `cargo test -p daemon -p proto -p core-index` 全绿 + `arch-check` 绿。
  **本地验证完，未推 GitHub**——按用户要求先在本地把 daemon+Android
  真机联调一起做完再决定推不推。
- **SYNC-04 代码完成，真机验收进行中**：Android 端 `DaemonClient.
  subscribeTimeline` + `PhotosScreen` 换掉 15s 仅追加轮询，改前台常驻
  订阅+整页覆盖+断线退避重连（状态机抽成纯函数 `nextSubscribeRetry`，
  5 个新单测）。真机（SM-S9210）飞行模式测试时发现并当场修复一个缺口：
  重连期间界面原本全程沉默，只有耗尽后才提示，补了"正在重新连接电脑…"
  的中间态提示。桌面壳本地跑最新 daemon sidecar（release build）验证
  中。**待用户确认的 5 条真机剧本一条都还没过**，本卡未移入 done/。
  另发现两处范围外的既有行为（非本卡引入）：backup WorkManager 网络
  约束下飞行模式的"延迟传输"是既有设计；桌面壳某处"连接中"文案在源码
  里查无实据，等用户截图确认。
- 下一步：等真机验收 5 条剧本走完；SYNC-05 独立，暂缓。
- **WATCH-01 完成（本地目录监听，本 session）**：`LibraryWatcher`
  （watcher.rs）——notify 监听 `originals/` + 防抖（500ms 静默窗口）+
  父路径合并 + 增量扫描：新文件经 `Ingestor` 入库（src_device=本机
  node_id，审计记本地导入，hash dedup 幂等），删除走局部对账
  （`list_asset_paths_under` + `Reconcile::remove_asset`），变化经
  `Throttle` 合并 emit `timeline.invalidated`。每小时 reconcile 保留兜底。
  macOS 坑两则：FSEvents 返回 /private/var 真实路径，监听根必须
  canonicalize（否则 strip_prefix 全失败）；同批次 Create+Remove 合并成
  无事件（测试显式等批次 flush）。Linux inotify 坑：默认监听 Access
  （读访问）事件，扫描/ingest 自读触发 Access → 触发扫描 → 无限事件
  循环淹没 Remove（CI 取证桩复现，删除永不被发现）——回调过滤
  EventKind::Access 根治。deny.toml 补 notify CC0-1.0 license +
  RUSTSEC-2024-0384 ignore（instant unmaintained informational）。
  watcher 6 单测 + watch_flow 4 集成测试（真实 notify）全绿；
  daemon/proto/core-index 全量绿 + arch-check 绿 + clippy 零警告 + deny 本地绿。

## 2026-08-13 — DAE-03 daemon CLI 纪律 + 人话报错（8/6 --help 事故 3 缺口）

- 事故（8/6 傍晚）：daemon 无参数解析，`--help` 被当普通启动一路走到单实例
  claim 触发误接管、常驻停机数分钟。三缺口补齐：
  - **① --help/--version 参数解析**：新 `crates/daemon/src/cli.rs`（纯函数 +
    单测）——`--help`/`-h`/`--version`/`-V` 在一切 daemon 机制（日志/配置/
    数据库/身份/claim/bind）之前短路退出（exit 0）；未知参数报错 + 用法，
    exit 2，**绝不静默忽略**（静默忽略 = 事故根因）。main.rs 最顶接线。
  - **② autostart 只在升级接管装**：决策抽成 `cli::autostart_install_required`
    （TookOver=true；Proceed/StandDown=false）+ 单测——纯新启动/手动/开发
    构建启动绝不写 launchd/注册表（8/6 事故第二缺口：手动启动篡改自启配置）。
  - **③ 固定端口冲突人话报错**：异身份实例（不同数据目录）或第三方程序占住
    config.toml 钉的 UDP 端口时，`humanize_bind_error` 把英文底层错误翻译成
    中文 + 修复指引（改 bind_addr / 关占用方），原始错误留日志；非占用类
    错误原样透传。
- **测试**：cli 单测 8/8（parse_cli 短路/未知拒绝/autostart 决策/占用识别/
  透传）；二进制冒烟 tests/cli_flow.rs 3/3——`--help` exit 0 且 stdout 无
  IPC:/身份铸造/已启动（证明没走到 claim/bind）；`--version` exit 0 打印版本；
  `--bogus` exit 2 + stderr 报未知参数 + 用法。**三反证全成立**：①未知参数改
  静默忽略 → `--bogus` 真的把 daemon 拉起来常驻（事故模式复现，测试挂死）；
  ②autostart 恒 true → 单测红；③in_use 放宽成 "use" 子串 → 含 "use" 的合法
  错误被误伤，透传断言红。workspace 286/286 + arch-check 绿 + clippy 零警告
  + fmt 干净。
- 期间环境：subscribe_flow 全量并发跑一次偶发红（REV-01 的 revoke 计时断言），
  隔离复跑 3/3×2 绿——与既有 blobs_resume 300s 同类并发偶发，CI（REV-01 推
  动 ci-rust 成功）未复现。
| **桌面走查补漏（≥1440 居中）** | 2026-08-13 | 本 commit | ✅ 已实现（vite build 绿 176 modules；实测 1920px 右侧死区 486px→0） | 44f9a0b 的 `@media(min-width:1440px)` 给 `.page` 加 `max-width:1180px` 但漏了 `margin: 0 auto`——只限宽不居中，超宽窗口下内容左贴、右侧留死区（用户实测反馈「右边留死区」的同类症状，只是阈值从 880px 上移到了 1180px）。补 `margin: 0 auto` 后内容居中，1920px 死区从右侧 486px 变为对称留白。 |

## 2026-08-19 MOB-27 监听与干活分家

- **根因**：content trigger 绑在 `BackupWorker` 上，同一个 job 既是监听又是
  干活。job 一执行监听即被消耗，直到 rearm 重挂前没有任何监听在接 MediaStore
  通知——**监听空窗 = 备份时长**。旧补丁在系统之外自造队列（rearm 轮询 +
  `catchUp = batchSize > 0`），依赖时间常数，且触发来自范围外的写时完全不补捞。
- **方案**：content trigger 通道绕过 WorkManager 直连 JobScheduler。新增
  `MediaWatchJob`（`MEDIA_WATCH_JOB_ID = 20260819` 稳定常量）：`onStartJob`
  先派活、后 `schedule(同 ID)` 释放，毫秒级返回；备份走
  `MEDIA_WATCH_BACKUP_WORK_NAME` + `APPEND_OR_REPLACE` 排队执行。依据是
  `JobInfo.Builder#addTriggerContentUri` 的 javadoc 原文（本机 android-36
  sources 逐字核对）：系统在 job 运行期间持续监听并把变更转交给下一个同 ID 的
  job——**系统就是事件队列**。
- **第二个洞（更严重）**：旧监听带 `UNMETERED` + `batteryNotLow` 约束，不连
  Wi-Fi 时监听根本不被投递。现改为监听裸挂（永远在线），约束挂派出去的 work。
- **删除**：`ContentTriggerRearmWorker` / `enqueueContentTriggerRearm` /
  `KEY_REARM_CATCH_UP` / `REARM_*` 三常量 / `CONTENT_TRIGGER_WORK_NAME` /
  `CONTENT_REARM_WORK_NAME` / `CONTENT_TRIGGER_POLICY` /
  `buildContentTriggerRequest` / `scheduleContentTriggerBackup`。净减约 6 KB，
  **一个时间常数都没剩下**。
- **已知代价**：trigger URI 与 `setPersisted` 互斥，看门 job 每次重启必死，
  靠"周期任务拉起进程 → `PPassApplication.onCreate` → `ensureMediaWatch`"复活；
  监听空窗上限 = 周期任务首跑。数据不丢（照片仍在水位之上）。
  连带 `PPassApplication` 的健康检查 early-return 删除（MOB-18 提示 UI 已
  pending，不恢复 = 静默死亡），`isBackupScheduled` 从此无法区分重启与
  force-stop——重做 MOB-18 前须换判据，已写进 `BackupHealth.kt` KDoc。
- **装机时发现的升级路径 bug（已修）**：`adb install -r` 保留应用数据，旧的
  `ppass-content-trigger` unique work 原封不动活着（dumpsys 实锤，还带着
  `batteryNotLow=true` + `NOT_METERED`），而本卡把 cancel 它的代码全删了 →
  升级窗口内新旧两个监听被同一波变化同时唤醒，并行扫同一水位重复推字节。
  加 `cancelLegacyContentTriggerWork`（字面量，挂 `scheduleAutoBackup`）。
- **真机证据**（<测试机> / 0.3.3(8)）：看门 job `Requires:
  batteryNotLow=false` 且无 `Network type` 行（零约束实锤）；job history
  显示 START→+27ms 派活→+32ms 释放重挂，**监听空窗 32 毫秒**（旧实现 =
  整个备份时长）；P-Pass 名下 job 精确剩 2 个。同一次探针顺手补上 MOB-09
  的真机验收（`skipped 1/1 unreadable media record(s)`，无 ENOENT 重试）。
- **验证**：`:app:testDebugUnitTest --rerun-tasks` 218/218（基线 207），
  `:app:assembleDebug` 绿，versionCode 7→8。反证 10 条全红（去 forDescendants /
  调换派活重挂顺序 / KEEP 换掉 APPEND / 去 ensure guard / 暂停不停监听 /
  结束不自检 / 恢复 early-return / manifest 漏 BIND_JOB_SERVICE / 去重恒真 /
  不做升级清理）。
- **教训**：`codeOf` 只剥 `//` 行不够——KDoc 块注释里引用 javadoc 写了
  `jobFinished()`，把"不该出现 jobFinished"这条否定式断言判红。否定式源码
  断言必须先剥块注释。
- **真机验收 owed**：连拍只触发 1 次 / 备份期间拍照不用等下一个事件 /
  重启后监听何时回来。三项做完本卡才能移入 `done/`。

## 2026-08-20 MOB-28 区分「重启」与「被清」，被清了只提示不恢复

- **取代 MOB-18**（backlog 卡已标注，不要按它实施）。用户原话是本卡的全部
  理由："不要做静默恢复，就是要提醒。""必须点了才恢复。你都提示了，就别
  自作主张。"
- **为什么现在能做**：MOB-18 pending 的理由是 `ForceStopRunnable` 跑在
  `androidx.startup` 的 ContentProvider 里、比 `Application.onCreate` 还早就
  把 work 重排了。MOB-27 把监听搬到我们自己注册的 JobScheduler job 之后，
  WorkManager 完全不知道它存在，碰不到它——语义于是成立。
- **判据**：开机时刻 `currentTimeMillis() - elapsedRealtime()`（同一次开机内
  稳定、重启后变，零权限，容差 60s 扛 NTP 校时）。判定表
  `decideRecovery(watchScheduled, sameBoot, awaitingConsent)` 是纯函数，
  八种组合全覆盖。`awaitingUserConsent` 必须排最前——已经在等用户点了，
  重启也不许悄悄替他决定。
- **三处闸门**：`PPassApplication` 对账 / `MainActivity` 的 `LaunchedEffect`
  （用户实测栽过两次的那条"打开 App 就悄悄恢复"）/ `BootWatchReceiver`。
  第 1、3 共用 `reconcileWatchOnProcessStart`，不许各写一份。恢复的唯一
  入口是提示卡上的「恢复备份」→ `resumeAfterInterruption()`。
- **开机 receiver**（MOB-27 §五的待定项，此前判断"性价比不明"是错的）：
  `RECEIVE_BOOT_COMPLETED` 本来就在合并 manifest 里（WorkManager 带进来的），
  加它不增加用户可见权限；WorkManager 自己的 `RescheduleReceiver` 是
  `enabled=false`（只在 API<23 路径动态开启）救不了我们；manifest receiver
  不常驻。`onReceive` 用 `goAsync()` + `finally { finish() }`。
- **删除** `isBackupScheduled()`：MOB-27 之后它既不精确也会误导（看门 job
  重启必死，两边对账无法区分重启与被清）。教训保留在注释里。
- **验证**：234/234（`--rerun-tasks`，基线 218），`assembleDebug` 绿，
  versionCode 8→9。反证 18 条全红（MOB-27 的 9 条一起复跑，确认旧锁未被削弱）。
  真机端到端（0.3.4(9) / <测试机>）：force-stop → 已注册 job=0 → 打开 App
  → 看门 job **仍为 0**（没被自动装回去）+ `interruptedUnacknowledged:true`
  → UI 树里读到提示卡与「恢复备份」→ 点击 → job 回来 + 标志清除 + 卡消失
  + 立刻补跑一次。
- **已知边界**：force-stop **再重启**再打开会被判成"重启"而自动恢复——那段
  时间我们一行代码都跑不了，"被清过"没人记下。主路径（force-stop → 打开 App）
  已真机验过，那正是用户抱怨的那条。
- **四条教训（都写进了测试注释）**：①Kotlin 的 `substringAfter` 找不到分隔符
  时返回**整个字符串**，于是删掉 `finally` 之后断言反而对全文求 contains、
  照样绿（反证跑出来不红才发现）——切片断言已全改走 `sliceAfter`/`sliceBetween`；
  ②zsh 不对未加引号变量分词，反证脚本 `for f in $ALL` 让备份/还原静默失败、
  18 次破坏叠加在工作区上，驱动已改成 Python 内存快照；③反证驱动只认
  `FAILED` 行会把编译失败当成绿；④用索引区间重写测试会连带切掉夹在中间的
  用例（`upgrade_kills_the_legacy_workmanager_trigger` 就这么丢过一次）；
  ⑤`grep -c` 数 dumpsys 的 job 会把历史记录算进去，必须按 `JOB ` 分块解析。

## 2026-08-20 MOB-19 备份只有一条管线（手动 = 又一种触发方式）

- **修法被用户改了方向**。卡面原方案是"照搬 MOB-09 的逐条隔离到
  BackupUiStateHolder"，用户否掉："不是说应该自动和手动触发的备份一样吗？
  ……手动就相当于第 5 种触发方式。**你为什么这里弄了两条路径去做备份呢？**"
  ——两份实现必然漂移，MOB-09 只修了其中一份就是证据。所以是**删掉第二条**。
- **手动 = 事件⑥**：`triggerManualBackup` / `cancelManualBackup` 入
  `BackupWorker.kt`。两个手动专属语义靠触发档与 input data 表达，管线一行未改：
  零约束（新增 `BackupTier.MANUAL`，唯一不读 settings 的档——用户定稿"手动
  能不能在检测-发起之间直接人工点击-发起"）+ 全量重扫（`KEY_FULL_RESCAN`）
  + `KEEP`（跑着的时候再点不打断）。
- **删掉第二条管线**：`BackupUiStateHolder` 298→199 行，删的是它自己那份
  `scanSince`/`hashWithCache`/`BackupRunner.run`/`WatermarkStore`。
  **MOB-19 是靠删除修掉的，不是靠加错误处理。**
- **界面状态改从 work 上读**：worker 新增 `setProgressAsync` 三阶段上报 +
  终态输出，`uiStateOf(infos)` 纯函数映射。用 async 版是因为调用点在
  `buildCandidates` 的 lambda 与 `BackupRunner` 回调里（非 suspend 上下文）；
  `ProgressThrottle` 首末必发（MOB-11 教训：进度条别"卡死然后突然完成"）；
  上报失败一律吞（上报不是业务逻辑）。**顺带收益**：自动备份第一次有了
  实时进度。
- **MOB-13 的特例分支消失**：旧手动链路"全已确认→早退+补齐"的分支不再需要，
  全量重扫下正常路径就会 commit + `recordRun`。写入点从两处变一处。
- ⚠️ **真机核实到的事实**：设置页里**早就没有「立即备份」**了
  （0.3.5(10) 走查：备份哪些相册/仅 Wi-Fi/失败通知/存储电脑/版本/自动备份）。
  `onBackupNow` 只剩两个触点——进行中的「暂停」和失败红卡的「再试一次」。
  `R.string.manual_backup_entry` 是死文案（无代码引用）。所以本卡真正修的是
  **「再试一次」那条路径**：用户在失败红卡上反复点而永远好不了，比隐藏入口
  严重得多。
- **验证**：247/247（`--rerun-tasks`，基线 234），`assembleDebug` 绿，
  versionCode 9→10。反证 27 条全红（MOB-27/28 的 17 条一起复跑）。
- **教训**：反证 U/AA 第一次是绿的——`sliceAfter` 把锚点之后的整个文件都带
  进来，"这个函数里必须是 KEEP"实际在全文找 KEEP（`triggerProcessStartCatchup`
  里正好有一个）。**函数级断言必须夹出函数体**，加了 `sliceBetween`。

## 2026-08-20 BLOB-01 收件箱不回收，占盘翻倍（实测 2.05x → 1.00x）

- **根因不是"忘了清"，是"绕了一圈根本不该绕"**。`upload.rs` 接收时本来就
  流式算 BLAKE3 并自己比对（不匹配 reject），然后才 `blobs.push` 把这份
  **已校验**的文件拷进 blob store（`add_path` 默认 `ImportMode::Copy`），
  commit 时 `backup.rs` 又 `export_to` 拷回来才能 ingest。同一份字节拷三遍，
  而 blob store 那份永不回收。用户机器实测：originals 549M + .ppf/blobs/data
  553M = 占盘 2.05 倍。
- **改动**：①`upload.rs` 校验通过后原地改名坐实（`<hash>.upload` → `<hash>`），
  不再碰 blob store，`UploadPlane` 不再持有 `Blobs`；②`backup.rs` commit 优先
  吃 staging 里现成的，blob store 降级为只服务回退路径（T-032 主动拉取）；
  ③新增 `inbox.rs`：启动时清空 `.ppf/blobs`（那一刻不可能有传输在飞），
  staging 只扫 `.upload` 半成品、完整文件一律保留。
- **为什么不用 GC**：iroh-blobs 0.103 的单 blob `delete` 是 `pub(crate)`，
  文档明写只让走 GC；而 `gc_run_once` 所在 `store::gc` 是私有模块，`GcConfig`
  默认 `None` 只能配定时轮询。与其把回收交给控制不了的定时器，不如在可证明
  安全的时刻（启动）自己动手。这同时是老用户的迁移路径。
- **续传零损失**（查过）：`UploadHeader` 无 offset/resume 字段，`upload.rs`
  零续传逻辑，`File::create` 直接截断——上传平面从来都是断了整个重传。
- **验证**：真实 daemon 端到端 `BACKUP OK: pushed=12 ingested=12;
  rerun pushed=0 dup=12`（`rerun pushed=0 dup=12` 正是卡面要的"同一 hash 再
  offer 不重传也不报错"）；固定目录量占盘 **originals 2,400,078 B /
  blobs/data 0 B / staging 0 B = 1.00x**。`just ci` 全绿。反证 4 条全红。
- **集成断言**进 `upload_flow.rs`：commit 后 `blobs/data` 与 `staging` 必须为 0。
  口径盯 `blobs/data/` 而非目录总量——store 的 redb 空库有 ~1MB 固定开销，
  比小尺寸测试图还大（第一版就这么误报的；真机布局：data 553M / blobs.db 4.7M）。
- **顺手修掉 E2E-02 的漏修**：跑 `just android-backup` 炸出
  `DaemonBackupTest.kt:82` 也是 `parsePairingQr(qr).addr!!`——同一个 H-10b
  死契约。全仓共**四处**（DaemonHello / DaemonBackup / NetProbe / DeviceBackup），
  上一轮只修一处就宣布"解红"。已抽成共用 `addrOf(qr)`（`PairingQrAddr.kt`），
  四处全走它。⚠️ 教训：**"这个测试挂了"要先问"还有几个同形的"**——一次契约
  变更会同时打断所有依赖它的测试。
- **用户数据处置**：按用户授权清理本地重装，用 `mv` 不用 `rm`——旧库移到
  `~/本地旧库副本`（1.1G，含 549M 照片），验收通过后
  由用户删。

## WATCH-02 / WATCH-03 —— Finder 与索引的双向真相（2026-08-20 晚）

- **WATCH-02 根因是一个斜杠**。用户报「Finder 删光照片，索引一条没减」。卡面
  写了三条假设（FSEvents 句柄失效 / 前缀口径 / 瞬态 remove 过滤），**只有第二条
  沾边，前两条的表述都不准**。实际是 `list_asset_paths_under` 在 prefix 已带
  尾斜杠时拼出 `LIKE 'originals//%'`，命中 0 行。整棵子树被删 → `affected_dirs`
  收敛到 `originals` 本身 → `rel` 空串 → 触发。
- **教训：测试形状 ≠ 用户操作形状**。`watch_flow.rs` 一直绿，因为它删**单个
  文件**（`rel` 非空，前缀正常）；用户删的是**整棵目录**。补测试时必须按
  「用户实际怎么操作」枚举形状——单文件 / `rm -rf` 整棵 / Finder 改名进废纸篓，
  三种都写了，其中后两种在修之前都是红的。
- **教训：没测试覆盖的函数就是没契约**。`list_asset_paths_under` 此前零测试，
  它的 doc 注释写着"按目录边界匹配"，而调用方传的 prefix 违反了这个隐含前提
  （不带尾斜杠），双斜杠就这么活了 8 天。
- **WATCH-03 是修 02 时挖出来的，级别更高**。02 是「删了但还显示」（多显示），
  03 是「没删但不显示了」——用户在 Finder 里分类照片，索引把行删掉，照片凭空
  消失且**再也回不来**（没有新的文件系统事件了）。根本问题是身份口径：内容
  寻址系统里 hash 是身份，`rel_path` 只是当前住址，**搬家不该销户**。
- **顺带补掉的洞**：手机重传一张曾被外部删掉的照片，旧代码返回 `Duplicate`，
  staged 文件被删、索引行仍指向不存在的文件，下轮对账把行也删掉——那张照片
  永远补不回来。现在会正常落位。
- **性能口径写进代码注释**：删除方向的候选集是「变化子树下的索引行」，变化
  目录是 `originals` 本身时就是全库；每行一次 stat，5 万行百毫秒级，可预估。
  但必须整批下放 `spawn_blocking`——逐行同步 stat 会钉住 async 运行时的工作线程。
- **我自己的反证驱动出过一次假阴性**：retarget 用了 `str.replace` 但锚点不存在，
  静默无效，M4 跑的还是旧靶子并报告「恒真式」。手工复现才发现它其实是红的。
  ⚠️ **`str.replace` 必须先 assert 锚点存在**——这是本项目第三次被同一形状咬。
  驱动已加 `assert old in orig` + 还原后 `assert` 内容一致。
- **验证**：Rust 301/301，`just ci` 全绿，反证 8/8 全红（含 M1/M1b/M1c 三个不同
  入口打同一处修复、M4 的 canonicalize 缺失导致「用户放的位置被我们动了」）。

## WATCH-04 宽容入库 —— Finder 是一等公民（2026-08-21）

- **先摆事实再谈设计**。用户问「macOS 一个目录的变更都能监听什么事件」，我写了
  诊断工具把真实事件打出来（`docs/product/2026-08-21-macos-fs-events.md`），
  三条结论都跟直觉相反：①事件的**类型**基本没有信息量（改写文件报 `Create`、
  改名在旧名字上报 `Create`、删目录同时报 `Create` 和 `Remove`），只有路径可信；
  ②「拖进来」和「拖出去」长得**一模一样**（都只有一条 `Modify(Name)`），判断
  只能靠 stat；③根目录删掉重建，监听**不会死**——这条直接推翻了我在 WATCH-02
  里列为「最可能」的假设，已加断言钉住。
- **用户的提案纠正了我一个错判**。我说「手放的文件归属只能留空，归本机会破坏
  ADR-006，这是解不了的架构张力」。用户提「用本机标签分类？」——对的：规则
  「不在 `<64hex>/` 下 = 本机」**目录树自己就能重现**（重建总在本机跑），铁律
  根本不用破。⚠️ 教训：说「这是架构张力，解不了」之前，先检查那个约束到底
  约束的是什么。
- **宽容规则的真正代价不在宽容本身，在它暴露的旧洞**。`asset` 表 `hash` 是主键
  而 `rel_path` **没有唯一约束**。旧的严格布局（无条件 mv + `-1` 后缀）**歪打
  正着**掩盖了「用户编辑已入库文件 → 同一路径两条索引行」这个问题：文件被搬走
  了，老路径空了，对账顺手清了老行。改成宽容之后洞就露出来。所以「路径唯一性」
  是宽容落位的**前置条件，不是可选项**。
- **反向守卫比正向断言更值钱**。加了
  `a_file_from_outside_still_lands_in_the_canonical_layout` —— 否则宽容会滑向
  「谁都不搬」，手机上传的文件永远烂在 staging 里。同一批还加了
  `duplicate_stays_duplicate_while_the_recorded_file_is_present`（WATCH-03）。
- **性能先量再决定**。用户机器上 203 张 570MB 实测：stat 4.6 µs/张，hash
  2.8 ms/张（995 MB/s），**620 倍**。据此把 inode 身份缓存判为 backlog——百张
  量级完全无感，几千张才有意义。没有这组数字我会凭「重读 5000 个文件很贵」
  直接开工。
- **语义变更要敢改测试**。`watch_flow.rs` 里 6 个测试的前提是「文件会被搬到
  canonical 目录」，全部按新语义重写为用户自建的 `originals/2026/08/` 树——
  **测试不该假设我们的布局形状**，那正是 WATCH-02 里「测试形状 ≠ 用户操作形状」
  的同一个错。顺带删掉两个失去意义的辅助函数（clippy dead-code 报出来的）。
- **验证**：Rust 305/305，`just ci` 全绿，反证 5/5 全红。

## 真机三条反馈：MOB-29/30/31（2026-08-21）

- **先证伪再修**。用户报「同步完成后执行了一个全量同步，不知道是显示问题还是
  正在执行」。我先证明**不是在执行**：`WorkProgress` 表零行、存储端审计零
  ingest、库里行数不变、`ppass-auto-backup` 从 11:22:05 排队至今一次没跑过。
  确认是显示问题之后才动代码。**「是不是真在跑」比「为什么会这样」先回答。**
- **MOB-31 的根因是一个集合语义误用**：`infos.lastOrNull { isFinished }` 取列表
  最后一个，而 `getWorkInfosByTagFlow` 不保证按时间排序（Room 顺序，实际按
  UUID），五条通道的终态同时躺着 → 随机挑一条历史记录。⚠️ **凡是"最近一条"
  这种语义，都要问一句"按什么排序"** —— 集合 API 不给你时间顺序。
- **adb 直读设备状态比看日志快一个数量级**。这轮全部证据都是这么拿的：
  `confirmed.json`（手机的已备份集）、`backup_scope.xml`（相册范围）、
  WorkManager 的 `androidx.work.workdb`（**在 `no_backup/` 不在 `databases/`**，
  `WorkSpec.output` 能解出每次 run 真实上报的 ingested）、`content query` 数
  相册张数。再把 `confirmed` 与 `select hex(hash) from asset` 求交集，
  **直接量出「手机撒谎的张数」= 185**。这个手法记进 NEXT 了。
- **MOB-30 的改法有一处不显眼的记账坑**：逐张入库之后，`commit` 循环里那句
  「已在索引里 → duplicates++」会把上传阶段刚入库的**再数一遍**。所以 Session
  除了 `ingested`/`duplicates` 还需要一个 `settled` 集合让 commit 跳过且不计数。
  ⚠️ 改数据流时，**顺带检查所有依赖"索引里有没有"做判断的分支**。
- **抽公共实现是硬要求不是洁癖**。`ingest_one` 让上传路径与 commit 路径共用
  一份单条入库逻辑——MOB-19 手动/自动两条备份管线漂移的教训还热着。
- **我又栽在 grep 过滤器上**。`./gradlew ... | grep -E "^e:|error:"` 没输出，
  我报告「编译过了」；实际 gradle 打的是 `Unable to locate a Java Runtime`，
  **根本没跑起来**。⚠️ **grep 没匹配到 ≠ 成功**，要看退出码或 BUILD SUCCESSFUL。
  这与 8/20 那次「`grep -c` 数 dumpsys 把历史记录算进去」是同一类错误。
- **反证又抓到我自己两个恒真式**：①「终态必须盖时间戳」原本对整个文件
  `contains`，而失败分支里有同一串，把成功分支的戳删掉照样绿——改成夹在
  `successStamped` 函数体内断言；②「全无戳退回列表顺序」原本只放**一条**存量
  记录，一条时任何挑法结果都一样。⚠️ **断言要夹边界；样本要足以区分**。
- **验证**：android 252/252、Rust 307/307、`just ci` 全绿，MOB-31 反证 4/4、
  MOB-30 反证 4/4。

## MOB-32：清场前 `du -sh` 那一下抓到的 L0（2026-08-21）

- **被丢弃的工作不会留下入库记录**。用户报「同步完成后执行了一个全量同步」，
  我查了 `WorkProgress`（零行）、存储端入库审计（零 ingest）、库里行数（没变）、
  排队的 work（未跑），断言「不是在执行，是显示问题」。**前半句是错的。**
  真相：全量上传确实发生了（11:18–11:22，186 个文件 547MB 进了 `.ppf/staging`），
  但 commit 报 `ingested=0` 把它们全扔了，所以入库审计里当然看不到。
  ⚠️ **判断「传了没有」要去看中转区和磁盘占用，不能只看入库审计。**
  抓到它纯粹是因为清场前顺手 `du -sh` 发现 553M 的库里 originals 只有 3.4M。
- **「此刻没在跑」≠「那次没发生过」**。我的证据每一条都是真的，错在外推。
- **根因是两个"各自都对"的设计撞在一起**：`backup.begin` 无条件重置 session
  （对空闲设备幂等，注释也这么写的），而漂移校准 `existCheck` 也走 begin +
  manifest；session 按设备 NodeId 索引 → 校准与备份同一把钥匙 → 用户打开 App
  就把正在上传的会话清空了。commit 循环零次、报 0 入库、**却返回 ok**，手机
  据此把 186 张全标记「已备份」。⚠️ **共享键的生命周期要按最长的那个用途设计**，
  「幂等」只在空闲态成立。
- **泄漏点会搬家**。BLOB-01 把 `blobs/data` 压到 0，本轮 547MB 全在 staging：
  `is_partial_upload` 只认 `.upload` 后缀，**已校验完成但没入库**的孤儿回收
  逻辑永远碰不到。⚠️ 修一处占盘泄漏之后，要问「同一份字节还会停在哪」。
- **MOB-30 意外成了这条的主要补丁**：逐张入库让文件在上传完成那一刻就进索引，
  session 被清空再也不能让已上传的东西凭空消失。但 MOB-32 仍必须做（数字、
  水位、兜底路径、存量孤儿）。

## 2026-08-21（下午）MOB-32 修完：会话生命周期与三处对账

- **`begin` 的「幂等」只对空闲设备成立。** 改成 `entry().or_default().touch()`，
  会话生命周期归 `commit`（成功即删）与新 janitor `sweep_sessions(1h)`。
  ⚠️ **共享键的生命周期要按最长的那个用途设计**——会话按设备 NodeId 索引，
  于是「查一下有没有这些 hash」这种只读操作和「传 186 张」共用同一把钥匙。
- **审出来的回归比原 bug 更隐蔽。** `begin` 不再清空会话之后，上一轮声明过、
  手机上已删掉的「幽灵 item」会让 commit 走 `fetch_from`；手机从不 serve
  blobs → 报错 → 报错时 `sessions.remove` 走不到 → 重试又把会话 touch 活 →
  janitor 也收不走 → 备份一直红。**拿掉一个「破坏性」的动作之前，先问它是不是
  正在替谁兜底。** 修法：拉取回退加 `provider.is_some()` 门。
- **证据不能存在会被清掉的地方。** commit 要判断「传了 N 张却入库 0 张」，
  而这个矛盾的成因恰恰是会话被清 —— 台账放会话里就一起没了。所以
  `delivered` 是独立于 session 的一张表。
- **有记录的裁决反转。** BLOB-01 定「staging 裸文件一律保留」，理由「下一轮
  手机会重新 offer，省一次上传」。这条推理有个**没被验证的前提**，而本卡的
  事故正好打掉它（假 ok 让手机再也不 offer）→ 547MB 永久孤儿。
  ⚠️ **一条「保留」的理由如果依赖别人将来会来取，就要问：他凭什么还会来？**
- **反证驱动第四次被同一个形状咬。** `cargo test --lib <短名> -- --exact`
  一个测试都没匹配到（`--exact` 对 lib 测试要写全模块路径），cargo 退 0，
  被我读成「绿」。前三次：`str.replace` 锚点不存在 → 变异静默 no-op；
  `grep '^e:'` 没匹配到 gradle 的 `Unable to locate a Java Runtime`；
  `sliceAfter` 把整个文件带进断言。**同一个根源：某种「没找到」被当成
  「通过」。** 驱动现在解析 `running (\d+) tests`，跑到 0 个直接判无效。

## 2026-08-21（真机验收）四条修复同时成立，外加两个新发现

- **MOB-30/31/32 + WATCH-02 一次全验了。** 12 张的相册 → `ingested=12
  duplicates=0`、staging 收尾 0 字节；Finder 删 5 张 → `asset.removed_external`
  ×5、索引 12→7。⚠️ **一次真机跑完整流程比四次分头验都强**——四张卡共用同一份
  审计时间线，互相校验。
- **MOB-29 被真机证实**：手动删掉的 5 张在下一轮备份里原样全回来了。用户上一轮
  就预判过这件事，现在有证据了（查文件名，索引里每个 1 行）。
- **WATCH-07（新卡）**：备份管线 `place()` 进 `originals/` → FSEvents 立刻报告
  → 监听去 ingest 一遍 → 全判 `Duplicate` → 每张写一条审计。
  ⚠️ **假设一定要落成事实再写卡**：我先想到「监听咬自己的尾巴」，但没停在这儿——
  `select action, actor, count(*) group by` 一句就把 actor 查成了本机存储端
  node id（不是手机），假设变成事实。卡里那句「候选改法」才敢写。
- **`strings` 在 macOS 上只扫部分段。** 核对 sidecar 二进制里有没有新代码时，
  五条中文字符串全「没找到」，换 `grep -a` 全在。⚠️ 这是「某种『没找到』被当成
  『不存在』」这个形状的**第五次**（前四次见上一条 MOB-32 记录）。

## 2026-08-21（晚）DESK-08：修好一个 bug 会让下游的 bug 第一次有机会发生

- **WATCH-02 的修复踩响了一个一直躺着的前端 bug。** 活动流的 `#each` key 是
  `ts + ":" + action`；WATCH-02 修好之前，整棵子树的删除对账**一行都查不出来**
  （`LIKE 'originals//%'` 命中 0 行），所以从来不会有 N 条同毫秒的删除审计。
  修好之后，用户一次删 5 张 → 5 条同毫秒 `asset.removed_external` → 撞键 →
  整个活动流渲染不出来。⚠️ **改完一处对账/批量逻辑，要去看下游谁在假设
  「同一时刻只会有一条」。**
- **时间戳不是身份，主键才是。** `audit_log` 有自增主键、`AuditRecord` 一直带
  `id`，只是 IPC 层没往外传，前端只能拿 `ts + action` 凑一个"看起来够独特"的
  key。凑出来的唯一性在批量面前必然破产。
- **「还有几个同形的」这次主动问了**（E2E-02 的教训）：全文 3 处 keyed each，
  另两处的 key 是 asset 主键和按月分组键，都真唯一，没有第四处。
- ⚠️ **「函数级断言必须夹出函数体」第三次复发。** 前端守卫第一版只断言了读侧
  `backupDuration[e.ts`，而写侧是 `out[...]`——把写侧改回去测试照样绿，反证 D2
  当场抓到。夹出 `backupDuration` 函数体、读写两侧一起断言才对。
- **桌面端测试基建从 8 条涨到 18 条**（`auditKey.test.js` 是第二个前端测试文件）。

## 2026-08-21（收口）对照清单落地 + 本地正式构建

- **新增 [`docs/CHECKLIST.md`](CHECKLIST.md)**：把 ROADMAP 4000 行里跟"现在"有关的
  部分抽成用户能逐条勾掉的动作清单（真机验收 / 等拍板的决定 / 待做 / backlog /
  命令速查）。⚠️ **ROADMAP 是历史账本，不是待办清单**——两者混在一个文件里的时候，
  用户想"对照着做点事"就得自己从一千行里挑，这本身就是个可用性问题。
- **本地正式构建两条都跑通了，但两个"报错"都是无凭据路径**：macOS 的 `.app` 出得来
  （内置 `ppf-daemon` 已逐字节核对含 MOB-32 + DESK-08），只是 updater 的 `.tar.gz`
  缺 `TAURI_SIGNING_PRIVATE_KEY`；Android release APK 未签名。
- **`BUILD-01`（新卡）**：本地 JDK 25 让 `lintVitalAnalyzeRelease` 炸，异常信息里
  只有一个 `> 25.0.1`。⚠️ **那不是错误码，是 Java 版本号**——我第一眼当成了签名
  配置缺失。CI 钉 JDK 17 所以一直没暴露。**本地工具链跟着 `brew --prefix openjdk`
  漂，而 CI 是钉住的**，这个不一致本身就是"本地绿 CI 红"和反向两个坑。
- **远端 `workflow_dispatch` 触发不了**：`gh` 无认证态、环境里也没有
  `GH_TOKEN`/`GITHUB_TOKEN`。路径过滤的 ci-rust / ci-android / ci-desktop 已被
  今天 9 个 commit 自动触发，但结论看不到。⚠️ **纪律没履行就要说出来**，
  不能因为"推上去了"就当 CI 绿了。

## 2026-08-21（夜）CI 红：本地 clippy 落后 7 个小版本，`just ci` 绿是假的

- **`just ci` 绿不等于 CI 会绿**——除非本地工具链与 CI 同版本。本地 stable 停在
  1.91.0（2025-10-28），CI 的 stable 已到 1.98.0；1.98 新增的
  `chunks_exact_to_as_chunks` 在本地 clippy 里**根本不存在**，扫不出来。
  ⚠️ 这是「本地验证过了」这句话第一次被证伪。**验证的有效性取决于验证工具与
  目标环境同版本**，工具版本本身就是被验证对象的一部分。
- **CI 只报了 1 处，实际全仓 7 处。** `-D warnings` 让 `transport` 先炸，
  后面的 crate 根本没检查（`waiting for other jobs to finish`）。
  ⚠️ **只修 CI 报的那一处必然换来第二次红**——这次主动 grep 了全仓，7 处一起改
  （E2E-02 那条「还有几个同形的」教训，这次在正确的时机用上了）。
- **根因是两侧都不钉**：`rust-toolchain.toml` 写的是 `channel = "stable"`，
  CI 也用 `dtolnay/rust-toolchain@stable`。已钉成 `1.98.0`，升级从"某天 CI 突然红"
  变成一次显式提交。
- ⚠️ **`BUILD-02`：CI 侧能不能钉住我没核实**（`dtolnay/rust-toolchain` 是否导出
  `RUSTUP_TOOLCHAIN` 会盖掉 toml，没 gh 认证验不了）。**不确定就不许当成已解决**
  ——写成卡，别在回话里说"本地 == CI 构造上成立"。
- **和 `BUILD-01` 是同一个病的两个方向**：本地落后 → CI 红（Rust）；本地超前 →
  本地红（JDK 25 vs CI 钉 17）。结论不是"本地要跟上 CI"，而是
  **工具链版本必须有唯一真相，且两侧都从它取**。
- ⚠️ 顺带一个操作失误：我同时起了后台和前台两个 `rustup update`，两者抢同一个
  下载目录，报 `could not rename downloaded file ... No such file or directory`。
  **看着像磁盘权限问题，其实是我自己制造的竞态。**

## 2026-08-21（收口）凭据归属定调：只在 GitHub

- 用户定调：**「构建的任务和需要的账号证书，都只在 GitHub，其它本地不保留，
  你也不用保留，本地能跑的就跑就好了。」** 已写进 `CLAUDE.md`（新增「凭据与构建
  归属」一节）、`docs/CHECKLIST.md`、以及 agent 的长期记忆。
- ⚠️ **这条同时关掉了一整类假问题**：本地 release 构建出不了可安装产物
  （macOS 缺 `TAURI_SIGNING_PRIVATE_KEY`、Android APK 未签名）**不是缺陷，
  是设计**——以后别再去"修"它。`BUILD-01` 的范围据此收窄：只保「别让 JDK 漂移
  把 debug 构建和单测搞坏」，`assembleRelease` 移出范围。
- **顺手把 secret 实况从仓库历史里核实了**（不是猜）：`ANDROID_KEYSTORE_*` 与
  `UPDATE_SIGNING_KEY` 已配（`v0.2.1-test.2` run 30950901275 四 job 全绿，
  Android signed APK + Sign update manifest 两步都 success）；`APPLE_*` 未配
  （T-071 原话「无凭据路径 codesign 步干净跳过」「凭据路径待 H-02」）。
  ⚠️ **「有没有配」这种问题，答案往往就躺在自己的 PROGRESS 里**——比猜、比问
  都快，而且有据。

## 2026-08-25 MOB-29：删掉的照片照旧传回来，但两端各给一句告知（commit 95f3c4f）

- 定调（用户 2026-08-25）：**重传是正确行为，不拦**；删除的正确姿势是「先删
  手机原图、再删库」；要做的只是让用户知道，**不做精确归因**。墓碑方案整条
  撤销——本批**零改动 `manifest`/`missing`，零改动 proto**。
- 手机端：新 `Calibration.kt`（校准内核 + 判据 `lostFromLibrary` = `confirmed`
  交集），通知走 UX-02 通道固定 id 2030；提示插在 `removeMissing` **之前**
  （顺序承重，反过来交集恒空）。提示天然一次性——那批 hash 随即被剔出
  `confirmed`，**没有**新造去重窗口/时间戳状态。
- 桌面端：`lib/externalDelete.js` 判据（只认 `asset.removed_external`，
  `relocated`/`ingest.*` 一律不算）+ 总览页一条警告，后端零改动。
- 反墓碑判据落成 daemon 集成测试：`deleted_asset_is_still_reported_missing_no_tombstone`
  ——删掉的 hash 下一轮 `manifest` 里**仍在 `missing`**。任何隐式墓碑（含
  Immich 那种 30 天软删）都会让它变红。
- 绿：`just ci` all green（nextest 317 passed）· Android 263 tests / 36 类 0
  failure（`--rerun-tasks`）· desktop vitest 24 passed + `vite build` ✓。
  两个反证都真跑了（去掉 `confirmed` 交集 → 2 红；去掉 action 过滤 → 1 红），
  输出摘录在卡的「实施记录」里。
- ⚠️ **卡面根因描述与代码实况有一处差**，如实记在卡里而不是绕着它建东西：
  周期兜底任务（5h）本来就会跑校准（它排在所有早退分支之前），所以「好几天
  不校准」只在「这趟走到校准之前就死了」（`setForeground` 被拒是 MOB-08
  记录的最常见路径）或「后台档约束长期不满足」时成立。本次修的是前者——
  校准提成独立单元 + `doWork` 的 finally 补一次，于是**备份一步都没开始也能
  校准完**。刻意没新开周期任务（MOB-17 定调兜底不该更频繁）。
- 欠：真机验收（访达删照片 → 两端各出一句 + 照片真的回来），验收人自己跑。

## 2026-08-25 MOB-34：被删的老照片真的被补回来，K 能归零（commit d592639）

`MOB-29` 只做了「告知」，「会被传回来」那句话在手机端是**假的**——增量扫描
按水位只看新照片，被删的老照片远在水位之下，永远不进 `manifest`，存储端一直
报缺、手机压根不来问，`K` 也永远归不了零（真机：删 3 张 1 月的照片，之后 11
轮备份 `ingested=1/8/7/1/0/1/3/3/1…` 传的全是新照片，那 3 张一次都没回来）。

- 新增 `backup/ReuploadQueue.kt`：校准算出 `lost` 之后、`removeMissing`
  **之前**，按 `MOB-13` 的文件级记录把 hash 反查成 fileKey 入队；下一轮
  `MediaScanner.itemsByKeys` 按 `_ID` **定向**取回那几条 MediaStore 记录，与
  增量结果合并后走同一条管线上传，commit 成功后 `recordRun` 把 hash 与文件级
  记录一起写回 → K 归零。
- **定向不是全量**：查询代价与队列长度成正比、与相册规模无关（卡面硬约束——
  全量重扫在大库上是几分钟的活，不能变成常态）。队列为空的轮次一次查询都不发。
  回归锁住「不许靠把 `since` 改成 0 实现」，全量重扫仍只属于手动触发（`MOB-19`
  事件⑥）。
- 出队三规则，防 `MOB-09` 的「一条坏记录卡死整批」换个门重现：查无此行 /
  范围外 / 打不开（`built.skipped`，且必须在「整批读不了」早退**之前**）立刻
  丢；传成功的在 `recordRun` 之后丢；run 失败则保留、下一轮再试。
- **两条校准门都接了队列**：`BackupWorker.calibrateIfReachable` 与
  `BackupUiStateHolder.calibrateFromDaemon`（App 打开时那次）。后者原本只
  `removeMissing`——少接一处就等于那条门里剔掉的 hash 照样永远回不来。
- 绿：Android `--rerun-tasks` **37 类 / 283 tests / 0 failures / 4 skipped**
  （XML 时间戳本次生成）+ `assembleDebug` 通过；新增 `ReuploadCompensationTest`
  20 个。本批只动 `apps/android/**`，`crates/` 与 `assets/` 一行未动，未跑
  `just ci`（无 Rust/桌面改动）。
- 反证两条真跑：`planReuploads` 不合并 → 4 红；`items` 退回 `scan.items` →
  1 红（`合并结果必须落成本轮列表`）。红输出摘录在卡的「实施记录」里，之后
  全部还原。
- ⚠️ 已知边界如实记在卡里：`MOB-13`（0.3.4）之前备份的存量条目没有文件级
  记录，反查够不着——判别法与绕法（先手动全量备份一次补齐记录）写在卡里，
  **刻意不为此加自动全量重扫**。
- 欠：真机验收一条（删 3 张老照片 → 不手动干预 → 它们回来、K=0），验收人自己跑。

## MOB-36 移进已选相册的老照片进本轮候选（2026-08-26，commit 55f8c43 · 🟡 等真机验收）

- **根因（与 `MOB-34` 同族）**：相册之间移动照片不改 `_ID` / `date_added` /
  `date_modified`，只改 `bucket_id`——移进已选相册的老照片水位值远在水位之下，
  增量扫描永远看不见它。真机现象：MediaStore 通知照发、看门 job 照起、派活正常，
  **但什么也没传**（验收人：「必须拍照才行？我通过相册移动，它后台没触发？」）。
- **选卡面 A 路（按 bucket 定向查），不选 B（bucket 归属快照表）**：B 也必须每轮
  发同一条范围查询才能比出变化，查询成本一样，却多一张要落盘/要清理/要三方对齐的
  状态表。A 的「快照」是免费的——`ConfirmedState.files` 与 `HashCache` 本身就按
  fileKey 索引，「这个文件处理过没有」直接问它们。**少一份状态，同样的成本上界。**
- **成本压住的那一条**：返回集 ≈ 已选相册总张数，**一行都不直接哈希**——已知 hash
  且仍在 `confirmed` 里的一律跳过（不开流、不哈希，验收④）。稳态零候选、零哈希；
  查询次数恒 2（范围为 null 或水位为 0 时 0 次）；开销 ∝ 变化量而非库大小。
- **新增 `backup/ScopeBackfill.kt`**（`planScopeBackfill` 纯函数 + `knownHashOfFile`
  两表查询）与 **`MediaScanner.scanScopeBelow`**（`BUCKET_ID IN (已选) AND genCol <= ?`
  ——移**出**已选相册的行根本不在结果集里，验收⑤ 由查询构造保证；**不返回
  nextWatermark**，返回类型钉死「补齐不参与水位推进」，`MOB-09` 语义一行未动）。
  `doWork` 走 `MOB-34` 建的同一条汇合点（`val items = plan.items + backfill`），
  候选构建 / 进度分母 / batchSize 因此自动全部用上，没有第二处改动。
- **顺带治好**「新勾选相册里的存量照片自动备份永远够不着」（同一根因另一面）。
  代价：勾选大相册后第一轮自动备份一次 offer 整个存量（与手动全量重扫同量级），
  **属预期行为，不是回归**。
- **明写的取舍**：范围内、水位之下、hash 未知、文件打不开的坏记录，现在每轮多一次
  失败的 `open`（上界 = 坏记录条数，`buildCandidates` 逐条隔离保证挡不住整批）。
  刻意不加「打不开」负缓存——那正是选 A 要省掉的那份状态。
- 绿：Android `--rerun-tasks` **39 类 / 302 tests / 0 failures / 4 skipped**
  （XML 时间戳 2026-08-26 11:11:51 = 本次生成；基线 38 类 / 290）+ `assembleDebug`
  通过；新增 `ScopeBackfillTest` 12 条，既有测试一行未改。本批只动
  `apps/android/**` → 受影响 CI 域只有 **ci-android**（`crates/`、`assets/`
  一行未动，未跑 `just ci`）。
- 反证四条真跑（不合并进管线 → 2 红；不补齐 → 4 红；去掉「已确认的跳过」→ 3 红；
  查询去掉 `BUCKET_ID IN` → 1 红），红输出摘录在卡的「实施记录」里，之后全部还原。
- 欠：真机验收一条（把一张 1 月的老照片移进已选相册 → 不手动干预 → 它被备份），
  验收人自己跑；抓手是 logcat 里的 `scope backfill: N in-scope item(s)…`。

### MOB-40 还没选相册就把整库传了（2026-08-26，L0，🟡 等真机验收）
- 根因是一条语义：`selectedBucketIds() == null`（从未选过）被全链路解释成
  「全量备份」。logcat 实锤：全新安装后 `scanning 254/254` 跑在用户进选相册页
  **之前**，选完之后那一轮才是正确的 `offered=11`。
- 闸门放在管线咽喉（worker 读范围那一处，扫描之前），**不逐个堵五条触发通道**
  ——那是「同一判断写五遍」，MOB-33/34/35/38 四个 bug 全是「漏接一处」。
- null 与空集行为相同、盖戳分开（`KEY_NO_SCOPE` / `KEY_NO_ALBUMS`），UI 文案共用。
- 45 类 / 340 tests / 0 failures（XML 16:08:45），反证真跑变红；只动
  `apps/android/**`，受影响 CI 域只有 **ci-android**。
- 顺带修掉一条自钉字面的旧测试（它断言的正是本卡删掉的那条缺陷语义），
  顺带开 `MOB-41`（重传提示发在范围过滤之前）。
- 收尾补一处同一语义的另一半：`computeTripletSafe` 的 `countAll(null)` 是全库
  口径，会让状态条挂着「还有 254 张待备份」而 worker 一张不传、永不收敛
  （可达路径：配对 → 选相册页 → 部分授权不保存范围 → 回 Home）。改成与
  DOG-01c/d 同一个退化出口：没选过范围 → 三元组不显示。最终 45 类 / 341 tests。

### UX-14 失败重试被渲染成「被暂停」（2026-08-26，L1，🟡 等真机验收）
- 验收人「传一半自己暂停了，按道理我没碰到」——不是误触。失败走
  `Result.retry()`，而 WorkManager 的 retry **结构上拿不到 outputData** →
  那一轮不盖 `KEY_FINISHED_AT` → UX-13 的判据认为 17:12:48 那次暂停「还没被
  覆盖」→ 界面又显示「继续」。约 2 分钟后有一轮跑成功盖戳才自愈。
- 判据的锚点从「最新完成时刻」扩到「最新**开跑**时刻」：新增 `RunStartPrefs`，
  worker 在**抢到互斥门之后、扫描之前**落盘（空转轮不算开跑）。
- UX-13 卡面那句「时刻不需要清除时机就能自证过期」假设每轮都留终态戳，而
  retry 这条路留不下——被自己的前提坑了，文件头注释已改。
- 46 类 / 347 tests / 0 failures（XML 17:43:01），反证两红。
- ⚠️ 第五次「源码断言钉字面形状」误伤（`uiStateOf(infos, pausedAt)`），已改钉
  不变量。

### 2026-08-26 真机回归（test.8，24 步）结论
- **MOB-40 通过**：只选 11 张的相册 → 全程只传 11 张，配对到选完之间零传输。
- 通过：#1 #3 #4 #6 #7 #10 #11 #15 #16 #17 #19 #20 #21 #23 #24
  （#21 日志确认范围非空且不含相机——拍照不传、move 进 P-Pass 立即传，正是
  MOB-40 想要的形状；#24 的 1+4=5 张重传收敛正确）。
- 新开卡：`UX-14`（#14）、`DOG-03`（#2）、`NET-01`（#18）、`I18N-01`（#9）。
- 进 backlog：`UI-05`（#8 扫描阶段裸 0 + 过早出现暂停按钮）、`UI-06`（#12
  进度条与大字不同步）、`DESK-11`（#13 断开配对后审计显示 id）。
