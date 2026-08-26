# MOB-40 还没选相册就把整库传了——「从未选过」被当成「全量备份」　级别 L0

> 🟡 状态：代码已合并，等真机验收
> 级别：**L0**（无授权就上传全部照片，产品红线）· 阻塞：真机回归无法继续

## 问题

验收人反馈（2026-08-26 真机，0.4.0-test.6 全新安装）：

> 「我就选择了一个 11 张的相册，你给我同步几百个？又出现 bug 了，我都不用往下
> 测试了！」

## 实锤（logcat，`/tmp/ppass-logs/logcat.txt`）

```
15:47:31  卸载旧包（deletePackageX，进程 28932 被杀）
15:53:05  全新安装 0.4.0-test.6（新 uid 10365 → SharedPreferences 全空）
15:54:13  work bb407474  scanning 0/0      → 早退（尚未配对）
15:54:14  work d9b69afe  scanning 254/254  ← 全库 254 张，此刻用户还没进选相册页
15:54:15~ hashing 1…254，随后 sending
15:55:13  CANCELLED_BY_APP(1)  ← 用户看到进度不对，手动按了暂停
15:55:26  auto backup: offered=11 pushed=11  ← 选完相册后的正确一轮
```

`254` = 整库，`11` = 用户实际选的相册。**顺序错了：备份先跑，选择后到。**

## 根因

一条语义：`BackupScopeStore.selectedBucketIds()` 返回 `null` 表示
「**从未选过范围**」，而全链路把它解释成「**全量备份**」。

- `BackupScopeStore.kt:15` kdoc：`null = everything (never scoped)`
- `MediaScanner.scanSince`：`bucketIds` 为 null 时不拼 `BUCKET_ID IN (…)` → 全库
- `BackupWorker.kt:515-520`：只对**空集**早退（`KEY_NO_ALBUMS`），null 直穿

这条兼容语义是 T6 给「升级上来的老用户」留的。代价在这次真机上兑现了：
**「我还不知道你要备什么」被当成「那就全备」。** 一个备份产品最不该做的
默认动作，就是在没拿到用户选择之前把整个相册库传出去。

触发时机有两条路，都不带「已选范围」这道门：

1. `MainActivity.kt:448` —— 配对成功当场调 `scheduleAutoBackup`，
   而 `enqueueAutoBackup` 的 `PeriodicWorkRequest` **没有 initialDelay**，
   首轮立即执行。这就是 15:54:14 那一轮。
2. `MainActivity.kt:191-199`（MOB-38 的 `foregroundCatchup`）—— 门控只有
   「已配对 + 未暂停」。配对后任何一次 ON_RESUME（选相册页上弹权限对话框
   回来就是一次）都会 `triggerUserPresentBackup`，USER_PRESENT 档只查
   Wi-Fi，立即开跑。

## 决策：修在管线咽喉，不是逐个堵触发通道

备份有五条触发通道，MOB-39 的触发层重构还没做。**在每条通道上各加一道
「选过范围了吗」，就是把同一个门控写五遍**——MOB-33/34/35/38 四个 bug 全是
「漏接一处」，这个形状不能再复制。

闸门放在 `BackupWorker.runBackup` 读取范围的那一处：**`null` 一张都不备。**
不管谁触发、什么档位，都过这一道。

`null` 与空集的**行为**从此相同（都不备），但**盖戳分开**——诊断时要能
区分「用户从没选」和「用户全取消了」。UI 文案两者共用现有的
`state_no_albums`（「没有可备份的相册（一个都没选）」对两种情形都是实话，
出路也相同：去选相册），不新增状态、不新增字符串。

## 要做的

1. `BackupWorker.kt`：`bucketIds == null` → `successStamped(KEY_NO_SCOPE to true)`，
   独立常量 `KEY_NO_SCOPE`。不推水位、不进扫描。
2. `BackupUiStateHolder.kt`：`KEY_NO_SCOPE` 与 `KEY_NO_ALBUMS` 同映射到
   `BackupUiState.NoAlbums`（**不许**落到「已备份 0 张」那条分支）。
3. `MainActivity.kt:696`：`prevScope == null → added = sel`。新语义下
   「从未选过」的首次选择就是**全部新增**，按 MOB-20 的规矩应归零水位；
   旧代码 `added = emptySet()` 是旧语义（null 已经全备过了）的残留。
4. `MainActivity.kt:201-208`：MOB-38 重构掏空的空 `if` 尸体，删掉
   （`wifiDeferred = false` 那行保留）。

## 验收标准

- [x] 单测：`bucketIds == null` 时 worker 早退且盖 `KEY_NO_SCOPE`，**不扫描**
- [x] 单测：`KEY_NO_SCOPE` 的终态 → `BackupUiState.NoAlbums`（不是 AllSafe / Idle）
- [x] 单测：首次选择（`prevScope == null`）→ 水位归零
- [x] **反证**：把 null 的早退去掉 → 上面第一条变红（真跑，红输出进卡）
- [ ] 真机（**留给验收人**）：卸载重装 → 配对 → 选那个 11 张的相册 →
      **全程只传 11 张**，配对到选择之间一张都不传

## 不准动

- MOB-36 的范围补齐（`scanScopeBelow` 对 null 已经是零成本早退，语义一致）
- MOB-38 的 `foregroundCatchup`（门控收拢归 MOB-39；管线闸已经覆盖它）
- `MainActivity.kt:448` 的提前挂周期任务（管线闸之后它只是空转一轮）

## 实施记录

**改了四处**（与卡面 1-4 一一对应）：

1. `BackupWorker.kt` —— 新常量 `KEY_NO_SCOPE`；`bucketIds == null` 在
   `scanner.scanSince` **之前**早退并盖戳。空集那条早退原样保留（判据从
   `bucketIds != null && isEmpty()` 简化成 `isEmpty()`，null 已在上面拦掉）。
2. `BackupUiStateHolder.kt` —— `KEY_NO_SCOPE` 与 `KEY_NO_ALBUMS` 同映射到
   `BackupUiState.NoAlbums`，不落 AllSafe 分支。
3. `MainActivity.kt` —— `prevScope == null → added = sel`（首次选择归零水位）。
4. `MainActivity.kt` —— 删掉 MOB-38 重构掏空的空 `if` 尸体。

**新测试** `NoScopeNoBackupTest`（6 条）。钉的都是不变量：

- 早退语句的位置在 `scanner.scanSince(` **之前**（不钉判据的字面写法）
- 五个 trigger 函数体内一个都不许读 `selectedBucketIds`（防「堵五个通道」复发）
- `KEY_NO_SCOPE` 的终态 → `NoAlbums`（真 `WorkInfo`，不是源码断言）
- 两个戳是不同的 key（盖戳分开的全部意义）
- 首次选择 → 差集 = 全选中集 + 水位归零

**顺带修掉一条自钉字面的旧测试。** `OneBackupPipelineTest
.an_empty_album_scope_never_says_all_safe` 原本断言
`contains("if (bucketIds != null && bucketIds.isEmpty())")`，理由写着
「null = 全量语义，不是没选」——而「null = 全量」正是本卡定性为 L0 缺陷
并删掉的那条语义。那个断言只是把缺陷钉住，一点东西也没守住。改成钉
「空集的早退也在扫描之前」。

**测试计数**（XML `apps/android/app/build/test-results/testDebugUnitTest/`，
时间戳 16:08:45）：**45 类 / 340 tests / 0 failures / 4 skipped**
（基线 44 / 334 → +1 类 +6 测试）。`:app:assembleDebug` BUILD SUCCESSFUL。

**反证真跑过**——把 null 早退去掉、完整退回修复前的
`if (bucketIds != null && bucketIds.isEmpty())`：

```
NoScopeNoBackupTest > a_null_scope_never_reaches_the_scanner FAILED
    java.lang.AssertionError at NoScopeNoBackupTest.kt:62
340 tests completed, 1 failed, 4 skipped
```

（第一次反证时直接删掉那段，`bucketIds.isEmpty()` 因空安全**编译失败**——
类型系统本身就拦住了退化。为了拿到真的测试红输出，改成完整复现旧代码。）

**顺手开了 `MOB-41`**：重传提示发在范围过滤之前——清理这 243 张范围外的
照片时，每轮校准都会弹一条「正在重传」然后什么也不传。

### 收尾补一处（同一语义的另一半）

`BackupUiStateHolder.computeTripletSafe` 把范围直接喂给
`MediaScanner.countAll`，而 `countAll(null)` 是**全库**口径。修完 worker 之后
两边一拼就出现一条新的假话：范围为 null 时三元组按全库算出 N=254 / M=0 →
`statusLineOf` 走 `Pending(254)`，状态条挂着「还有 254 张待备份」而 worker
一张都不传，**永不收敛**。

可达路径：配对 → 进选相册页 → 部分授权（`MOB-02 §二` 不保存范围，直接回
Home）→ 范围仍是 null。

出口取 `DOG-01c/d` 的同一个退化点：**没选过范围 → 三元组不显示**。还没告诉
我要备什么，我就报不出待备份张数。加一条测试钉「范围检查排在 `countAll`
之前」。

最终计数：**45 类 / 341 tests / 0 failures**（XML 16:14:56）。
