# I18N-02 主 Android Kotlin 残留中文硬编码清理（L1）

> ✅ 状态：完成（2026-09-08）
> 当前节点：三处主 Kotlin 文件的用户可见中文已迁入对称 en/zh 资源并通过验证；下一步：无。
> 协同分支：`batch/i18n-02`
> 级别：L1 · 前置：I18N-01 代码已在 main，英文系统真机验收不阻塞本卡开发

## 问题

I18N-01 的空相册名兜底已从数据层移到资源，但其原“主 Kotlin 非注释行不得含中文”验收发现 `MainActivity.kt`、`PairFlow.kt`、`BackupWorker.kt` 存在既有中文硬编码。它们不属于空相册卡的范围，却会在非中文系统中漏出中文。

## 期望行为

这些用户可见文本全部进入 en/zh 资源，数据/日志/注释不受无关改动。

## 验收标准

- [x] 逐处确认是用户可见文本，不把日志、测试或注释误迁。
- [x] 对应 en/zh 资源对称，Android i18n 测试通过。
- [x] 反证：删除任一新增 key 的一侧翻译，资源对称测试必须变红。

## 范围

- 只准动：上述三个主 Kotlin 文件中的用户可见中文、对应 strings 资源与测试。
- 不准动：I18N-01 已完成的空相册数据语义、备份行为或其他业务文案。

## 阻塞与依赖

无。

---

## 实施记录（2026-09-08）

- 逐处走查确认：`MainActivity.kt` 的更新提示四处、`PairFlow.kt` 的配对失败/不可解析/存储端默认名三处属于用户可见文案；`BackupWorker.kt` 无用户可见中文。日志、注释、测试数据与备份行为未迁移。
- 新增 `StringsSymmetryTest.main_kotlin_has_no_chinese_outside_comments`，先以现有硬编码运行并按预期失败（MainActivity 4 处）；补齐 `values/` + `values-zh/` 后通过。资源键集对称反证仍由同一测试覆盖：任一侧删除新增 key 会失败。
- 验证：Android JVM `:app:testDebugUnitTest --tests ...StringsSymmetryTest` **3 tests / 0 failures / 0 errors**；全量 `:app:testDebugUnitTest` **309 tests / 0 failures / 0 errors / 4 ignored**（fresh XML）；`just ci` 全绿（fmt、clippy、nextest、arch-check、queue-check）。
