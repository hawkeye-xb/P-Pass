# 更新签名密钥：划分、配置与轮换（#1121）

更新签名私钥决定了什么版本能装到用户设备上，是产品信任链里最重的一把密钥。本文是
它的操作手册：怎么配、怎么换、出事怎么办。仓库是公开的，本文与仓库里不出现任何密钥值。

## 1. 现状

| 通道 | 私钥（GitHub Actions secret） | 公钥的唯一来源 | 谁用它验签 |
|---|---|---|---|
| 正式 | `UPDATE_SIGNING_KEY` | `apps/desktop/src-tauri/tauri.conf.json` 的 `plugins.updater.pubkey` | 正式版桌面（Tauri updater）、正式版 Android（`MinisignVerifier`） |
| test | `UPDATE_SIGNING_KEY_TEST` | `release/update-keys/test.pub` | test 版桌面（构建时由 `tools/release/tauri-config.mjs` 换入）、test 版 Android |

- 一个安装包只认自己通道那一把：正式客户端拒收 test 签名，test 客户端拒收正式签名。
- 公钥不手抄：Android 构建（`apps/android/app/build.gradle.kts`）、桌面 test 构建、发布
  校验（`tools/release/update-key-lib.sh`）都从上表的来源读。
- 格式：tauri signer（minisign，Ed25519，空密码）。私钥是 base64 文本，公钥文件内容就是
  `tauri.conf.json` 里 `pubkey` 的那种 base64 文本。

签名环境（发布流水线的签名步骤）：
- 只运行 `tools/release/signer.sh`。它按 `tools/release/signer/` 的 lockfile 安装 tauri
  CLI，校验 integrity、不执行安装脚本；pnpm 本身也经 corepack 按 `packageManager` 里的哈希校验。
- 构建步骤（`pnpm tauri build/bundle`）拿不到任何更新签名私钥，`createUpdaterArtifacts` 已关。
- 每个签名步骤只拿到本通道那一把私钥。签完立即用本通道公钥自验；私钥缺失或配错通道时
  流水线失败，不会发出未签名的清单。
- 上传后从 release 上取回清单和安装包，用客户端内置的公钥再验一次签名与 sha256
  （`tools/release/verify-published.sh`）。

## 2. 配置 test 通道密钥（首次，由仓库所有者本人操作）

在 `~/personal/P-Pass` 目录下操作（gh 按目录自动用个人账号）：

1. `tools/release/new-update-key.sh test`
   - 生成密钥对，私钥写到 `~/.ppass-update-keys/test-<时间>.key`（0600，不打印）；
   - 私钥经 stdin 存进 secret `UPDATE_SIGNING_KEY_TEST`；
   - 公钥写到 `release/update-keys/test.pub`。
2. 把私钥文件备份进密码管理器，然后删除本地文件。
3. 提交 `release/update-keys/test.pub` 并合入 main。

公钥入库之前：test tag 的桌面构建会失败（缺 test 公钥），test 版 Android 拒收一切更新。
这是故意的，不能拿正式密钥去签 test 包。

切换后的第一个 test 版本，装着旧 test 包的设备收不到（旧包内置的是正式公钥）。
需要手动重装一次 test 包，之后恢复应用内更新。

## 3. 轮换（定期更换或疑似泄露）

Tauri updater 与 Android 客户端都只内置一把公钥，换钥不能一步到位：已安装的客户端只
认旧公钥。所以轮换分两步，由旧密钥签发一个携带新公钥的过渡版本：

1. **生成新密钥对**，私钥先不进 secret，放在本地并备份进密码管理器。
   - test 通道：`tools/release/new-update-key.sh test` 会直接改 secret，轮换时不要用它，改用
     `tools/release/signer.sh generate -w <路径> -p "" --ci` 手动生成；
   - 正式通道：同样手动生成。
2. **过渡版本**：把仓库里的公钥换成新公钥（正式改 `tauri.conf.json` 的 `pubkey`，test 改
   `release/update-keys/test.pub`），同时把旧公钥原样存成 `release/update-keys/stable.retiring.pub`
   （test 通道是 `test.retiring.pub`）；**secret 仍是旧私钥**。打 tag 发布。这一版：
   - 用旧私钥签名，现有客户端照常验签通过、能装上；
   - 内置的是新公钥，装上之后只认新私钥签的更新；
   - 发布流水线的签完自验与发布后验签接受「当前公钥或退役中公钥」任一把，所以过渡版本
     不需要放宽任何检查（`tools/release/update-key-lib.sh`，反证见 `test-update-key-lib.sh` ⑤）。
3. **等过渡版本铺开**：正式通道看应用内更新的覆盖情况（至少等主要设备都更新到过渡版本）；
   test 通道只有测试机，确认它们都装上即可。
4. **切 secret**：把 secret 换成新私钥（`gh secret set <名字> < <新私钥文件>`），并删掉
   `*.retiring.pub` 提交。之后的版本都用新私钥签名，旧私钥签的东西流水线不再接受。
5. 旧私钥在密码管理器里标注「已退役」，保留到确认不再需要重签旧版本为止。

还没更新到过渡版本的客户端，在第 4 步之后就收不到更新了，需要手动下载安装。所以第 3 步
不能省。

### 疑似泄露

- 正式私钥泄露：攻击者能签出正式客户端会接受的更新清单。macOS 客户端还要求新包由团队
  2WJUWVUJBN 签名，装不进别人的包；Android 和 Windows 没有这道检查。
  1. 立刻按上面的流程轮换，过渡版本优先发；
  2. 从 release 撤下可疑资产，检查 `test-channel` 与正式 release 的清单是否被改动；
  3. 在 key-compromise runbook 里登记时间线。
- test 私钥泄露：只影响 test 通道（测试机）。直接按第 2 节重新生成，测试机手动重装即可。

## 4. 相关代码

- 签名与校验：`tools/release/signer.sh`、`update-key-lib.sh`、`sign-android.sh`、
  `sign-desktop.sh`、`check-manifests-signed.sh`、`verify-published.sh`
- 反证测试：`tools/release/test-update-key-lib.sh`、release dry-run（`tools/release/dry-run.sh`）
- 客户端：桌面 `apps/desktop/src-tauri/src/update_install.rs`（下载、验签、校验团队、安装），
  Android `apps/android/app/src/main/java/com/hawkeyexb/ppass/update/MinisignVerifier.kt`
