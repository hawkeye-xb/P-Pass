# E2E-03 tag 触发的 Android live scenarios 缺 Android Rust target，门禁在 Gradle 预构建失败（L1）

> 🟠 状态：进行中 · 当前节点：`v0.5.0-test.1` 的 E2E #73 已复现 target 缺失；下一步：在 e2e workflow 补齐与 CI Android / release 相同的 native provider 前置，再以新 tag 复核 · 协同分支：`main`
> 级别：L1 · 阻塞：无

## 问题

2026-09-04 推送 `v0.5.0-test.1` 后，tag 触发的 E2E #73 在
`tools/android-hello.sh` 运行 `:app:testDebugUnitTest` 时失败。临时 daemon
已正常启动；失败发生在 Gradle 的 `buildIrohBlobsProviderBridge` 预构建：

```text
error[E0463]: can't find crate for `core`
note: the `aarch64-linux-android` target may not be installed
```

`ci-android.yml` 和 `release.yml` 都先执行 `rustup target add
aarch64-linux-android` 并导出 `ANDROID_NDK_HOME`；`e2e.yml` 的 Android live
job 缺少这段前置。因此 E2E 没有进入 hello/pair/backup 的真实协议断言。

## 期望行为

Android live E2E 在 Gradle 触发 native iroh-blobs provider 前，拥有与常规
Android CI、release job 一致的 Rust Android target 与 NDK 环境；失败时应来自
真实 hello/pair/backup 行为，不得因构建前置缺失而中断。

## 验收标准

- [ ] `e2e.yml` 的 Android live job 在 Gradle 场景前显式安装
  `aarch64-linux-android` 并设置 `ANDROID_NDK_HOME`。
- [ ] 推送新的 test tag 后，E2E 的 `android live (hello/pair/backup)` job 不再出现
  `aarch64-linux-android target may not be installed`，且三个脚本均运行。
- [ ] 反证：移除 target 安装步骤后，`buildIrohBlobsProviderBridge` 在干净 Linux runner
  必须重现 E0463，证明门禁真的依赖该前置。
- [ ] 相关 tag E2E 与 release 均绿后，才删除历史 test Release/tag；保留 `v0.3.1` 与
  固定 `dogfood`。

## 范围

- 只准动：`.github/workflows/e2e.yml`、本卡、`docs/QUEUE.md`、`docs/PROGRESS.md`、
  `docs/ROADMAP.md`。
- 不准动：Android Flow 生产实现、release workflow 的既有签名/发布语义、旧 test
  Release/tag（本卡验收前不删除）。

## 阻塞与依赖

无。

---

## 实施记录

- 2026-09-04：`v0.5.0-test.1` 已指向 `056dc0f` 并触发 Release #45 与 E2E #73。
  E2E #73 的 daemon 已启动，Android Gradle 在 12 秒内失败于缺 Rust target；根因不是
  daemon relay 日志，也不是 MOB-49/MOB-50 的 Flow 语义。
