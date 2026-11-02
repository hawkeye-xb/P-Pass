# 开发版与正式版同机并存

- 状态：提议（待验收人拍板）
- 日期：2026-11-02
- 涉及：身份、签名校验（#1115）、配对协议、更新链——全部属于核心（`.github/core-paths.txt`）

## 结论

1. **开发版是一个独立的产品身份，不是正式版的一种运行模式。** 每端所有「身份项」（bundle id、
   服务名、数据目录、钥匙串条目、IPC 端点、ALPN……）在开发版里统一加 `.dev` / ` Dev` 后缀，
   由**一处常量表**派生，两版装在同一台设备上，系统层面就看到两个互不相干的 App。
2. **变体在编译期决定，用 `--cfg ppf_dev`，不用 cargo feature。** 正式版构建里不存在开发版的
   任何常量与放宽路径；Linux CI 的 `--all-features` 也打不开它（tokio 的 `--cfg tokio_unstable`
   是同一做法）。
3. **隔离的硬边界是 ALPN**：开发版用 `ppf-dev/ctrl/1`、`ppf-dev/blobs/1`。QUIC 握手阶段就谈不拢，
   任何配对入口、任何应用层代码都绕不过。配对 PAKE 的上下文串也带变体，作为第二道。配对链接上的
   `v=dev` 只负责给人看的友好提示，不承担安全职责。
4. **签名：正式版的 `code_requirement` 与它的测试逐字节不变。** 开发版只有一条路径：对端必须与
   **本进程用同一张叶证书签名**（运行时取自身签名的叶证书哈希）。负责人的 Developer ID、协作者
   本机的自签证书都走这一条；ad-hoc 不支持。开发版不用钥匙串访问组，密钥存数据目录里的 0600 文件。
5. **开发版没有更新通道**：不注册 updater、不带更新公钥。
6. **test 包仍是正式身份**（它要验的正是正式签名、正式更新链），test 包与正式包依然互斥，
   本 ADR 不改变这一点。

## 背景

`just mac-dev` 与正式包共用 `~/Applications/P-Pass.app`、LaunchAgent、数据目录，正式包在时直接
拒绝（`tools/mac-dev.sh` 的 `refuse_release`）。主 Mac 上「开发」与「验收正式包」互相挡；
Android debug 包与正式包同 applicationId、签名不同，装不上去。外部协作者没有团队证书和
daemon 的 Developer ID 授权文件，#1115 之后完全跑不起来。

## 决定

### 1. 变体的唯一来源

新建叶子 crate `crates/variant`（无依赖），只放常量：

```rust
#[cfg(not(ppf_dev))] pub const VARIANT: Variant = Variant::Release;
#[cfg(ppf_dev)]      pub const VARIANT: Variant = Variant::Dev;
// 其余身份常量按同样两行写，见下表
```

- 开发构建由脚本统一设置 `RUSTFLAGS="--cfg ppf_dev"`，并且使用**独立的 target 目录**
  （`target/dev`），开发产物与正式产物不共享缓存。
- `Cargo.toml` 用 `[lints.rust] unexpected_cfgs` 登记 `cfg(ppf_dev)`。
- `#[cfg(ppf_dev)]` 只许出现在 `crates/variant` 和下文列出的少数文件里，由 `arch-check` 白名单管着。
- 非 Rust 端：Android 用 `BuildConfig.VARIANT`，iOS 用 Info.plist 的 `PPassVariant`。启动时与
  原生库自报的 `variant::VARIANT` 对账，**不一致直接崩溃**。这样不会出现「开发版 APK 带着正式
  ALPN」这种静默错配。

### 2. 身份清单（正式值不变，开发值为提议）

**协议层（四端共用）**

| 项 | 正式值 | 开发值 | 代码位置 |
|---|---|---|---|
| 控制面 ALPN | `ppf/ctrl/1` | `ppf-dev/ctrl/1` | `crates/transport/src/lib.rs:53`；Android `transport/DaemonClient.kt:40` |
| 数据面 ALPN | `ppf/blobs/1` | `ppf-dev/blobs/1` | `crates/transport/src/lib.rs:61` |
| PAKE 上下文 | `ppass/pair/v1` | `ppass-dev/pair/v1` | `crates/pair-pake/src/lib.rs:31-32` |
| 配对链接 | `ppf://pair?node=…` | 同左再加 `&v=dev` | `crates/daemon/src/pairing.rs:440`；`crates/transport/src/pair_link.rs` |
| 库标记目录 | `.ppf` | `.ppf-dev` | `crates/daemon/src/library_location.rs:20` |

**macOS**

| 项 | 正式值 | 开发值 | 代码位置 |
|---|---|---|---|
| 外壳 bundle id | `com.hawkeyexb.ppass.desktop` | `….desktop.dev` | `tauri.conf.json:5`；`platform/src/code_signature.rs:17` |
| daemon bundle id | `….desktop.daemon` | `….desktop.dev.daemon` | `code_signature.rs:20`；`tools/daemon-helper-macos.sh:40` |
| App 名与位置 | `~/Applications/P-Pass.app` | `~/Applications/P-Pass Dev.app` | `tauri.conf.json` productName；`tools/mac-dev.sh` |
| daemon LaunchAgent | `….desktop.daemon` | `….desktop.dev.daemon` | `platform/src/macos.rs:23` |
| 外壳 LaunchAgent | `….desktop.shell` | `….desktop.dev.shell` | `macos.rs:138` |
| 数据目录 | `~/Library/Application Support/P-Pass` | `…/P-Pass Dev` | `macos.rs:494` |
| IPC socket | `<数据目录>/run/daemon.sock` | 随数据目录 | `macos.rs:572` |
| 钥匙串 | 访问组 `2WJUWVUJBN.….daemon`，三个 service | 不用钥匙串，`<数据目录>/secrets/` 0600 | `platform/src/keychain.rs:22-31` |
| 默认库目录 | `~/Pictures/P-Pass Library` | `~/Pictures/P-Pass Dev Library` | `src-tauri/src/lib.rs:457` |
| WebView 存储 | 按 bundle id 自动隔离 | 自动 | 无需改 |
| 更新 | R2 / GitHub 清单 + 正式公钥 | 无 | `tauri.conf.json:84`；`tools/release/tauri-config.mjs` |

**Windows**

| 项 | 正式值 | 开发值 | 代码位置 |
|---|---|---|---|
| 服务名 / 服务账户 | `P-Pass` / `NT SERVICE\P-Pass` | `P-Pass Dev` | `platform/src/windows_service.rs:500`；`installer-hooks.nsh:16` |
| 服务管道 | `ppf-svc` | `ppf-dev-svc` | `platform/src/windows_pipe.rs:52` |
| 用户模式管道 | `ppf-<SID>` | `ppf-dev-<SID>` | `windows_pipe.rs:84` |
| 服务数据根 | `%ProgramData%\P-Pass` | `%ProgramData%\P-Pass Dev` | `windows_programdata.rs:154`；`installer-hooks.nsh:30` |
| 用户数据目录 | `%LOCALAPPDATA%\com.hawkeyexb.ppass.desktop` | `….desktop.dev` | `platform/src/windows.rs:334` |
| 计划任务 | `P-Pass` | `P-Pass Dev` | `windows.rs:115` |
| AUMID（通知） | `com.hawkeyexb.ppass.desktop` | `….desktop.dev` | `windows.rs:393` |
| 安装目录 / 卸载项 | `P-Pass`（随 productName） | `P-Pass Dev` | `tauri.conf.json` productName |
| DPAPI | 当前账户作用域，无 entropy | 加变体 entropy | `windows_programdata.rs:541` |

**Android**

| 项 | 正式值 | 开发值 | 代码位置 |
|---|---|---|---|
| applicationId | `com.hawkeyexb.ppass` | `com.hawkeyexb.ppass.dev`（`applicationIdSuffix`） | `app/build.gradle.kts:42` |
| 桌面名称 | `P-Pass` | `P-Pass Dev` | `AndroidManifest.xml:54` |
| Keystore / 通知渠道 / 文件目录 | 按 UID 自动隔离 | 自动 | 无需改 |
| FileProvider | `${applicationId}.fileprovider` | 自动带后缀 | `AndroidManifest.xml:123` |
| 安装结果广播 | `com.hawkeyexb.ppass.update.INSTALL_RESULT` | 开发版不更新，不涉及 | `AndroidManifest.xml:115` |
| 更新 | 按版本号推导通道 + 两把公钥 | 关闭，两把公钥都置空 | `build.gradle.kts:57-58`；`update/UpdateChecker.kt:126` |
| 原生库 | `libtransport.so` | 开发版单独产出一份（带 `ppf_dev`） | `build.gradle.kts` 的 `irohBlobsJniLibs` |

⚠️ Android 版本号含 `-test.` 才走 test 通道，其余一律走正式通道。所以开发版**必须显式关掉更新**，
否则会拿正式公钥去查正式清单。

**iOS**

| 项 | 正式值 | 开发值 | 代码位置 |
|---|---|---|---|
| bundle id | `com.hawkeyexb.ppass` | `com.hawkeyexb.ppass.dev` | `apps/ios/Config/Base.xcconfig` 的 `PPASS_BUNDLE_ID` |
| 显示名 | `P-Pass` | `P-Pass Dev` | `PPass/Info.plist` 的 `CFBundleDisplayName` |
| App Group | `group.com.hawkeyexb.ppass` | 开发版不带（#1172 后已不使用） | `project.yml` entitlements |
| 钥匙串 | service `com.hawkeyexb.ppass.identity`，默认访问组 | 默认访问组随 bundle id 自动隔离 | `PPass/Live/LiveTransport.swift:10` |
| BGTask id | `….backup` / `….refresh` | 按 App 隔离，不改 | `Info.plist:33-34` |
| 签名团队 | `2WJUWVUJBN` | 本地 xcconfig 可覆盖团队与 id 前缀 | `project.yml` `DEVELOPMENT_TEAM` |
| 传输 xcframework | 一份 | 开发版单独产出一份 | `tools/build-ios-transport-xcframework.sh` |

当前**任何一端都没有向系统注册 URL scheme**（已 grep Manifest、Info.plist、tauri 配置），所以两版
并存不会弹出「用哪个 App 打开」。以后要注册 `ppf://`，开发版必须改用 `ppf-dev://`。

### 3. 隔离边界：开发版与正式版之间什么保证、靠什么保证

| 要保证的 | 机制 | 强度 |
|---|---|---|
| 开发版与正式版连不上、配不了对 | ALPN 不同：QUIC 握手失败，在 `transport` 内完成，应用层不参与 | 协议强制，所有入口都挡 |
| 即使 ALPN 被误配，配对也完成不了 | PAKE 上下文带变体，两边算出的会话密钥不一致 | 密码学强制 |
| 扫错二维码时给出可读的提示 | 解析链接时比较 `v` 与本机变体（正式版不带 `v`）；不一致就提示「这是正式版（开发版）桌面」 | 仅 UX |
| 手机开发版只能配开发版桌面 | 同上三条：手机与桌面用同一份 `variant` 常量 | 协议强制 |
| 开发版拿不到正式版的密钥 | macOS：正式密钥在钥匙串访问组里，开发版没有该授权，系统拒绝。Android、iOS：应用沙盒。Windows 服务模式：`ProgramData\P-Pass` 的 ACL 只授权给 `NT SERVICE\P-Pass` | 系统强制 |
| 开发版不碰正式版的文件 | 路径常量不同，开发版里没有指向正式路径的代码 | **约定**：macOS / Windows 用户模式下，同一用户的进程物理上能读这些文件。Windows 用户模式的 DPAPI 再加变体 entropy |
| 开发版不认领正式版的照片库（含外接盘） | 库标记 `.ppf-dev`；开发版选择目录时遇到 `.ppf` 直接拒绝 | 代码强制（仅开发版） |
| 开发版收不到正式更新 | 不注册 updater、不带公钥 | 编译期强制 |

偏离 #1069 的说明：#1069 规定 ALPN 不跟协议版本走，是为了让旧版对端能连上、在带内收到「请升级
哪一端」的提示。变体不同则不存在任何可以升级过去的路径，在连接层失败才是正确行为。友好提示由
配对链接里的 `v` 参数提前给出。

配对短码会合（`infra/workers/rendezvous`）目前没有接入客户端（`crates/daemon/src/config.rs:39`）。
将来接入时，`code_hash` 的输入要带变体前缀，让开发版与正式版处在不同的命名空间。

### 4. macOS 签名：协作者能跑，正式版的校验不削弱

| | 正式版（含 test 包） | 开发版 |
|---|---|---|
| 对端要求 | `code_requirement(id)`：Apple 根证书 + Developer ID 两个 OID + 团队 OU + identifier | `identifier "<dev id>" and certificate leaf = H"<本进程叶证书 SHA-1>"` |
| 可用证书 | 只有团队 Developer ID | 任何真实证书：负责人的 Developer ID、免费 Apple Development、`just setup` 生成的本机自签证书 |
| 密钥存放 | data protection 钥匙串 + 访问组（需要授权文件） | `<数据目录>/secrets/` 0600 文件 |
| 授权文件 | daemon 嵌入 Developer ID provisioning profile | 不需要（不带 `keychain-access-groups`，否则没有 profile 会被 AMFI 杀掉） |
| 更新包校验（#1121） | 不变 | 不可达（没有 updater） |

- 「本进程的叶证书」在运行时用 `SecCodeCopySigningInformation(self)` 取得。外壳与 daemon 由同一个
  脚本、同一张证书签名，所以互相认得。别人用自己的证书签的程序，认不过。
- 不支持 ad-hoc：ad-hoc 签名的 designated requirement 是 cdhash，每次构建都会变，钉不住，TCC 授权
  也会在每次重编后被重置。
- 放宽路径只写在 `#[cfg(ppf_dev)]` 下，位于 `platform/src/code_signature.rs`、
  `platform/src/local_peer.rs`、`platform/src/keychain.rs`（选择存储后端）三个文件，进入
  `arch-check` 白名单。正式版构建里这段代码不参与编译。
- 负责人自己的开发版也走这条路径，不再像今天的 mac-dev 那样「签名校验与正式包一字不差」。
  正式签名链路改由 test 包与 `just verify-m1` 验证（这本来就是 E3 的职责）。

Windows 按用户 SID 认对端（#1167），与代码签名无关，开发版只改名字，不放宽任何东西。

### 5. 正式版零变化：怎么判定

1. **字面值快照测试**：`crates/variant` 里有一个只在 `cfg(not(ppf_dev))` 下编译的测试，逐项断言
   上面各表的「正式值」列。现有钉死字面值的测试（`code_signature.rs:255`、`local_peer.rs:459`、
   `windows.rs:2683` 等）一律不改。
2. **diff 门禁**：每张卡的 PR 中，上述测试函数体的 diff 必须为空。由脚本
   `tools/check-release-identity-untouched.sh` 判定，输出 PASS/FAIL。
3. **产物门禁**：发版打包脚本（`bundle-desktop-macos.sh`、Windows NSIS 流程、Android/iOS 发版）对
   最终二进制跑 `strings`，出现 `ppf-dev/`、`.desktop.dev`、`ppass-dev/` 中任何一个就失败。只靠单测
   证明不了发出去的包没带 `ppf_dev`，这一道在产物上判。
4. **反证**：把 `ppf_dev` 注入正式构建（或把开发值抄进正式常量），以上三道都必须变红。

## 理由（与标准做法对照）

| 平台 | 标准做法 | 我们怎么对齐 | 偏离与原因 |
|---|---|---|---|
| Android | build variants；`applicationIdSuffix ".dev"`、`resValue` 改应用名 | debug buildType 就是开发版：加 `.dev` 后缀，改名，单独产出 `.so` | 不加 productFlavor。目前不需要「正式身份但可调试」的包，需要时再拆 flavor |
| iOS | 多 configuration / scheme，每个 configuration 用一个 xcconfig 设 bundle id 后缀与显示名 | Debug 用 `Dev.xcconfig`，Release 用 `Base.xcconfig` | 协作者的团队与 id 前缀由不入库的 `Local.xcconfig` 覆盖，因为 `.dev` 的 App ID 只在我们团队名下 |
| macOS | 并存的独立 bundle：Chrome Canary（`com.google.Chrome.canary`）、Firefox Nightly、Xcode-beta，各有自己的 bundle id、数据目录、更新通道 | 独立的 `P-Pass Dev.app`，所有身份项派生自它 | Canary 有自己的更新通道；我们的开发版不更新，由开发者自己构建 |
| Windows | 并存产品用不同的服务名、安装目录和 AUMID（如 SQL Server 命名实例、Edge Dev 渠道） | 服务、管道、数据目录、任务名、AUMID 全加 ` Dev` | 无 |
| Rust | 用 `--cfg` 区分构建形态，不用 feature（feature 会被 `--all-features` 打开，且 feature 应当只做加法） | `--cfg ppf_dev` | 无 |
| 协议 | 不同产品线用不同 ALPN（ALPN 本来就是标识应用协议的） | `ppf-dev/*` | 与 #1069 的关系见 §3 |

## 后果

- 主 Mac、三星、iPhone 上可以同时装正式版和开发版，验收不再打断开发。
- 外部协作者用免费证书或本机自签证书就能跑桌面开发版，不需要我们的证书与授权文件。
- 写死包名的脚本要按变体改：`tools/android-ctrl-smoke.sh`、`tools/dogfood/*.sh`、
  `tools/reset-local.sh`、`tools/windows/manual-regression.sh`。Android instrumentation 测试今后跑在
  开发版（debug）上，要配的是**开发版桌面**；要对正式版桌面跑 E3，用正式 APK。
- 开发版循环不再覆盖「Developer ID + 钥匙串访问组」这条正式链路，由 test 包回归覆盖。
- 开发与正式各一份 Rust 产物，首次编译时间翻倍（之后增量）。
- `just mac-dev` 的互斥闸门（`refuse_release`）随 macOS 卡删除。

## 备选（未采纳）

- **cargo feature `dev`**：Linux CI 的 `--all-features` 会把它打开，现有钉字面值的测试会集体变红；
  而且 feature 会在依赖图里传染。
- **运行时开关（环境变量、配置项）选变体**：正式二进制里就带着放宽路径，违背 #1115 的「没有开发后门」。
- **开发版继续用团队钥匙串访问组（`….dev.daemon`）**：要去 Apple 后台新建 App ID 与 Developer ID
  授权文件，协作者照样用不了。两条开发路径并存，对弱模型 agent 来说负担太重。
- **只在应用层（Hello 带变体字段）校验**：所有入口都得各自记得去查，漏一处就串线。ALPN 一处就能挡住全部。
- **ad-hoc 签名给协作者**：理由见 §4。

## 实施计划（每张卡可独立合入）

验收规则：除 V1 外，每张卡都要拿出**同一台设备上正式版与开发版同时运行**的 E3 证据，并由
`tools/e3/coexist-<端>.sh` 脚本判定，输出 PASS/FAIL。每张卡都要附反证：把开发值改回正式值，
脚本或隔离测试必须变红。全部卡都属于核心，由验收人批准。

| 卡 | 范围（路径） | 验收场景 |
|---|---|---|
| V1 变体常量与门禁 | `crates/variant/**`、根 `Cargo.toml`/`Cargo.lock`、`tools/arch-check.sh`、`tools/test-arch-check.sh`、`tools/check-release-identity-untouched.sh`、`justfile` | **例外：本卡没有消费方，拿不出并存证据**。验收：E1 + 快照测试；`ppf_dev` 出现在白名单外时 arch-check 变红；带 `--cfg ppf_dev` 时快照测试被排除、开发值测试通过 |
| V2 平台身份接线 | `crates/platform/src/{code_signature,macos,keychain,local_peer,windows,windows_service,windows_pipe,windows_programdata}.rs`、`crates/daemon/src/library_location.rs`、`apps/desktop/src-tauri/src/lib.rs`（默认库名） | 正式版：用本分支打一个正式包，在主 Mac 上跑现有回归，结果与 main 一致（E3），并且身份门禁 PASS。开发版：`--cfg ppf_dev` 单测断言所有路径都带后缀 |
| V3 协议隔离 | `crates/transport/src/lib.rs`、`crates/transport/src/pair_link.rs`、`crates/pair-pake/src/lib.rs`、`crates/daemon/src/pairing.rs`、Android `transport/DaemonClient.kt` | E2 契约矩阵：开发↔开发能配对、能传输；开发↔正式在握手阶段失败；PAKE 上下文不同则配对失败；`v` 不一致时给出提示。反证：把 ALPN 改回正式值，矩阵变红 |
| V4 macOS 开发版签名 | `crates/platform/src/{code_signature,local_peer,keychain}.rs`（仅 `cfg(ppf_dev)` 段）、`tools/daemon-helper-macos.sh`（开发分支） | 用本机自签证书签名的开发版，外壳与 daemon 能互连；换另一张证书签的外壳被拒；ad-hoc 被拒。正式版 `code_requirement` 的测试 diff 为空 |
| V5 macOS 开发版打包与 `mac-dev` | `tools/mac-dev.sh`、`tools/release/tauri-config.mjs`、`justfile`、开发版图标 | **主 Mac 并存**：正式版 `P-Pass.app` 与 `P-Pass Dev.app` 同时运行；`launchctl list` 能看到两个 daemon label；两个数据目录、两个库目录；正式版继续收正式手机的备份；开发版用 `tools/android-pair.sh` 配开发版手机（V6 合入前用沙盒脚本代替） |
| V6 Android 开发版 | `apps/android/app/build.gradle.kts`、`AndroidManifest.xml`、`res/`（名称、图标）、`update/UpdateChecker.kt`、写死包名的脚本 | **三星并存**：两个 App 同时安装；开发版配 Mac 开发版桌面并完成备份；开发版扫正式版二维码时被拒并提示；正式版继续向正式桌面备份；开发版不发起更新检查（日志里没有清单请求） |
| V7 iOS 开发版 | `apps/ios/Config/**`、`apps/ios/project.yml`、`PPass/Info.plist`、`tools/build-ios-transport-xcframework.sh` | **iPhone 并存**：TestFlight 正式版与 Xcode 装的 `P-Pass Dev` 同时存在；开发版配 Mac 开发版桌面；互扫二维码时被拒 |
| V8 Windows 开发版 | `crates/platform/src/windows*.rs`（命名）、`apps/desktop/src-tauri/windows/installer-hooks.nsh`、Windows 打包脚本 | **回归机并存**：`sc query` 能看到 `P-Pass` 与 `P-Pass Dev` 两个服务同时在跑；两个 ProgramData 目录；卸载开发版不影响正式版 |

顺序：V1 → V2 → V3 → V4 → V5 → V6，之后是 V7、V8。V2、V3 合入后，正式版的行为由身份门禁和
现有回归共同证明没有变化。

不在本 ADR 范围、另开卡：`just dev <端>` / `just doctor` / `just setup`（含生成本机自签证书）、
`docs/dev-setup.md`（开发流程提案 §3.2b 第 2、4 条）。

## 待负责人拍板（用户能感知的）

1. 开发版的名字：提议四端统一叫 `P-Pass Dev`。
2. 开发版图标怎么区分：提议在原图标上加一条橙色「DEV」角标。
3. 开发版默认照片库目录：提议 `~/Pictures/P-Pass Dev Library`。
4. **test 包仍会替换正式版**：test 包是正式身份，装上就会顶掉同一台设备上的正式版。本 ADR 只解决
   「开发版与正式版并存」。如果希望 test 包也能与正式版并存，需要另外加一个变体，单独决策。
