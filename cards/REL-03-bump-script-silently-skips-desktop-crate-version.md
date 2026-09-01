# REL-03 bump-version.sh 静默跳过桌面 crate 版本，漂移断言看不见　级别 L2

> 🟠 状态：进行中（批次 A）· 协同分支：`batch/rel-03`
> 级别：L2 · 阻塞：无

## 问题

`tools/bump-version.sh` 声称同步「桌面四件套」，但其中一件会**静默跳过**。

第 90 行用 `$DCUR`（= `tauri.conf.json` 里读出的版本）去匹配
`src-tauri/Cargo.toml`：

```bash
sed -i.bak "s/^version = \"$DCUR\"/version = \"$NEW\"/" apps/desktop/src-tauri/Cargo.toml
```

而第 43 行的漂移断言只检查 **`tauri.conf.json` == 主仓 Cargo.toml**，
`src-tauri/Cargo.toml` 不在断言范围内。于是一旦后者独立漂移，`sed` 的模式
就永远匹配不上 → **静默 no-op**，而脚本尾部的「tree clean（version files
only）」断言只验「没碰到不该碰的文件」，不验「该碰的都碰了」，照样报 ok。

实测（2026-08-25，bump 到 `0.4.0-test.1` 时发现）：

```
Cargo.toml (主仓)              0.3.3          → 0.4.0-test.1  ✅
tauri.conf.json                0.3.3          → 0.4.0-test.1  ✅
apps/desktop/package.json      0.3.3          → 0.4.0-test.1  ✅
apps/desktop/src-tauri/Cargo.toml   0.2.1     →   0.2.1       ❌ 静默跳过
```

`0.2.1` 是上一次 `DOG-01d` 那轮的值——**脚本要防的就是这个 bug（注释原文
「DOG-01d 姊妹 bug：桌面卡 0.1.0 而主仓已 0.2.1」），它自己又犯了一次，
而且悄无声息地犯了好几个版本。**

## 期望行为

- 「该改的都改了」也要被断言，不只断言「没改错」。任一目标文件的版本
  在 bump 后不等于 `$NEW` → **脚本失败退出**，不许报 ok。
- 每个目标文件的当前版本独立读取，不共用 `$DCUR` 一个值去匹配所有文件
  （共用是本 bug 的根因：一处漂移就让 sed 对该文件永久失效）。

## 验收标准

- [ ] 反证：故意把 `src-tauri/Cargo.toml` 的 version 改成任意不同值 →
  跑 `bump-version.sh` → **脚本报错退出**（当前实现会报 ok）
- [ ] 正例：四件套 + 主仓 + Android 全部同步到 `$NEW`，`git diff` 仍只含
  版本号行
- [ ] `p-pass-desktop` 在 `src-tauri/Cargo.lock` 里的版本同步跟上
- [ ] 断言覆盖 Android 两项：`versionName` 的硬编码回落值（当前
  `build.gradle.kts:25` 是 `?: "0.3.5"`，与主仓版本无关地钉着）要么纳入
  同步、要么在卡里明确记为「刻意不同步」并写明理由

## 范围

- 只准动：`tools/bump-version.sh`
- 不准动：各文件里的版本号本身（那是脚本的输出，不是本卡的手工活）

## 阻塞与依赖

无。

---

## 备注

发现经过：2026-08-25 按用户要求出 `0.4.0-test.1` 测试版，bump 后核对各文件
时发现桌面 crate 还停在 `0.2.1`。本次已手工对齐（`src-tauri/Cargo.toml`
+ `cargo update -w` 同步 lock），**但脚本的盲区没修**，故开卡。

影响面（如实评估，不夸大）：`tauri.conf.json` 才是 bundle/About 对话框和
Tauri updater 读的那一份，**用户看到的版本号一直是对的**；漂移的是桌面壳
Rust crate 的元数据版本。所以这不是「用户装了 dmg 看到旧版本」那级事故，
但它是**同一个盲区**——下一次漂移的可能就是 `tauri.conf.json` 之外的哪一件。

## 追加（2026-08-26 出 test.9 时发现）：第七处版本号，脚本同样不碰

`apps/android/app/build.gradle.kts:25` 的**非 tag 回退版本号**钉着字面量：

```kotlin
versionName =
    System.getenv("PPF_BUILD_VERSION")?.takeIf { it.isNotBlank() }?.removePrefix("v")
        ?: "0.3.5"
```

`bump-version.sh` 只改 `versionCode`，这个回退串从 0.3.5 之后就没人动过。

- **tag 构建不受影响**（`PPF_BUILD_VERSION` 由 release.yml 注入）。
- **狗粮/本地构建会报错版本**——`artifacts.yml` 的 Dogfood Binaries 不打 tag，
  装出来的 APK 自称 0.3.5。这与验收人 2026-08-19 那句「下载的安装包为啥是
  0.3.0 的？！」是同一个形状的坑。

修法与本卡主体一致：要么让 bump 脚本也改这一处，要么让回退值从**单一真相**
（workspace 版本）派生，别在第七个地方抄同一个数。本卡的尾部断言（「没有改到
不该改的文件」）照旧抓不到「该改的没改」——那是本卡的核心教训。
