# 全量回归 SOP（正式发版前）

> 正式发版前的回归唯一入口。执行者默认是 agent：拿到任意一台 macOS（Apple Silicon）
> 和一台 USB 调试已授权的 Android 手机，照本文从 §2 走到 §7 即可产出一份回归报告。
> 桌面端是 Windows 时，§2–§7 照走，凡是 macOS 专属的命令按 [§9](#9-windows-桌面变体) 替换，并加跑 §9 的 W 系列用例。
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
| G3 | 无人值守：App 进程崩溃、Doze、服务被杀或停止后，自动备份能自己恢复 | 备份静默停摆 |
| G4 | 配对可信：断开后旧身份被拒，重新配对可用，断开通知可靠送达 | 安全边界失效或设备列表失真 |
| G5 | 隐私：日志里没有地址、完整编号、令牌 | 诊断包泄露用户信息 |

分层原则：CI 已经证明过的不在真机上重跑。本文只做 CI 证明不了的事（真签名、真安装、真系统调度、真升级）。

## 1. 什么时候跑、谁来做

- **时机**：候选 test tag 发布后、打正式 tag 之前；每个正式版跑一轮。
- **执行标记**：每条用例标 `agent`（adb / IPC / shell 能独立完成）或 `user`（必须人在设备上操作）。
- **`user` 步骤只有三类**：系统授权弹窗（照片、通知、摄像头、安装未知应用、电池优化白名单）、需要密码的操作、只能用眼睛判断的界面观感。agent 不代点系统授权、不输密码、不改系统设置。
- **不做重启类用例**：手机重启后停在首次解锁前，USB 调试不可用，agent 无法继续，只能等人来解锁。重启后的自动备份由 CI 与狗粮期自然运行覆盖。
- **人工批次**：`user` 步骤按 §5 集中成几批。到批次时 agent 发推送通知，人一次做完，平时不打断。

## 2. 入口条件

全部满足才开跑，任一不满足就停下，报告写明原因。

- [ ] 候选 tag 的 Release run 结论 success。#1187 起它包含发版前全量验证（本次要构建的各端 CI + E2E），任一条红都建不出 Release，所以不必再逐条查 CI。
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

   macOS 常驻 daemon 只接受签名程序的 IPC 连接（#1115），脚本连不上它。状态与日志改由 App 内签名的 daemon 自己跑一次 `diag export` 取：这条子命令以 daemon 角色连常驻服务，只调 `status` 与 `logs.export`，包里的 `status.json` 是版本、状态、照片数、进程号、启动时间。

   ```bash
   CONF="$HOME/Library/Application Support/P-Pass/config.toml"
   DATA_DIR=$(sed -n 's/^data_dir *= *"\(.*\)"$/\1/p' "$CONF")
   DAEMON_LOG="$HOME/Library/Application Support/P-Pass/logs/daemon.log"
   HELPER="/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon"
   ppass_diag() {   # 导出一份诊断包，打印它的路径；daemon_reachable=false 即常驻服务不在线
     local z="$WORK/diag-$(date +%s).zip"
     "$HELPER" diag export --out "$z" | jq -e '.daemon_reachable' >/dev/null && echo "$z"
   }
   ppass_status() { unzip -p "$(ppass_diag)" status.json; }
   ppass_status | jq '{version, state, photo_count}'
   ```

   `config.toml` 的 `data_dir` 在 macOS 上是钥匙串里库位置的同步副本，只用来定位库目录；改它不改变 daemon 用的库。

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
| R0.2 | agent | 桌面：退出 P-Pass → 挂载正式版 dmg → `ditto` 覆盖 `/Applications/P-Pass.app` → 打开 | daemon 起来，`ppass_status` 的 `version` 等于正式版桌面版本号 | `status.json` 输出 |
| R0.3 | user | 专用测试机首次安装时走一遍桌面向导（选库目录） | 三步走完，进入主界面 | 截图 |
| R0.4 | user+agent | 生成 40 张带唯一内容的 JPEG push 到 `DCIM/PPassRegression/` 并触发媒体扫描；手机打开 App → 首页「无法扫码？手动输入配对串」，人在桌面 App「添加设备」里显示配对串（#1115 起脚本取不到正式桌面的配对串，也不能代为批准），`adb shell input text` 填入后由人在桌面点「允许」（设备名取手机型号）。授权弹窗在开局批次里由人点 | 配对成功；桌面设备列表出现该机型 | 诊断包 `devices.json`（NodeId 前缀）+ 设备行 |
| R0.5 | agent | 范围只选 `PPassRegression`，立即备份，等完成 | 40/40；每张 `sha256` 在 `originals/` 里能找到同值文件 | 哈希对账表 |

### R1 升级（G2，对应 upgrade-compat A、B 格）

| ID | 执行 | 步骤 | 预期 | 证据 |
|---|---|---|---|---|
| R1.1 | agent | 升级前快照。手机：发布签名包不可 `run-as`，改记桌面 `device` 表里该机的 `node_id` 与 `pairing_epoch`（升级后不变即证明 `identity.key` 与配对保留）、设置页的相册范围。桌面 `identity.key` 哈希、`_sqlx_migrations` 最大版本、各表行数、`originals/` 全量哈希 | 快照落盘 | `pre-upgrade.json` |
| R1.2 | agent | 桌面覆盖安装候选 dmg（同 R0.2 手法；日常机见 §3 第 5 条） | daemon 起来；迁移只前进；NodeId、原图哈希、行数不减 | 前后对比 |
| R1.3 | agent | `adb install -r` 候选 APK 覆盖安装（更新通道由版本号推导，没有切换开关；正式版只认正式通道，收不到 test 包） | 装上候选版；不需要重新配对；范围保留；后续一轮零重复 | 前后对比 + 版本号 |
| R1.4 | agent | 版本一致性：手机 `dumpsys package` 的 versionName、`ppass_status` 的 `version`、`/Applications/P-Pass.app` 的 `CFBundleShortVersionString`（桌面壳界面上的版本号即读它） | 三者都等于候选版本号 | 三行输出 |
| R1.5 | agent | 升级后再 push 8 张 → 自动或立即备份 | 恰好 +8，无重复入库 | 对账表 |
| R1.6 | agent+user | 应用内更新一跳：从候选版 App 内更新到下一个 test tag（对外动作，先问人；两个 tag 钉在同一个 SHA，不要取打 tag 那一刻的 `origin/main`）。抓 `adb logcat` 的 `PPassUpdate` 与 `PackageInstallerSession` | 点一次系统安装器的「更新」即装上；没有 `Session was abandoned`；配对与范围保留 | 日志摘录 + 版本号 |

更新代码只在「下一跳」生效：R1.6 跑的是候选版自己的更新代码。候选版改了更新流程时 R1.6 必跑；修更新流程的修复版要先 `adb install -r` 装上，再更新到下一个 test tag。

### R2 备份正确性（G1）

| ID | 执行 | 步骤 | 预期 | 证据 |
|---|---|---|---|---|
| R2.1 | agent | 大批次：push 300 张 → 立即备份 | 全部完成，App 不 ANR，前台服务通知在跑完后消失 | 对账 + `dumpsys activity services` |
| R2.2 | agent | 备份中断网：开始备份后 `adb shell svc wifi disable`，30 秒后恢复 | 自动续传收敛，不重不漏 | 对账 |
| R2.3 | agent | 备份中让进程崩溃：`am crash com.hawkeyexb.ppass`，不打开 App（`am kill` 杀不掉跑着前台服务的进程；`force-stop` 按平台规则会清掉全部后台任务直到用户打开 App，不代表真实场景） | 后台任务接续完成；不接续时记 #827 并看重新打开 App 后是否零重复补齐 | 对账 + `dumpsys jobscheduler` |
| R2.4 | agent | 取回：从桌面库随机抽 5 张，经手机「保存到相册」取回 | 取回文件与原图字节一致 | 哈希对比 |
| R2.5 | agent | 手机删除 5 张已备份照片 | 桌面保留，不重传 | 对账 |

### R3 无人值守恢复（G3）

| ID | 执行 | 步骤 | 预期 | 证据 |
|---|---|---|---|---|
| R3.2 | agent | `kill -9` daemon | launchd 拉起；壳自动重连；手机下一轮备份成功 | `pgrep` + IPC + 对账 |
| R3.3 | agent | 照桌面「停止服务」的做法：先写标记 `~/Library/Application Support/P-Pass/desktop-user-stopped`，再 `launchctl bootout gui/$(id -u)/com.hawkeyexb.ppass.desktop.daemon`，45 秒后 `pgrep` 确认仍停着（只 bootout 不写标记，壳的自愈会在 30 秒内拉回），手机立即备份；恢复时删标记再 `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hawkeyexb.ppass.desktop.daemon.plist` | 手机给出明确提示；恢复后收敛 | logcat 摘录 + 对账 |
| R3.4 | agent | `dumpsys deviceidle force-idle` 进 Doze，再 `unforce` | Doze 期间不跑且文案平静；退出后补跑 | logcat 摘录 |

磁盘满（T-070，`crates/daemon/tests/scenarios/process_failures.rs` 的 `disk_full_*`）和崩溃恢复（同文件 `crash_mid_transfer_*`）由 CI 在 Linux 上覆盖，真机不重跑。

### R4 配对与断开（G4）

| ID | 执行 | 步骤 | 预期 | 证据 |
|---|---|---|---|---|
| R4.1 | agent | 服务在线，手机端「断开电脑」 | 手机回到欢迎页；桌面把该设备标为已断开 | `device` 表 `revoked` |
| R4.1b | agent | 同 R3.3 停服务，手机端「断开电脑」，再恢复服务 | 手机 5 秒内完成断开；恢复服务后手机不补发，桌面该设备仍未撤销（主动断开只尽力通知一次，#956 / #565 撤销；残留设备行由桌面端最近活动与手动移除管理） | 手机日志只有一行断开通知；`device` 表 `revoked=0` |
| R4.2 | agent | 查桌面 `device` 表该 `node_id` | `revoked=1`，`pairing_epoch` 与断开前一致（「旧身份 hello 被拒」由 `DaemonUnpairTest` 覆盖） | sqlite 输出 |
| R4.3 | agent | 重新配对（同 R0.4） | 成功，备份可继续，旧照片不重传 | 对账 |

### R5 隐私（G5）

| ID | 执行 | 步骤 | 预期 | 证据 |
|---|---|---|---|---|
| R5.1 | agent | 收集本轮 `adb logcat -d --uid=<App 的 uid>`（按 uid，跨进程重启也不漏）和 `$DAEMON_LOG` 里本轮时间窗的行（文件里可能留着脱敏上线前的历史行，不算本轮）。第一遍按本轮自己的秘密原文检索：电脑 NodeId 全长（配对串的 `node=`）、手机 NodeId 全长（macOS 桌面侧只给前缀：从手机自己的日志里按前缀取全长；Windows 用 `ipc devices.list`）、配对串里的 `t=` 令牌、`ipc.token` 第二行（只 Windows 有；macOS 常驻 daemon 不用令牌）。第二遍按形状检索：任意 64 位十六进制串、公网 IPv4/IPv6（私网、链路本地、回环按 `redact-vectors.json` 的 `keep` 规则放行） | 两遍都零命中 | 检索命令与输出 |
| R5.2 | agent+user | `ppass_diag` 导出的包（经 `logs.export` 收 audit / diag_events / devices 三份 JSON，另含 daemon.log、status.json；Windows 仍可直接 `ipc logs.export`）；带 `daemon.log` 的完整诊断包由人在桌面界面导出（收尾批次）。两份都解开，同 R5.1 两遍检索，另查用户主目录名与本轮测试图片文件名 | 零命中 | 检索命令与输出 |

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
| 升级 | R1.6 | 系统安装器点「更新」（人不在场时，经人在对话里授权，agent 可用 adb 代点） | 30 秒 |
| 收尾 | §4 跑完 | R6 全部 + 界面导出诊断包 | 10 分钟 |

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

## 9. Windows 桌面变体

桌面端换成一台 Windows 10/11 x64 时，§0 的五项保证、§1 的分工、§4 的用例顺序和 §6 的通过标准都不变。本节只写**和 macOS 不一样的地方**：先给出要替换的命令，再列出 Windows 独有的 W 系列用例。

agent 在 Git Bash 里执行；凡是要把 `/S`、`/F` 这类斜杠参数传给 Windows 原生程序的命令，都用 PowerShell 跑，MSYS 会把它们改写成路径。

### 9.0 执行环境：先确认 agent 不在 MSIX 沙盒里

agent 如果跑在 MSIX 打包的宿主里（例如 Claude 桌面 App），它启动的所有子进程都继承包的**文件与 HKCU 虚拟化**：安装器写进 `%LOCALAPPDATA%` 的文件实际落在 `%LOCALAPPDATA%\Packages\<包名>\LocalCache\Local\` 下，Run 键、卸载项写进包私有的注册表。agent 自己看是正常的，但测到的不是用户机器上的真实状态（2026-10-12 首跑就因此重跑了一遍安装类用例）。

- **判断**：安装后看 `%LOCALAPPDATA%\Packages\*\LocalCache\Local\P-Pass` 是否存在；或者备份进行中 `powercfg /requests` 里 daemon 的路径是否带 `Packages\…\LocalCache`。
- **做法**：安装、卸载、启动 App、查计划任务 / 卸载项这类步骤，一律经 `tools/windows/run-outside-package.ps1 -Cmd '<cmd 命令行>'` 执行。它用 WMI `Win32_Process.Create` 起进程，WmiPrvSE 没有包身份，子进程看到的是真实文件系统与注册表；输出写在 `%USERPROFILE%\ppcheck\`。启动 App 用 `Invoke-CimMethod Win32_Process Create` 直接起 `p-pass-desktop.exe`。
- ⚠️ **不要经 `run-outside-package.ps1` 启动 App**：它把所有命令的输出都写进同一个 `out.txt`，App 一直开着就一直占着这个文件，之后每条经它执行的命令都写不进输出、实际上没有执行（2026-10-13 踩过）。启动 App 用 `cmd.exe /c start "" "<exe>"` 交给 `Invoke-CimMethod`，让 cmd 立即退出。
- 照片库在「图片」下、`%TEMP%` 也不虚拟化，所以 IPC、哈希对账、日志检索不受影响。

### 9.0b 界面操作由 agent 完成

Windows 上除系统安全提示外，界面操作都由 agent 做，不打断人：

- **桌面窗口**：WebView2 把页面的无障碍树暴露给 UI Automation。`tools/windows/uia-drive.ps1 -Action dump` 列出元素，`-Action click -Name <按钮文字>` 按文字点击（中文参数从 PowerShell 传，Git Bash 会把编码弄乱）。页面切换后第一次点击偶尔返回「NOT FOUND」，重试一次即可。
- **系统对话框**（如「发现新版本 …，是否下载并安装？」）：是任务对话框（`#32770`），在 UIA 里挂在 P-Pass 主窗口下面，按钮的类名是 `CCPushButton`，没有 Invoke 模式。做法：用 UIA 按名字找到按钮，取它的 `NativeWindowHandle`，对这个句柄发 `BM_CLICK`（`0x00F5`）。
- **托盘菜单**：图标在「显示隐藏的图标」折叠区，名字是 `P-Pass`（#876 之后），用 UIA 按名字找到，在它的中心发鼠标右键。菜单是原生 Win32 菜单（`#32768`），UIA 读不到菜单项，用键盘选：菜单项顺序见 `apps/desktop/src-tauri/src/lib.rs` 的 `TRAY_ITEMS`（打开 / 导出诊断包 / 停止后台服务 / 退出），例如「导出诊断包」是 ↓ ↓ 回车。
- **手机授权**：测试机上用 `adb shell pm grant com.hawkeyexb.ppass android.permission.<权限>` 授予 `READ_MEDIA_IMAGES`、`READ_MEDIA_VIDEO`、`ACCESS_MEDIA_LOCATION`、`POST_NOTIFICATIONS`；电池白名单用 `dumpsys deviceidle whitelist +com.hawkeyexb.ppass`。App 内的点击用 `uiautomator dump` 找坐标再 `input tap`。
- **仍然要人的**：UAC 提权（W4 的 `powercfg /requests`）、SmartScreen「仍要运行」（R6.4）。

### 9.1 基线版本

在 Windows 正式发布之前（#788），Latest 正式版里**没有** Windows 安装包。这时 R0 的「上一个正式版」改用**候选之前的那个 Windows test 包**。

⚠️ 不能等候选出来再去找：test 通道只保留每端最新的一份安装包，候选 tag 一出包，旧的 Windows 包和旧 test 草稿、tag 就被自动删掉（#872）。所以要在**打候选 tag 之前**先把 test 通道当前的 Windows 安装包下载下来，留作基线：

```bash
gh release download test-channel -R "$REPO" -D "$WORK/base" -p '*_x64-setup.exe' -p 'manifest-windows.json'
```

已经错过时，用本机以前回归留下的、核对过哈希的安装包（报告里写明来源和哈希）。基线的应用内更新会指向 test 通道，也就是候选，所以 R1.2 可以直接走 R1.6 的应用内更新一跳。Windows 正式发布之后，就和 macOS 一样用 Latest。

### 9.2 §3 预检的替换

1. **工具链**：Windows 上的 `python3` 常是微软商店的占位程序（运行后退出码 49，没有任何输出）。准备一个 shim 放到 `PATH` 最前，内容是 `exec "/c/Program Files/Python39/python" "$@"`，按本机的 Python 路径改。注意 `PATH` 里的目录要写成 `/c/...` 这种形式，写成 `C:/...` 时冒号会把它切断。`sqlite3` 用 Android SDK `platform-tools` 里自带的那一份即可。
2. **产物校验**：
   - `sha256sum` 算出的候选 `P-Pass_<版本>_x64-setup.exe` 哈希，要同时等于 `SHA256SUMS-windows-x64` 里的值和 `manifest-windows.json` 里 `platforms."windows-x86_64".sha256` 的值。
   - 在 PowerShell 里跑 `Get-AuthenticodeSignature <exe>`。签名接入（#846）之前，结果是 `NotSigned`，记进报告，**不阻塞**。接入之后必须是 `Valid`，签名者是 SignPath 签发的证书，否则阻塞。
3. **daemon 发现**：

   ```bash
   APPDIR="$LOCALAPPDATA/com.hawkeyexb.ppass.desktop"            # 平台数据目录（DESK-24 #173 之后）
   CONF="$APPDIR/config.toml"
   # data_dir 可能是 TOML 字面串 '…'（反斜杠原样），也可能是基本串 "…"（反斜杠成对转义）
   DATA_DIR=$(cygpath -u "$(sed -n "s/^data_dir *= *[\"']\(.*\)[\"']\$/\1/p" "$CONF" | sed 's/\\\\/\\/g')")
   DAEMON_LOG="$APPDIR/logs/daemon.log"
   SOCK=$(sed -n 1p "$DATA_DIR/ipc.token"); TOKEN=$(sed -n 2p "$DATA_DIR/ipc.token")
   source tools/ipc-lib.sh   # Windows 上走命名管道 \\.\pipe\<SOCK>
   ipc status | jq '.result | {version, state, photo_count, pid, exe_path}'
   ```

4. **桌面机属性**：专用测试机可以用 `tools/windows/reset-ppass-env.ps1 -Uninstall` 清到出厂状态，先加 `-DryRun` 看一遍会删什么。日常机的约束和 §3 第 5 条相同。

### 9.3 §4 用例的替换

| 用例 | Windows 上的做法 | 预期 |
|---|---|---|
| R0.2 / R1.2 安装 | PowerShell：`Start-Process <setup.exe> -ArgumentList '/S' -Wait`。安装器的 PREINSTALL 钩子会先结束 `ppf-daemon.exe` 和 `p-pass-desktop.exe`。静默安装**不会**自动启动 App，装完要 `Start-Process "$env:LOCALAPPDATA\P-Pass\p-pass-desktop.exe"`。已经配置过、没停过服务的机器，安装器的 POSTINSTALL 钩子装完就运行计划任务 `P-Pass`，daemon 不等 App 就起来（#957）；全新机器由向导登记任务并拉起 | `ipc status` 的 `version` 等于安装包版本，`exe_path` 位于 `%LOCALAPPDATA%\P-Pass\` 下 |
| R0.3 向导 | agent 用 `uia-drive.ps1` 依次点「继续」「继续」「完成」。启动时若已有更新的 test 包，会先弹「发现新版本 …」，基线阶段对它点「取消」。默认库目录是 `图片\P-Pass 家庭照片库`，路径里带中文，正好覆盖非 ASCII 路径；全新机器上这个目录不存在，#871 修好之前首启必失败 | 三步走完，进入主界面 |
| R1.4 桌面版本 | 读 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass` 的 `DisplayVersion`，或者 `p-pass-desktop.exe` 的 `VersionInfo.ProductVersion` | 和 `ipc status` 的 `version`、手机端版本号一致 |
| R1.6 桌面应用内更新 | 打开候选版桌面端，会弹出系统对话框「发现新版本 …，是否下载并安装？」，人点「确定」即可。人在对话里授权后，agent 也可以给对话框里的「确定」按钮发 `BM_CLICK` 代点。同时跑 W1 盯窗口 | 安装器进度窗出现后桌面端自动重启；`DisplayVersion` 和 `ipc status` 的 `version` 都变成下一跳版本，`pid` 换新（更新后 daemon 换新版，#788 第 4 项） |
| R3.2 崩溃恢复 | PowerShell：`Stop-Process -Id <ipc status 的 pid> -Force`，分别在桌面壳开着和退出 App 之后各做一次 | 两种情况都由计划任务 `P-Pass` 的每分钟看门狗在 1 分钟内拉起，新进程的父进程是 `svchost.exe`（#957；之前桌面壳没在跑时要等下次登录） |
| R3.3 / R4.1 停服务 | 用托盘或设置页的「停止后台服务」（键盘操作见 §9.0b）。**不要**只写标记再杀进程：计划任务还在，看门狗一分钟内就会把 daemon 拉回来。等 2 分钟以上确认仍然停着；恢复时点「启动后台服务」 | 停止后计划任务 `P-Pass` 被删除、没有 daemon 进程，2 分钟以上不被拉起，重启电脑后也不起（#957）；启动后任务恢复、daemon 的父进程是 `svchost.exe` |
| R5.1 日志 | `$DAEMON_LOG` 见 §9.2 | 同 macOS |
| R6.1 照片墙 | 「在 Finder 中显示」换成「在资源管理器中显示」 | 资源管理器打开，并选中原文件 |
| R6.4 首次打开 | 用浏览器下载候选安装包，双击运行 | 签名接入之前：SmartScreen 弹出「Windows 已保护你的电脑」，点「更多信息 → 仍要运行」后能装上，记进报告。签名接入之后：发布者显示为签名证书的主体，不出现「未知发布者」 |
| §7 清理 | 测试照片移到回收站，不做硬删除：PowerShell 里用 `[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(<path>, 'OnlyErrorDialogs', 'SendToRecycleBin')`，先 `Add-Type -AssemblyName Microsoft.VisualBasic` | — |

### 9.4 W 系列：Windows 独有的用例

| ID | 执行 | 步骤 | 预期 | 证据 |
|---|---|---|---|---|
| W1 | agent | 先在另一个 PowerShell 里起 `tools/windows/watch-new-windows.ps1 -Seconds <N>`，再依次触发：静默安装、首次启动、R1.6 应用内更新、R3.2 自愈、R3.3 停止服务。脚本每 5 毫秒扫描一次新出现的可见顶层窗口。不要拿「有没有 conhost」当判据，带 `CREATE_NO_WINDOW` 启动的进程也有隐藏的 conhost | 脚本退出码 0，没有任何 `ConsoleWindowClass` / `CASCADIA_HOSTING_WINDOW_CLASS` 窗口（#168 / #787 / #814 的回归） | 脚本输出 |
| W2 | agent | 经 §9.0 的沙盒外执行，`Get-ScheduledTask -TaskName P-Pass` 看动作和状态；再查 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 下没有 `P-Pass` 值 | 任务的执行路径是 `%LOCALAPPDATA%\P-Pass\ppf-daemon.exe`，状态 `Running`；Run 值不存在（老版本升级上来的，打开 App 后迁移掉，#957） | 命令输出 |
| W3 | agent | 安装时 daemon 正在跑：不先停服务，直接静默覆盖安装候选包 | 安装成功，没有「文件被占用」；装完打开 App 后 daemon 是新版本 | 退出码 + `ipc status` |
| W4 | agent | 备份进行中，用 `powercfg /requests` 查唤醒声明（要在管理员终端里跑，由人执行，或者在人授权后提权跑一次） | 传输期间 `SYSTEM` 一栏间歇列出 `ppf-daemon.exe`（按传输持有、传完即撤，2 秒采样会看到断续命中）；备份完成后不再出现（NET-26 #419 传输期间持有唤醒）。#804 落地之后改成：插着电时一直列出 | 命令输出 |
| W5 | agent | 收尾时执行 `"%LOCALAPPDATA%\P-Pass\uninstall.exe" /S`，然后重新安装候选版并打开 App（都经 §9.0 的沙盒外执行） | 卸载后计划任务被删、70 秒内没有 daemon 被拉起，照片库目录和 `config.toml` 都还在；重装并打开 App 后不用重新配对，照片不重传，任务恢复并在运行（#877、#957） | 目录列表 + `Get-ScheduledTask` + 对账 |
| W6 | agent | 桌面系统通知目前只在磁盘可用空间跌破阈值时发（`App.svelte` 的 `checkLowSpace`；断开设备不发通知）。只有在磁盘接近写满的测试机上才能触发；触发后查 `%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db` 里 `NotificationHandler.PrimaryId = 'com.hawkeyexb.ppass.desktop'` 的记录 | 有一条通知，文案完整（DESK-17 #166）。条件不具备时标「未覆盖」 | sqlite 查询输出 |

W3 和 W5 都会改动安装状态，放在 §4 全部跑完、§7 清理之前做。

### 9.5 本节不覆盖的

- **登录 / 重启周期**：开机自启靠计划任务的登录触发，agent 没法在同一个会话里完成注销再登录，归人工：服务运行时重启，登录后 daemon 由 `svchost.exe` 拉起；停止服务后重启，登录后没有 daemon、没有计划任务（2026-10-15 人工验过，#957）。
- **熄屏相关的用例不做自动验收，归人工**（验收人 2026-10-13 定）：R3.4（Doze）和 R6.2 里「锁屏后在线态」这一半。原因：
  - 三星机的息屏显示（AOD）让系统认为屏幕仍亮着（`dumpsys deviceidle` 里 `mScreenOn=true`），`force-idle` 停在 INACTIVE。
  - 手机插着 USB 充电时，锁屏后后台心跳不停，在线态和真实使用不一样（2026-10-13 实测：锁屏 170 秒后仍显示「在线」）。

  agent 跑的报告里，这两项一律标「人工验收」，不标通过或失败。人工跑法见 [manual-regression-windows.md](manual-regression-windows.md) 的 S19 和 S25。
