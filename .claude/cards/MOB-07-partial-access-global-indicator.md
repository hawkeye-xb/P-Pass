# MOB-07 部分授权全局提示（tab 红点 + 复用哨兵通知模式）　级别 L1【backlog，不排期——用户 2026-08-14 明确指示"现在先不做，在做 UI 重构"，等桌面壳 Tailwind 迁移(DESK-07)收尾后再看】

> ⏸ **backlog，不排期**（用户 2026-08-14：「现在先不做」）。级别 L1。

背景：2026-08-14 真机实测确认——手机只授权部分相册（Android 14+
`READ_MEDIA_VISUAL_USER_SELECTED`）时，WorkManager 内容触发器照样会
被唤醒（JobScheduler 实测证据：唤醒后 `app called jobFinished` 正常
完成），**但唤醒之后的 MediaStore 查询仍然被权限范围卡住，新拍的
照片始终查不到**——桌面库对照实测：唤醒后一小时，新照片始终没有
出现在 `originals/` 里。也就是说"自动后台备份"这个承诺在部分授权
下是假的，而**用户完全没有办法感知**——现有的部分授权提示卡
（`partialAccess = partialMedia`，见 `MainActivity.kt` 第 495 行）
只挂在"设置"tab 的 `HomeScreen` 里，用户如果主要停留在"照片"tab
看家庭相册，永远不会看到这张卡。

## 目标

两层提示，缺一不可：
1. **常驻小红点**：`ui/TwoTabs.kt` 的底部栏是常驻的（不管当前显示
   哪个 tab，这条 Row 一直在），"设置"tab 的 `TabCell` 加一个"有事
   需要关注"的红点参数——部分授权只是第一个触发条件，以后别的"需要
   关注"状态（比如哨兵触发、电池白名单契机）都可以复用同一个红点
   聚合逻辑，不要为部分授权单独写一套判断。
2. **主动推送通知**：复用 `SentinelStore.kt`（SENT-01）已验证过的
   模式——纯判定函数 + 落盘状态 + 去重冷却窗口 + 搭现有后台任务便车
   发通知，不新起心跳。检测"长期处于部分授权状态且期间有新照片本该
   备份却没有"，参照 `shouldNotifySentinel` 同款结构写一个
   `shouldNotifyPartialAccess`（纯函数，JVM 可测）。

## 范围（等排期时再细化，这里先划个大概）

- `apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/TwoTabs.kt`
  （红点渲染）
- `apps/android/app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt`
  （红点触发条件的状态汇总——目前只有 `partialMedia` 一个信号源，
  未来可能是个"needsAttention"聚合值）
- 新文件（仿 `SentinelStore.kt` 结构）——落盘状态 + 判定纯函数 +
  去重窗口
- `BackupWorker.kt`（搭便车发通知的接线点，仿 `notifySentinel` 那段）

## 不准动

- `crates/`/`apps/desktop/`——纯 Android 端问题，不涉及桌面/daemon。
- `hasPartialMediaAccess`/`isPartialMediaAccess` 判定逻辑本身（MOB-05
  已验证过，本卡只是消费这个信号，不改它怎么判定）。

## 设计要点（先记下讨论过的结论，排期时展开）

- 红点逻辑要做成"可扩展的关注点聚合"，不要写成"专门为部分授权开一个
  if"——以后哨兵/电池白名单契机这类"需要用户看一眼"的信号会越来越多，
  应该是同一套红点消费多个信号源。
- 通知去重窗口、"该不该发"的判定思路完全照抄 SENT-01 的哲学（契机式，
  不是心跳式；发过一次之后进入冷却期，不是每次后台任务都检查都发）。
- 这次真机实测的证据（JobScheduler 唤醒了但 MediaStore 查询看不到
  新照片）可以直接作为本卡验收阶段"反证"的素材——不需要重新找一遍
  真机验证方法，上次怎么测的，这次还能怎么测。

## 收尾（排期时再定，本卡目前是纯记录，不要求验证）

暂不适用——这是 backlog 卡，不是待验收的实施卡。排期时把上面"设计
要点"展开成正式的"可执行验收"章节。

---

## 相关但独立的备选方向（2026-08-14 讨论，同样 backlog，未来若要"全文件
备份"扩展时优先评估这条）

用户提问：以后如果扩展成"整个文件夹/全部文件"的备份（不限于 MediaStore
认识的照片/视频），能不能用 Android 的 Storage Access Framework
（`ACTION_OPEN_DOCUMENT_TREE` + `takePersistableUriPermission`，整个
文件夹树授权）代替现在这套 `READ_MEDIA_*` 模型，从根上绕开"部分授权"
这个坑？

调研结论（不是拍板，是留证据）：
- **DCIM/Pictures 不在系统禁止名单里**——Android 11+ 只挡内部存储根/
  SD 卡根/`Download` 目录，用户可以把"相机"文件夹整个授权出来。
  来源：https://developer.android.com/training/data-storage/shared/documents-files
- 这个授权大概率是"整棵目录树"，不是像 `READ_MEDIA_VISUAL_USER_SELECTED`
  那样精确到单张照片的清单——理论上更耐用（前提是文件夹本身没被移动/
  删除）。
- **最关键的问题没有查到确定答案**：别的 App（比如系统相机）往这个
  文件夹写新文件时，SAF 的变化监听会不会真的触发——这是具体存储
  实现细节，Android 官方文档没有通用保证。**要真的搞清楚，需要一次
  跟本卡"部分授权唤醒测试"同款的真机实测**，不能只凭文档下结论。
- **代价重新核实过（2026-08-14 查代码，纠正了此前凭印象写的说法）**：
  拍摄时间 `taken_at`/去重哈希跟 MediaStore 无关——手机侧 `BackupRunner.kt`
  的 `Candidate` 根本没有 `taken_at` 字段，只推原始文件字节；拍摄时间是
  daemon 侧 `crates/core-media/src/exif_meta.rs::read_meta()` 直接解析
  文件自带的 EXIF 段算出来的，去重哈希是手机侧自算的 blake3——都不依赖
  MediaStore 的任何列，换成 SAF 拿到的还是同一份文件字节，这块零影响。
  真正的代价是手机侧 `MediaScanner.kt` 现在靠 `DATE_ADDED`/
  `GENERATION_MODIFIED` 做的**增量扫描**（不用每次全量扫文件系统）——
  SAF 的文件夹树授权没有对应的内置变化流，就是上一条"变化监听会不会
  真的触发"要验的东西，不是元数据丢失问题。
- 没查到有参考价值的同类 App 案例（Syncthing/FolderSync 等，调研
  时间预算用完，没查到，不是查了没有）。

**这条不是"部分授权全局提示"的替代品，是解决同一类问题的另一条更
根本的路线**（前者是"权限受限时怎么提示用户"，后者是"能不能干脆
不受这个限制"）——两条独立记录，排期时分别评估，不要合并成一件事。

### 追加讨论：SAF 场景下增量扫描具体怎么做（2026-08-14 续，仍是 backlog，纯记录不实施）

用户追问链：MediaStore 的 `GENERATION_MODIFIED` 系统侧到底怎么维护的→
我们自己数据库能不能做类似的事→用户删文件能不能感知到→这样是不是
就变成跟 Desktop 一样监听文件目录而不是相册了。

**MediaStore 内部机制**（Android 平台架构公开说明，非本仓库代码）：
scoped storage（API 29+）下，DCIM/Pictures 等目录的读写要经过
`MediaProvider` 自己操作的 FUSE 文件系统层——任何 App（含系统相机）
的增删改都"过它的手"，同一事务里顺手把该行的 `generation` 计数器
加一。但**暴露给普通 App 查询的 API 把这些操作类型全部抹平**：只有
「每行一个版本号」+ 可选的 `ContentObserver`「门铃」（只说"这个 URI
范围有动静"，不说哪一行/什么操作）。改名/移动表现为"同一 `_ID`
字段变了"，删除**没有事件**，靠"这个 `_ID` 上次查得到这次查不到"
的缺席推断——这正是我们自己 `MediaScanner.kt::allItemUris()`
（PERF-01 孤儿清理）已经在用的手法。

**桌面这边验证过同一套哲学，不是另起一套**：`crates/daemon/src/watcher.rs`
用 `notify` crate（FSEvents/inotify），**能**拿到带类型的
Create/Modify/Remove/Rename 事件，但代码注释明确写着不信任这些类型
当真相——"事件只是触发器，扫描读取「当前真相」"；删除具体走
`reconcile.rs` 的"局部对账"（DB 记录 vs 磁盘实际比对），原因是
Linux 实测 Access 事件风暴会淹没真正的 Remove 事件。

**如果 SAF 路线要做增量扫描，设计骨架是**：
1. **能力上没有疑问**：`DocumentFile.listFiles()` 全量列举（名字/
   大小/mtime）是成熟、有文档保证的能力，跟本卡"变化通知是否可靠
   触发"那个悬而未决的问题不是一回事——列目录这件事本身没有不确定性。
2. **自建增量表**：每次扫描拿到当前完整清单，跟本地持久化的"上次
   已知清单"做 diff——多了=新增，size/mtime 变了=修改，上次有这次
   没了=删除（缺席推断，跟 `allItemUris()`/`reconcile.rs` 同一手法，
   删除**可以**检测到，只是不是"实时监听"，是"下次扫描时发现"）。
3. **调度只能是时间驱动的兜底轮询**：`WorkManager.PeriodicWorkRequest`
   平台硬下限 15 分钟一次（我们自己 `BackupWorker.kt` 的
   `CONTENT_MAX_DELAY_MS` 已经是这个数字，只是那里是 content-trigger
   的兜底上限，SAF 场景下会变成主力周期）。
4. **架构收敛**：范围单位从"MediaStore 相册"变成"一棵文件夹树"，
   跟桌面 `watcher.rs`+`reconcile.rs` 的模型（实时 watcher 触发 +
   定期全量兜底）概念上可以直接照搬，这一步用户的判断是对的。

**但不是无代价的平级替换，有一个关键的未决分叉，决定这条路线是
"打平"还是"退步"**：
- 如果 SAF tree 的 `ContentObserver` **能**可靠收到第三方 App（系统
  相机等）写入的变化通知 → 事件驱动为主 + 周期扫描兜底，跟今天
  MediaStore content-trigger 的架构对等，效率不受影响。
- 如果**不能**可靠触发 → 只能靠 15 分钟一次的盲扫轮询当主力（不是
  兜底），相比今天"系统真的有变化才叫醒你"是明确的电量/时效倒退。
- 这个分叉目前没有查到确定答案，**必须靠真机测**（同款方法：
  另一个 App 或系统相机往已授权的 SAF 文件夹写新文件，看
  `ContentObserver` 回调是否触发），文档调研到此为止，不能再网上
  查出结论。

下一步讨论/排期时，这是要先定的第一个问题：值不值得花一次真机测试
去解决这个分叉，还是先假设"退步"去做成本评估。
