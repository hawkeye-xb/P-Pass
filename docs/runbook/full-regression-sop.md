# 全量回归 SOP（正式发版前）

> 正式发版前的回归唯一入口。执行者默认是 agent：拿到任意一台 macOS（Apple Silicon）
> 和一台 USB 调试已授权的 Android 手机，照本文从 §2 走到 §7 即可产出一份回归报告。
> 用例细节的历史出处：[live-acceptance-checklist.md](live-acceptance-checklist.md)、
> [dogfood-manual-cases.md](dogfood-manual-cases.md)、
> [dogfood-week-cases.md](../product/dogfood-week-cases.md)、
> [upgrade-compat.md](upgrade-compat.md)（升级判据以它为准）。前两份不再单独执行。

## 0. 这次回归要证明什么

一个版本能发，等于下面五件事在真机上同时成立。每条用例都挂在其中一件上，挂不上的不进本文。

| 编号 | 保证 | 失败的后果 |
|---|---|---|
| G1 | 照片完整：已选范围内的照片全部到电脑，逐字节一致，原图不被改动 | 用户丢照片（不可逆） |
| G2 | 升级不丢：从上一个正式版直接升到候选版，配对、范围、照片库、续传都保留 | 用户升级后要重配，或库打不开 |
| G3 | 无人值守：杀 App、重启手机、电脑重启、服务被杀后，自动备份能自己恢复 | 备份静默停摆 |
| G4 | 配对可信：断开后旧身份被拒，重新配对可用，断开通知可靠送达 | 安全边界失效或设备列表失真 |
| G5 | 隐私：日志里没有地址、完整编号、令牌 | 诊断包泄露用户信息 |

分层原则：CI 已经证明过的不在真机上重跑。本文只做 CI 证明不了的事（真签名、真安装、真系统调度、真升级）。

## 1. 什么时候跑、谁来做

- **时机**：候选 test tag 发布后、打正式 tag 之前；每个正式版跑一轮。
- **执行标记**：每条用例标 `agent`（adb / IPC / shell 能独立完成）或 `user`（必须人在设备上操作）。
- **`user` 步骤只有三类**：系统授权弹窗（照片、通知、摄像头、安装未知应用、电池优化白名单）、需要密码的操作、只能用眼睛判断的界面观感。agent 不代点系统授权、不输密码、不改系统设置。
- **人工批次**：`user` 步骤按 §5 集中成两批（开局一批、收尾一批）。到批次时 agent 发推送通知，人一次做完，平时不打断。

## 2. 入口条件

全部满足才开跑，任一不满足就停下，报告写明原因。

- [ ] 候选 tag 对应 commit 的 CI 全绿（`gh run list --commit <sha>`）。
- [ ] 候选 Release 资产齐全：Android APK、macOS dmg 与 app.tar.gz、`SHA256SUMS-macos-arm64`、三份 manifest。
- [ ] 目标里程碑没有未关闭的阻塞卡。
- [ ] `test-channel` 指针已指向候选 tag（`gh release download test-channel -p manifest.json -O -` 的 `version` 等于候选版本）。

## 3. 环境发现与预检（`agent`）

本节不写死任何设备序列号或本机路径，全部现场发现，结果写进报告的「环境」段。

```bash
REPO=hawkeye-xb/P-Pass
TAG=<候选 tag，如 v0.9.12-test.3>
STABLE=$(gh release view -R "$REPO" --json tagName -q .tagName)   # Latest = 上一个正式版
WORK=$(mktemp -d)/regression && mkdir -p "$WORK"/{cand,stable,evidence}
gh release download "$TAG" -R "$REPO" -D "$WORK/cand"
gh release download "$STABLE" -R "$REPO" -D "$WORK/stable" -p '*android.apk' -p '*.dmg' -p 'SHA256SUMS*'
```

1. **工具链**：`adb`、`python3`、`sqlite3`、`jq`、`gh` 均可用；`gh auth status` 是仓库所属账号。`apksigner` 取最新的 build-tools（`$(ls -d ~/Library/Android/sdk/build-tools/* | sort -V | tail -1)/apksigner`），运行前 `source scripts/java-home.sh` 设好 `JAVA_HOME`（它对 NDK 缺失的提示可忽略，本节不用 NDK）。
2. **手机**：`adb devices` 恰好一台 `device` 状态 → `export ANDROID_SERIAL=<它>`。记录 `ro.product.model`、`ro.build.version.release`。多于一台时先问人用哪台。
3. **产物校验**：
   - `cd "$WORK/cand" && shasum -a 256 -c SHA256SUMS-macos-arm64`
   - `xcrun stapler validate <dmg>` 通过（公证票据钉在 dmg 上，dmg 里的 `.app` 本身没有票据，属正常）。
   - `hdiutil attach -nobrowse -readonly <dmg>` 挂载后，对 `.app` 跑 `codesign --verify --deep --strict` 与 `spctl -a -vv`：通过，且 `source=Notarized Developer ID`。
   - 挂载状态下读 `.app/Contents/Info.plist` 的 `CFBundleShortVersionString`，记下备 R1.4 用。
   - `apksigner verify --print-certs` 候选 APK 与上一个正式版 APK 的证书 SHA-256 **相同**（不同 = 覆盖安装会失败，直接阻塞）。
4. **daemon 发现**（桌面装好后执行）。照片库目录以桌面配置文件为准；不要用 `lsof` 反推，它会把中文路径转义成 `\xe5…`：

   ```bash
   CONF="$HOME/Library/Application Support/P-Pass/config.toml"
   DATA_DIR=$(sed -n 's/^data_dir *= *"\(.*\)"$/\1/p' "$CONF")
   DAEMON_LOG="$HOME/Library/Application Support/P-Pass/logs/daemon.log"
   SOCK=$(sed -n 1p "$DATA_DIR/ipc.token"); TOKEN=$(sed -n 2p "$DATA_DIR/ipc.token")
   source tools/ipc-lib.sh   # 之后用 ipc <method> [params]
   ipc status | jq '.result | {version, state, photo_count}'
   ```

5. **桌面机属性**：问清这台 Mac 是「专用测试机」还是「日常机」，记入报告。日常机上的照片库是真实数据，**禁止**删除、重置或降级：
   - R0.2、R0.3 不做（桌面不装回正式版：旧 daemon 遇到更新过的库会拒绝启动，见 [upgrade-compat.md](upgrade-compat.md) §5）。
   - R1.2 改为「当前已装版本 → 候选版」覆盖安装，R1.1 快照照做；upgrade-compat B 格在报告里记「部分覆盖（日常机）」。

## 4. 执行顺序与用例

顺序是刻意的：先在上一个正式版上铺好数据，再升级，升级后的版本上跑其余全部用例。这样一轮同时证明 G2 和「候选版本身可用」。

测试照片隔离：只往手机 `DCIM/PPassRegression/` 里放 agent 生成的图片，备份范围只选这一个相册。用户自己的相册不勾选、不读写。

### R0 基线：装上一个正式版

| ID | 执行 | 步骤 | 预期 | 证据 |
|---|---|---|---|---|
| R0.1 | agent | 手机：`adb uninstall com.hawkeyexb.ppass`（仅限测试机）→ `adb install` 正式版 APK | 安装成功；`dumpsys package` 的 versionName 等于正式版 | 命令输出 |
| R0.2 | agent | 桌面：退出 P-Pass → 挂载正式版 dmg → `ditto` 覆盖 `/Applications/P-Pass.app` → 打开 | daemon 起来，`ipc status` 的 `result.version` 等于正式版桌面版本号 | IPC 输出 |
| R0.3 | user | 专用测试机首次安装时走一遍桌面向导（选库目录） | 三步走完，进入主界面 | 截图 |
| R0.4 | agent+user | 生成 40 张带唯一内容的 JPEG push 到 `DCIM/PPassRegression/` 并触发媒体扫描；手机打开 App → 扫码页 → 「手动输入配对串」，串由 `ipc_pair_qr` 现取，`adb shell input text` 填入；`ipc pairing.confirm` 批准。授权弹窗在开局批次里由人点 | 配对成功；桌面设备列表出现该机型 | IPC 输出 + 设备行 |
| R0.5 | agent | 范围只选 `PPassRegression`，立即备份，等完成 | 40/40；每张 `sha256` 在 `originals/` 里能找到同值文件 | 哈希对账表 |

### R1 升级（G2，对应 upgrade-compat A、B 格）

| ID | 执行 | 步骤 | 预期 | 证据 |
|---|---|---|---|---|
| R1.1 | agent | 升级前快照：手机 `run-as` 读 `files/pairing.json`、`shared_prefs/backup_scope-*.xml` 的哈希；桌面 `identity.key` 哈希、`_sqlx_migrations` 最大版本、各表行数、`originals/` 全量哈希 | 快照落盘 | `pre-upgrade.json` |
| R1.2 | agent | 桌面覆盖安装候选 dmg（同 R0.2 手法；日常机见 §3 第 5 条） | daemon 起来；迁移只前进；NodeId、原图哈希、行数不减 | 前后对比 |
| R1.3 | agent+user | 手机切到测试通道 → App 内检查更新 → 下载 → 系统安装器确认（人点「安装」，首次需在开局批次授权「安装未知应用」） | 装上候选版；不需要重新配对；范围保留 | 前后对比 + 版本号 |
| R1.4 | agent | 版本一致性：手机 `dumpsys package` 的 versionName、`ipc status` 的 `result.version`、`/Applications/P-Pass.app` 的 `CFBundleShortVersionString`（桌面壳界面上的版本号即读它） | 三者都等于候选版本号 | 三行输出 |
| R1.5 | agent | 升级后再 push 8 张 → 自动或立即备份 | 恰好 +8，无重复入库 | 对账表 |

本次改动了 Android 更新流程本身时，R1.3 跑的是旧版的更新代码，证明不了新代码。此时加跑一跳：先发下一个 test tag（对外动作，先问人），再从候选版 App 内更新到它。

### R2 备份正确性（G1）

| ID | 执行 | 步骤 | 预期 | 证据 |
|---|---|---|---|---|
| R2.1 | agent | 大批次：push 300 张 → 立即备份 | 全部完成，App 不 ANR，前台服务通知在跑完后消失 | 对账 + `dumpsys activity services` |
| R2.2 | agent | 备份中断网：开始备份后 `adb shell svc wifi disable`，30 秒后恢复 | 自动续传收敛，不重不漏 | 对账 |
| R2.3 | agent | 备份中杀 App：`am force-stop` 后不打开 App | 后台任务接续完成 | 对账 + WorkManager 状态 |
| R2.4 | agent | 取回：从桌面库随机抽 5 张，经手机「保存到相册」取回 | 取回文件与原图字节一致 | 哈希对比 |
| R2.5 | agent | 手机删除 5 张已备份照片 | 桌面保留，不重传 | 对账 |

### R3 无人值守恢复（G3）

| ID | 执行 | 步骤 | 预期 | 证据 |
|---|---|---|---|---|
| R3.1 | agent | `adb reboot`，开机后不打开 App，push 5 张，插电连 Wi-Fi 熄屏等待（上限 30 分钟） | 自动备份触发并完成 | 对账 + 时间戳 |
| R3.2 | agent | `kill -9` daemon | launchd 拉起；壳自动重连；手机下一轮备份成功 | `pgrep` + IPC + 对账 |
| R3.3 | agent | `launchctl bootout gui/$(id -u)/com.p-pass.daemon` 停服务，`pgrep` 确认确实停了，手机立即备份；再 `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.p-pass.daemon.plist` 恢复 | 手机给出明确提示；恢复后收敛 | logcat 摘录 + 对账 |
| R3.4 | agent | `dumpsys deviceidle force-idle` 进 Doze，再 `unforce` | Doze 期间不跑且文案平静；退出后补跑 | logcat 摘录 |

磁盘满（T-070 `tools/scenarios/disk_full.sh`）和崩溃恢复（`crash_recovery.sh`）由 CI 在 Linux 上覆盖，真机不重跑。

### R4 配对与断开（G4）

| ID | 执行 | 步骤 | 预期 | 证据 |
|---|---|---|---|---|
| R4.1 | agent | 同 R3.3 停服务，手机端「断开电脑」，再恢复服务 | 恢复后 2 分钟内桌面把该设备标为已断开（发件箱补发） | `device` 表 `revoked` |
| R4.2 | agent | 查桌面 `device` 表该 `node_id` | `revoked=1`，`pairing_epoch` 与断开前一致（「旧身份 hello 被拒」由 `DaemonUnpairTest` 覆盖） | sqlite 输出 |
| R4.3 | agent | 重新配对（同 R0.4） | 成功，备份可继续，旧照片不重传 | 对账 |

### R5 隐私（G5）

| ID | 执行 | 步骤 | 预期 | 证据 |
|---|---|---|---|---|
| R5.1 | agent | 收集本轮 `adb logcat -d --pid=$(adb shell pidof com.hawkeyexb.ppass)` 和 `$DAEMON_LOG`。第一遍按本轮自己的秘密原文检索：电脑 NodeId 全长（配对串的 `node=`）、手机 NodeId 全长（`ipc devices.list`）、配对串里的 `t=` 令牌、`ipc.token` 第二行。第二遍按形状检索：任意 64 位十六进制串、公网 IPv4/IPv6（私网、链路本地、回环按 `redact-vectors.json` 的 `keep` 规则放行） | 两遍都零命中 | 检索命令与输出 |
| R5.2 | agent | `ipc logs.export` 导出桌面诊断包并解开，同 R5.1 两遍检索，另查用户主目录名与本轮测试图片文件名 | 零命中 | 检索命令与输出 |

### R6 界面观感（`user`，收尾批次）

| ID | 步骤 | 预期 |
|---|---|---|
| R6.1 | 桌面照片墙数量与总览一致，点开大图、「在 Finder 中显示」 | 数量一致，原文件被选中 |
| R6.2 | 桌面设备行：手机前台时在线，锁屏后显示「x 分钟前在线」 | 三档在线态正确 |
| R6.3 | 手机首页、备份页、设置页在中英文下无截断、无遮挡 | 文案完整 |
| R6.4 | 浏览器下载候选 dmg 后首次打开 | Gatekeeper 只出现标准的「来自互联网」确认，无「已损坏」 |

## 5. 人工批次

| 批次 | 时机 | 内容 | 预计 |
|---|---|---|---|
| 开局 | R0.4 之前 | 手机：照片权限（选「允许全部」）、通知、摄像头「仅此一次」、电池优化白名单、「安装未知应用」授权给 P-Pass；专用测试机走 R0.3 | 3 分钟 |
| 升级 | R1.3 | 系统安装器点「安装」 | 30 秒 |
| 收尾 | §4 跑完 | R6 全部 | 10 分钟 |

## 6. 通过标准

- **阻塞**：G1、G2、G4、G5 下任何一条失败；R1.4 版本不一致；§3 的签名或证书校验失败。失败即停止发版，开卡修复后从失败的用例重跑，涉及安装产物的改动从 R0 重跑。
- **可带病发布**：R3、R6 的失败，前提是开卡登记、写明影响面，并由发版人确认。
- **未覆盖**：环境做不到的用例（如日常机上的 R0.3）在报告里如实标注，不算通过。

## 7. 收尾与报告

1. 清理：手机删除 `DCIM/PPassRegression/` 并触发媒体扫描；桌面上本轮产生的测试照片移到废纸篓（`~/.Trash`），不做硬删除。
2. 手机留在候选版，保持配对，作为下一轮的起点。
3. 报告写到 `docs/evidence/<日期>-full-regression-<tag>.md`：环境段（§3 发现的结果）、逐条用例结果（✅ / ❌ / 未覆盖 + 证据路径）、新开的卡、发版结论。

## 8. 正式发版后复核（`agent`）

正式 tag 发布后 30 分钟内：

- [ ] 正式 tag 是重新构建的，不是回归过的那份产物：对正式 Release 的资产重跑 §3 第 3 条（SUMS、公证、签名、APK 证书）。
- [ ] `manifest-android.json` 的 `version` 等于该 tag 下 `release/versions.json` 的 `android`，`manifest-macos.json` 的 `version` 等于其 `desktop`（正式版两端版本号各自独立，不等于日期 tag 名）；URL 指向本次 Release。
- [ ] stable manifest 不含任何 `-test.` 版本（upgrade-compat D 格）。
- [ ] 一台停在上一个正式版的设备能在 App 内看到更新提示。
