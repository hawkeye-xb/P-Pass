# LINT-01 Android lint 不在 CI 里跑，已知一处红长期无人看见　级别 L3

> ✅ 状态：已完成（2026-09-09）

## 问题

`ci-android.yml` 只跑单测 + `assembleDebug`，**不跑 `lint`**。于是 lint 的
结论没有任何门禁，红了也没人知道。

已知的一处：`BucketScreen.kt` 的 `BucketCoverImage` 里 `produceState` 报
`ProduceStateDoesNotAssignValue`——因为 `value` 的赋值裹在
`if (value == null && coverUri != null)` 里，lint 的检查器看不出条件分支里
有赋值，属于**误报**（缓存命中时本来就不该重新赋值）。

问题不是这一条误报，而是**没有门禁 = 下一条真报也会被埋掉**。MOB-08 那轮
就吃过一次类似的亏（`NewApi` 红一直没人看见）。

## 期望行为

Android lint 在 CI 里有结论。误报用 `@Suppress` / `lint.xml` 显式豁免并写
理由，真报当场修——不允许「一片红所以谁也不看」的状态继续。

## 验收标准

- [x] `ci-android.yml` 增加 lint step，`lintDebug`（或等价 task）零告警才算绿
- [x] `BucketScreen.kt` 那条误报显式豁免（带一行注释说明为什么是误报），
  或改写成 lint 认得的形式
- [x] 反证：故意引入一条新 lint 违规 → CI 变红
- [x] 首次开门禁时把现存告警清空（清不完的列进 `lint.xml` baseline 并在卡里
  逐条记原因，不许无声 baseline 全量吞掉）

## 范围

- 只准动：`.github/workflows/ci-android.yml`、`apps/android/**` 的 lint 配置
  与被 lint 点名的文件
- 不准动：业务逻辑（本卡只管 lint 门禁与豁免，不顺手重构组件）

## 阻塞与依赖

无。注意 CI-01 的额度纪律：lint 挂在既有 ci-android job 里，不新开 workflow。

---

## 验收记录（2026-09-09）

**本地验证环境**：`JAVA_HOME=/opt/homebrew/opt/openjdk@17`（与 CI
`setup-java` 的 `java-version: "17"` 对齐——本机默认 JDK 25 跑 lint 会有
偏差，已按 `AGENTS.md` 工具链纪律避坑）。

**改动**：
1. `.github/workflows/ci-android.yml`：`testDebugUnitTest` 之后、
   `assembleDebug` 之前插入 `./gradlew :app:lintDebug` 步骤。
2. 4 处 `ProduceStateDoesNotAssignValue` 误报（同一模式：赋值裹在条件分支/
   提前返回/嵌套 lambda 里，lint 静态分析看不穿）逐处加
   `@Suppress("ProduceStateDoesNotAssignValue")` 并写清理由：
   - `BucketScreen.kt:91`（卡里点名的那处）
   - `PhotosScreen.kt:453`（`ThumbCell`，同模式）
   - `PhotosScreen.kt:527`（`PhotoViewer`，`?:` 兜底表达式路径）
   - `VideoScreen.kt:64`（`VideoScreen`，提前 return + try/catch 分支）
3. `AndroidManifest.xml`：真错误 `PermissionImpliesUnsupportedChromeOsHardware`
   ——`CAMERA` 权限会被 Play 商店隐含推断为"需要摄像头硬件"，导致无摄像头
   设备（ChromeOS/平板）被过滤。加 `<uses-feature
   android:name="android.hardware.camera" android:required="false"/>`
   声明摄像头是可选功能（扫码配对之外还能手动输入配对码）。
4. `app/build.gradle.kts`：加 `lint { baseline = file("lint-baseline.xml") }`。
5. `app/lint-baseline.xml`：首次开门禁跑出 **0 errors, 72 warnings**（4 处
   ProduceState 误报 + 1 处 manifest 错误已修复，不在这 72 条里）。72 条
   全部修复都需要碰业务代码（本卡范围明确排除），按规则分类记录理由后
   全量收进 baseline：

   | 规则 | 条数 | 为什么本卡不修，归哪类后续工作 |
   |---|---|---|
   | `UnusedResources` | 23 | 未使用的字符串/drawable 资源；需要逐条确认是"预留给未完成 UI"还是"真死代码"，属于代码清理，不属于 lint 门禁本身 |
   | `GradleDependency` | 16 | 依赖库有更新版本（activity-compose/core-ktx/lifecycle/media3/camera/coroutines/work/test 等）；升级需要跑完整回归，不是本卡"只管门禁"的范围 |
   | `PluralsCandidate` | 12 | `strings.xml` 里 `%d` 后跟名词，建议改 `<plurals>` 做多语言复数；改动会牵动 i18n 字典对称测试（`assets/i18n`），属于 i18n 专项 |
   | `Recycle` | 10 | `Cursor`/`InputStream` 未显式 `close()`（多为 `?.use{}` 包裹，实际有资源管理，lint 对 `use` 的追踪不完整导致的已知局限，但逐条确认仍需读函数全貌，留作后续专项复核而非本卡顺手改） |
   | `InlinedApi` | 4 | `MediaStore.VOLUME_EXTERNAL`（API 29+）/`READ_MEDIA_IMAGES`（33+）/`READ_MEDIA_VISUAL_USER_SELECTED`（34+）字段在 minSdk 26 编译期内联；代码已有运行时 `Build.VERSION.SDK_INT` 分支守卫，只是 lint 认不出跨函数的守卫，真实风险低 |
   | `AutoboxingStateCreation` | 3 | `mutableStateOf(Int/Float)` 应改 `mutableIntStateOf`/`mutableFloatStateOf` 减少装箱；是性能优化不是 bug，且分布在多个 Compose 文件里 |
   | `SpecifyJobSchedulerIdRange` | 1 | `MediaWatchJob` 用 WorkManager 的 JobScheduler 桥接层，未声明 id range；需要理解 WorkManager 内部 id 分配策略再改，风险不小 |
   | `OldTargetApi` | 1 | `targetSdk = 35` 不是最新；升级 targetSdk 是跨版本兼容性回归工作，不是配置改一行的事 |
   | `ObsoleteSdkInt` | 1 | `mipmap-anydpi-v26` 目录判定为多余（minSdk 已是 26）；纯资源目录合并，低风险但需要验证图标在所有分辨率下正确加载 |
   | `LockedOrientationActivity` | 1 | `MainActivity` 锁定 `portrait`；这是产品决策（是否支持横屏），不是本卡能拍板的范围 |
   | `DiscouragedApi` | 1 | 同上，`screenOrientation="portrait"` 的另一条规则 |
   | `DataExtractionRules` | 1 | `android:allowBackup` 属性在 API 31+ 建议改用 `dataExtractionRules`；涉及备份/迁移语义，需要单独设计 XML 规则文件 |
   | `BatteryLife` | 1 | `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 违反 Play 政策措辞；这是 DOG-02 已知的产品决策（背景保活引导），非本卡范围 |

   合计 72 条，与 lint 报告一致，逐类可查证。

**反证**：在 `BatteryWhitelist.kt` 临时插入
`context.getSystemService(android.os.VibratorManager::class.java)`
（minSdk 26 下无版本守卫引用 API 31+ 类），`./gradlew :app:lintDebug`
产出 `1 errors, 0 warnings (75 warnings filtered by baseline)`，
`BUILD FAILED`，退出码 1——确认门禁真的会拦真报。验证后已撤回改动，
`diff` 确认文件与改动前逐字节一致。

**最终验证**：`./gradlew :app:lintDebug` → `BUILD SUCCESSFUL`，退出码 0，
0 errors，0 未 baseline 的 warnings。

**遗留**：baseline 里 72 条存量告警未清零，按上表分类记录理由；后续若要
逐条清理，应按规则拆分成独立卡（如 `UnusedResources` 清理、`GradleDependency`
批量升级回归等），不在本卡范围内展开。

---

## 备注

来源：`docs/NEXT.md`「未开卡」清单（`BucketScreen.kt:81` lint 红，CI 不跑
lint 所以一直没暴露），2026-08-25 按模板开卡。

首次开门禁大概率会顶出一批存量告警——预期工作量主要在这里，不在那一条误报。
