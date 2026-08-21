# BUILD-01 本地 JDK 25 让 Android release 构建挂在 lint　级别 L3

> ⛔ 未实施，**范围已按用户定调收窄**（2026-08-21：「构建的任务和需要的账号
> 证书都只在 GitHub，本地能跑的就跑就好了」）。
>
> 所以本卡**不再包含**「让本地能出可安装的 release 包」——那本来就该由 CI 出。
> 剩下的目标只有一条：**别让 JDK 版本漂移把本地跑得动的东西（debug 构建 +
> 单测）搞坏，且报错要是人话**。不影响 CI（CI 钉 JDK 17）。

## 现场

```
$ JAVA_HOME=$(brew --prefix openjdk) ./gradlew :app:assembleRelease
Execution failed for task ':app:lintVitalAnalyzeRelease'.
> A failure occurred while executing AndroidLintWorkAction
   > 25.0.1                        ← 这不是错误码，是 **Java 版本号**
BUILD FAILED
```

`brew --prefix openjdk` 指向 **openjdk 25.0.1**（本机只装了 `openjdk` 和
`openjdk@25`，没有 17）。AGP 的 lint 吃不下 JDK 25，异常信息里只吐一个版本号，
**看着完全不像版本问题**。

CI 不受影响：`ci-android.yml` 用 `setup-java` 钉了 `java-version: "17"`。
debug 构建与单测在 JDK 25 上也正常 —— **只有 release 的 lintVital 会炸**。

## 为什么要修（不只是"我本地跑不了"）

`justfile` 的 `android-test` 写死了 `JAVA_HOME=$(brew --prefix openjdk)`，
也就是**本地工具链跟着 brew 的最新版漂**。今天是 lint 炸，下次 brew 升到 26
可能是别的东西炸，而且报错依然会长得像别的问题（今天这条我第一眼当成了
签名配置缺失）。本地与 CI 的 JDK 不一致，本身就是"本地绿 CI 红"和
"CI 绿本地红"两个方向的坑。

## 候选改法（没定）

1. **`justfile` 钉版本**：`JAVA_HOME=$(/usr/libexec/java_home -v 17)`，
   并在 README/贡献文档写明需要 `brew install openjdk@17`。与 CI 对齐，
   最直接。代价：多一个安装步骤。
2. **加一条本地前置检查**：`just` 跑 Android 相关 recipe 前先断言 JDK 主版本
   ∈ {17, 21}，不匹配就明确报「装 openjdk@17」，而不是让 AGP 吐一个 `25.0.1`。
3. 什么都不改，只在文档里记一笔本地 release 构建要加
   `-x lintVitalAnalyzeRelease -x lintVitalRelease`。**治标**，而且下一个人
   照样会浪费半小时。

**倾向 1 + 2**（钉版本 + 前置检查给人话）。

## 顺带记录：本地正式构建的当前状态

| 平台 | 产物 | 状态 |
|---|---|---|
| macOS | `apps/desktop/src-tauri/target/release/bundle/macos/P-Pass.app` | ✅ 出得来。内置 `ppf-daemon` 已核对含 MOB-32 + DESK-08 的代码。updater 的 `.tar.gz` 签名步报错（`TAURI_SIGNING_PRIVATE_KEY` 缺失）——**无凭据路径，release.yml 上同样跳过**，不影响 `.app` 本身 |
| Android | `app/build/outputs/apk/release/app-release-unsigned.apk` | ⚠️ 绕开 lint 才出得来；且**未签名**，装不上真机。正式真机测试继续用 debug APK，或由 CI 的 release.yml 出签名包 |

## 2026-08-21 补记：同一个病在 Rust 侧真的咬了

本卡开出来几小时后，**Rust 侧出了同形事故的反方向**：本地 stable 停在
1.91.0、CI 的 stable 已到 1.98.0，`just ci` 本地全绿而 CI 上 clippy 直接红
（1.98 新增的 `chunks_exact_to_as_chunks`，本地根本没这条 lint）。

| | 本地 | CI | 症状 |
|---|---|---|---|
| Rust | 跟着 rustup stable 漂（停在 1.91） | 浮在最新 stable（1.98） | **本地绿 CI 红** |
| JDK | 跟着 `brew --prefix openjdk` 漂（25） | 钉 `java-version: "17"` | **本地红**（本卡） |

**两个方向都出过事。** 所以结论不是"本地要跟上 CI"，而是
**工具链版本必须有唯一真相，且两侧都从它取**。

Rust 侧已经钉了 `rust-toolchain.toml` → `1.98.0`；CI 侧能不能钉住另开
`BUILD-02`（`dtolnay/rust-toolchain` 是否导出 `RUSTUP_TOOLCHAIN` 会盖掉 toml，
没核实过）。JDK 侧就是本卡。

## 验收要求

- 本机 `just android-test` 与 **debug 构建**能在钉住的 JDK 上跑通
  （`assembleRelease` 不在范围内——签名产物归 CI）
- JDK 不匹配时报的是人话，不是 `> 25.0.1`
- **版本号只许出现在一处**（与 `BUILD-02` 同一原则）
