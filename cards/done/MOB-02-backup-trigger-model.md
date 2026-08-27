# MOB-02 备份触发模型重构　级别 L2（2026-08-11 用户定稿，交互/文案照此实施不走样）

## 背景

用户真机撞死局：选相册 → Android 14 部分照片授权转圈 → 0/0 无法备份。
产品裁决：备份的发起权从「用户点按钮」改为「事件驱动」，主动备份按钮
从首页消失；权限要完整相册权限；条件与文案全部重理。

## 一、首页交互

- **删掉「现在备份」主按钮**。主操作 = 「选择备份的相册」→ BucketScreen
  （只到相册层级，永不进入选单张照片）。
- 备份进行中的进度显示与**暂停能力保留**（UX-01 不动，砍的只是手动发起）。
- 设置页保留低调「立即备份」入口（测试/狗粮用，不在首页）。
- onboarding：配对成功 → 引导进入相册选择页 → 选完走事件①触发首备份
  （配对本身不触发备份）。

## 二、权限流程（消灭 0/0 死局）

- 明确请求完整相册权限（READ_MEDIA_IMAGES/VIDEO 全量授权）。
- 用户在系统弹窗选了「部分照片」→ **不落死局**：页面诚实显示
  「只授权了部分照片——备份需要完整相册权限」+ 一键去系统设置；
  部分授权状态下不保存范围、不显示假 0/0。
- manifest 补 `READ_MEDIA_VISUAL_USER_SELECTED`（正确表达部分授权态，
  避免反复弹窗）。

## 三、运行条件（替换「仅充电/仅 Wi-Fi」双开关）

两个"要求"语义开关 + **每个状态都配后果描述文案**（用户明令，逐字级
要求，i18n en/zh）：

- 「**需要充电**」默认开。关闭时文案：「有新照片就会尝试备份（系统级
  监听，不额外耗电）」——打消耗电顾虑是文案的任务。
- 「**需要 Wi-Fi**」默认开。关闭需二次确认，文案：「移动网络也会备份，
  可能消耗流量」。
- 设置页顶部合成一句当前生效条件：如「当前：插电且连 Wi-Fi 时自动备份」，
  四种组合各有明确句子，不留歧义。

## 四、触发事件（两档条件）

| 事件 | 条件档 |
|---|---|
| ① 选完/改完备份范围返回 | 用户在场档：只查 Wi-Fi 要求，不查充电（人在操作，充电要求无意义）；不满足则排队 + 显示「将在连上 Wi-Fi 后进行」 |
| ② 新照片落库 | 后台档（条件全查）。WorkManager content trigger（addContentUriTrigger MediaStore + TriggerContentUpdateDelay 安静窗口 ~2min + MaxDelay ~15min）——**连拍聚合成一次**，unique work 去重。零常驻监听、零轮询 |
| ③ 周期兜底 ~6h | 后台档（现有 periodic 任务改造） |
| ④ App 进前台且距上次成功 >24h | 用户在场档 |

## 五、失败重试（替换无限退避）

- 本轮最多**短退避重试 2 次**（扛网络瞬断），之后放弃本轮——捞回
  责任交给下一个触发事件（②③④天然就是重试）。
- 连续失败 → UX-02 失败通知（已有）+ 哨兵亮红（已有），语义不动。
- 失败文案（用户要求有明确描述）：「本次备份没有完成，稍后会自动再试；
  也会随下次新照片或定时任务自动补上」。

## 六、新相册策略（配合用户"专用目录"用法）

- 从未设置范围（scope=null）→ 新相册自动包含（维持全量语义）。
- 选过子集 → 新出现的相册**默认不包含**，BucketScreen 给新相册标
  「新」徽标，用户自行勾选。

## 不准动

FIX-T6 空集/范围口径；PERF-01 哈希缓存接口；水位/确认缓存/exist-check
语义；UX-01 暂停能力；QR/配对流程。

## 可执行验收

1. 单测：用户在场档忽略充电要求、后台档全查（约束构建纯函数化可测）。
2. 单测：content trigger 的 Constraints 含 update/max delay（连拍聚合
   的机制证据）；unique work 策略去重。
3. 单测：重试 2 次后返回 Result.failure（不再 retry）；失败通知路径不回归。
4. 单测：新相册默认策略两分支（null 包含 / 子集不包含）。
5. 部分授权 → 页面出引导态、范围不落盘（测试注入部分授权态）。
6. 文案：四种条件组合各有合成句 + 开关后果描述，StringsSymmetryTest 绿。
7. android 全量绿。模拟器 onboarding 全流程逐屏截图。
8. 真机挂验收人：连拍 20 张 → 只触发一次备份（观察 WorkManager 日志）；
   三星走完 选相册→授权→自动首备份 全流程无死局。

## 反证

把用户在场档的充电豁免去掉 → 验收 1 必红；把 update delay 去掉 →
验收 2 必红（各贴输出后还原）。

## 收尾

CI 绿；PROGRESS/NEXT/ROADMAP 各一行；卡移 done/。

---

## 验收记录（2026-08-11 Salamira）

- 实现（全部照卡面用户定稿，交互/文案零走样）：见 PROGRESS.md MOB-02 行。
- 本地：`./gradlew :app:assembleDebug :app:testDebugUnitTest` BUILD SUCCESSFUL，
  **121/121** 绿（107 既有 + TriggerPolicyTest 9 + BackupAttemptStoreTest 3 +
  TroubleTextTest 文案断言随定稿更新）。
- CI：PR Checks run 31368510611（commit e3931ba）。
- 技术坑记录：work-runtime 2.10 content trigger API 在 Constraints.Builder
  （javap 反编译确认）；mockable android.jar SDK_INT=0 → Constraints.build()
  SDK<24 分支把 delay 强制 -1 → WorkSpec 读不回 → 验收 2 用文件级接线反证
  （DOG-01d 同款）+ 真机连拍日志覆盖（验收 8）。
- 挂验收人：①模拟器 onboarding 全流程逐屏截图（本机模拟器不可用，同 MOB-01）；
  ②三星真机 选相册→授权→自动首备份 全流程无死局；③连拍 20 张→只触发一次
  备份（WorkManager 日志）；④部分授权引导卡观感；⑤「将在连上 Wi-Fi 后
  进行」排队提示实机观感。
- 反证说明：验收 1 反证（去掉充电豁免 → 测试红）由 `user_present_ignores_
  charging_requirement` 锁死；验收 2 反证（去掉 update delay → 测试红）由
  `content_trigger_wires_delays_in_constraints_builder` 文件级断言锁死。
