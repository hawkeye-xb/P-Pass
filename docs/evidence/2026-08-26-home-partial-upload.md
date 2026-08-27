# 2026-08-26 家中真机：照片只传了一部分，之后再也不传

**状态**：🔍 取证中，**尚无结论**。本文件是取证请求 + 假设表，不是诊断报告。

## 验收人报告的过程（原话保留）

1. 下载最新版
2. desktop move 到 application，启动后发现版本不对，停止后台服务后，重新
   move，重新启动，是最新版了
3. 手机安装 apk，扫码连接
4. 上传几张图片，等了好久，**最终突然传输成功**
5. 选择更多的图片，选择相册的，**之后再也传输不成功了**
6. 本地 agent 调整代理转发
7. desktop 重新停止所有服务，然后重启，重新走 onboard 流程（→ DESK-12）
8. 连接状态 OK，相片不传输，触发了不传输

## 与既往真机的差异（三个新变量，都没测过）

- **鸿蒙手机**（此前全部真机回归都在三星上做）。鸿蒙的后台冻结策略与三星
  Freecess 不同（DOG-03 记的是三星的）。
- **家庭网络**（此前是同一台 Mac 上双端 / 办公网络）。iroh 的 NAT 穿透与
  relay 可达性在这里第一次被检验。
- **中途加入了代理转发**（第 6 步）。时序上它在故障**之后**——所以它不是
  根因候选，但它污染了第 7、8 步的网络状态，口供必须拿。

## ⚠️ 取证纪律

现场已经被"修"过两次（第 6 步改代理、第 7 步重装重启）。**再动一次就取不到
昨晚的证据了。** 下面的清单**全部是只读操作**，一条写操作都没有。

---

# 给家中 desktop agent 的取证请求（可整段转发）

> **只读取证。不许重启任何服务、不许改任何配置、不许清任何目录、不许重装。**
> 逐项执行并把**完整输出**贴回来。某一项拿不到，就报"拿不到"这个事实本身
> ——空结果也是证据，不要跳过不提。

## A. 现在跑的到底是不是新版 daemon

第 2 步出现过"以为装了新版其实是旧版"。所以这条必须实证，不采信"重装过了"。

```bash
# A1 进程在不在、命令行路径是什么（旧版可能从别处被拉起）
ps aux | grep -i '[d]aemon' | grep -i p-pass
ps aux | grep -i '[P]-Pass'

# A2 launchd 服务是否注册、状态如何
ls -la ~/Library/LaunchAgents/ | grep -i p-pass
launchctl print gui/$(id -u)/$(ls ~/Library/LaunchAgents/ | grep -i p-pass | sed 's/\.plist$//') 2>&1 | head -40

# A3 App 自报版本
defaults read /Applications/P-Pass.app/Contents/Info.plist CFBundleShortVersionString 2>&1
/Applications/P-Pass.app/Contents/MacOS/*daemon* --version 2>&1 | head -3
```

## B. daemon 日志（昨晚故障时段）

⚠️ 日志路径**不要写死**。从 plist 里读实际值：

```bash
# B1 plist 里声明的日志路径
PLIST=$(ls ~/Library/LaunchAgents/*p-pass* 2>/dev/null | head -1)
echo "plist: $PLIST"
/usr/libexec/PlistBuddy -c "Print :StandardOutPath" "$PLIST" 2>&1
/usr/libexec/PlistBuddy -c "Print :StandardErrorPath" "$PLIST" 2>&1

# B2 拿到路径后取日志（把 <路径> 换成 B1 输出的实际值）
ls -la <B1 的 StandardOutPath>
wc -l <B1 的 StandardOutPath>
# 昨晚整段，别截断
cat <B1 的 StandardOutPath>
cat <B1 的 StandardErrorPath>
```

**如果 daemon 不是 launchd 托管的**（手动拉起 / App 内 spawn），那就**没有
日志文件**——这本身是重要事实，请明确报告"plist 无 StandardOutPath"或
"plist 不存在"，然后走 D4 的 `logs.export` 拿 stdout tail。

日志里重点找（贴出所有匹配行，带时间戳）：

```bash
grep -niE 'error|warn|fail|timeout|refused|connection|relay|holepunch|disconnect' <日志路径>
grep -niE 'backup|begin|blob|recv|store' <日志路径> | tail -60
```

## C. 网络与代理现状 + 第 6 步的口供

```bash
# C1 系统代理
scutil --proxy
env | grep -iE 'proxy|_PROXY'

# C2 有没有 VPN / 虚拟网卡
ifconfig | grep -E '^(utun|tun|tap|ppp)'
networksetup -listallnetworkservices 2>&1 | head

# C3 iroh relay 可达性（daemon 用它做 NAT 穿透兜底）
curl -sS -o /dev/null -w 'relay https: %{http_code} / %{time_total}s\n' \
  https://relay.iroh.network/ 2>&1
nc -zv -u -w3 relay.iroh.network 3478 2>&1 | tail -2
```

**口供（请文字回答，这部分命令拿不到）**：

1. 第 6 步"调整代理转发"**具体改了什么**？改前是什么、改后是什么？
2. 改的是系统代理、shell 环境变量、路由表，还是路由器/网关上的转发规则？
3. 第 5 步照片传不动的时候，**代理还没改**——对吗？（时序确认）

## D. daemon 自己的账（IPC 只读查询）

token 在 `~/Library/Application Support/P-Pass/ipc.token`，两行：第 1 行
socket 名，第 2 行令牌。下面这段 python 自包含，不需要仓库：

```bash
cd ~/Library/Application\ Support/P-Pass
SOCK=$(sed -n 1p ipc.token); TOKEN=$(sed -n 2p ipc.token)
ipc() {
  python3 - "$SOCK" "$TOKEN" "$1" "${2:-{\}}" <<'PY'
import socket, json, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect("/tmp/" + sys.argv[1])
f = s.makefile("rw")
f.write(sys.argv[2] + "\n"); f.flush()
f.write(json.dumps({"id":"x","method":sys.argv[3],"params":json.loads(sys.argv[4])}) + "\n"); f.flush()
print(json.dumps(json.loads(f.readline()), ensure_ascii=False, indent=2))
PY
}

# D1 手机还在配对表里吗？（第 7 步重走 onboard 后身份是否还认得它）
ipc devices.list

# D2 daemon 确认收到的最后一张是什么、什么时候——**判别"传输是否真的到达过"**
ipc device.watermarks

# D3 活动流与审计（daemon 视角的事件序列）
ipc activity.list
ipc audit.list

# D4 脱敏诊断包（可分享，含 stdout tail——B 段拿不到日志文件时靠它）
ipc logs.export
```

## E. data_dir 是否被清过（一条命令钉死"身份换了没"）

第 7 步重走 onboard 时，如果库目录/身份被重建，手机的配对会失效。

```bash
ls -la ~/Library/Application\ Support/P-Pass/
ls -la ~/Library/Application\ Support/P-Pass/.ppf/ 2>&1
```

看 `identity`（或同名密钥文件）、`ipc.token`、`config.toml`、
`.ppf/index.sqlite` 的 **mtime**：

- 都是**昨天之前**的时间戳 → 身份没换，配对是延续的
- 有**昨晚新建**的 → 身份换了，第 8 步的"连接状态 OK"需要重新解释

顺带看库目录里实际落了多少张：

```bash
# 库目录路径从 config 读
grep -i data_dir ~/Library/Application\ Support/P-Pass/config.toml 2>&1
# 然后数一下（把 <库目录> 换成上面读到的，或默认的 ~/Pictures/P-Pass 家庭照片库）
find "<库目录>" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.png' \) | wc -l
```

⚠️ **只数不动。** 库目录里是验收人的真实照片，一个字节都不许改。

---

# 手机侧（鸿蒙，等它连上本地网络后补）

```bash
# 版本先实证——第 1-2 步已经出过一次"以为装了新版"
adb shell dumpsys package com.hawkeyexb.ppass | grep -E 'versionName|versionCode'

# 昨晚的日志（如果没被冲掉）
adb logcat -d > /tmp/ppass-logs/logcat.txt
adb logcat -d | grep -iE 'BackupWorker|iroh|WorkManager|ppass' > /tmp/ppass-logs/filtered.txt

# 关键：备份 work 是不是卡在 RETRY 的退避里
adb shell dumpsys jobscheduler | grep -A20 -i ppass
```

**要看的核心一条**：`Result.retry()` 之后 WorkManager 的退避是**指数增长**
的。一轮 `ConnectionLost` 之后，新的触发落在同一个 unique work 上会被现有的
退避吞掉——这正好是第 8 步「触发了不传输」的形状。UX-14 在三星上抓到的就是
这条链的另一半（`sending 54/198` 时 `ConnectionLost(TimedOut)` → retry）。

---

# 假设表（**均未验证**，按判别力排序）

| # | 假设 | 解释得了哪几步 | 判别证据 |
|---|---|---|---|
| **H1** | 家庭网络下 iroh 连接建立困难（relay 可达性差 / 穿透失败后回落慢） | 第 4 步「等了好久突然成功」正是这个形状 | daemon 日志的连接/relay 事件（B）+ C3 的 relay 可达性 |
| **H2** | 大批量传输中途断连 → `Result.retry()` 退避吞掉后续触发 | 解释「小批量成、大批量再也不成」+ 第 8 步「触发了不传输」 | 手机 `dumpsys jobscheduler` 的退避状态 + logcat 的 `ConnectionLost` |
| **H3** | 代理转发污染了网络（**后置混杂，不是根因**） | 只影响第 7、8 步 | 时序：第 5 步坏在改代理**之前**。C 段的现状 + 口供 |
| **H4** | 重走 onboard 换了身份 → 配对实际失效 | 第 8 步「连接状态 OK 但不传」 | E 段 mtime 一条命令即可排除/确认 |
| H5 | 鸿蒙后台冻结（DOG-03 形状） | 只解释后台场景 | 降权——验收人报的是前台触发也不传 |

**H1 + H2 是一条链**：连接慢 → 大批量传到一半断 → retry 退避 → 之后任何
触发都"没反应"。既有卡 `NET-01`（backup begin 超时 15s 后退避）记的是同一
条链的上游。

**下一步不是改代码，是让证据落地。** 取证回来之后才谈根因。

---

# 追加：2026-08-27 现场实验（验收人在外用 5G，连接显示已建立）

## 新事实

验收人在外网 5G 下打开 App，**连接状态显示已连上家里 desktop**。

这一条本身就是证据：**iroh 的 relay/穿透在跨网络下能建立连接**。昨晚的故障
不能简单归为「连不上」。

## 约束：手机侧现在取不到日志

Mac 在家里，手机在验收人手上 → `adb` 这条路暂时断了。所以本轮取证只能是
**两端协作**：验收人在手机上操作，家里 agent 同时盯 daemon 侧。

## 实验 A（判别力最高，先做这个）

**目的**：区分「手机根本没发起」和「发起了但传不过去」。这两件事在手机界面上
长得一模一样（都是「什么也没发生」，见 UX-15），但在 daemon 侧完全不同。

**家里 agent 先起两个观察窗**（只读）：

```bash
# 窗口 1：实时跟 daemon 日志。路径从 plist 读实际值（见 B 段），
# 拿不到日志文件就跳过本窗口，只靠窗口 2。
tail -f <B 段读到的 StandardOutPath>

# 窗口 2：记下**触发前**的水位——这是实验的基线
cd ~/Library/Application\ Support/P-Pass
SOCK=$(sed -n 1p ipc.token); TOKEN=$(sed -n 2p ipc.token)
# ipc() 函数见上文 D 段（自包含 python，不需要仓库）
ipc device.watermarks     # ← 把这次输出完整贴回来，标注「触发前」
ipc devices.list          # ← 手机现在是不是还在配对表里
```

**然后验收人在手机上做一件事**：点一次「立即备份」（英雄区按钮，或设置页那个）。
记下**手机屏幕上出现了什么**——包括「什么都没出现」这个情况，那也是数据。

**60 秒后家里 agent 再取一次**：

```bash
ipc device.watermarks     # ← 标注「触发后」
ipc activity.list
ipc audit.list
```

**三分支判读**：

| daemon 日志 | 水位变化 | 结论 | 指向 |
|---|---|---|---|
| 出现连接/传输事件 | **涨了** | 传输其实在走,只是手机界面不说 | UX-15（呈现缺陷），不是传输缺陷 |
| 出现连接/传输事件 | **没涨** | daemon 接上了但字节没落地 | 传输层——看日志里的 error/timeout |
| **一条都没有** | 没涨 | **手机根本没发起** | H2：退避吞掉了触发（NET-01 + UX-15） |

第三个分支是我最怀疑的。判据：`Result.retry()` 之后 work 处于 `ENQUEUED` 等
退避，新的手动触发落在**同一个 unique work** 上会被现有退避吞掉——手机界面
既不显示进行中也不报错（`ENQUEUED` 的 `isFinished == false`，见 UX-15），
表现就是「点了没反应」。

## 实验 B（只在实验 A 判出第二/第三分支时做）

**目的**：区分「网络」和「状态机卡死」。

请验收人**把 App 强制停止再重开**，然后再点一次备份。强制停止会清掉进程内
状态，但 WorkManager 的退避是持久化的——所以：

- 强停重开后**能传** → 是进程内状态问题
- 强停重开后**仍不传** → 退避/持久化状态问题（退避跨进程存活）

⚠️ 这一步会破坏当前现场，所以**必须在实验 A 的数据全部拿到之后再做**。

## 昨晚那份取证仍然要做

实验 A/B 是「现在为什么不传」。上文 A~E 五段是「昨晚发生了什么」——两者不
互相替代。日志会被轮转冲掉，**昨晚的日志优先级更高，先抢那个**。

---

# 取证结果（2026-08-27，家中 agent 执行 A~F 全部完成）

## 拿到的硬事实

| 项 | 结果 | 判定 |
|---|---|---|
| App 版本 | `0.4.0-test.9` | ✅ 是新版，第 2 步的版本混乱已解决 |
| `identity.key` mtime | **Aug 8 16:16** | ✅ **身份没换**——H4 排除 |
| `p-pass-daemon.err` | **73 MB / 24.7 万行**，`tls handshake eof` **92211 行**（8/26 22:22–22:29 的 7 分钟内） | → 新卡 **NET-02** |
| 8/27 relay 错误 | **0** | relay 已恢复 |
| watermarks | PFZM10=6，**ALN-AL00=13**，`last_backup_at` = **8/26 22:36:14** | 基线 |
| 8/26 22:36 之后的 audit | 只有 `device.connected`，**零 `backup.started`** | 手机没发起 |
| 8/27 06:16–10:00 | 手机连上 7 次，**零 backup** | 同上 |

## 前半段：代理，已自愈

22:22–22:29 传不动 = Clash（mihomo）把 iroh relay 的流量走了代理，TLS 握手
失败 9 万次。验收人给 relay 域名/IP 加直连白名单 → **22:29 配对成功，
22:29–22:36 连传 13 张**。

**代理是前半段的根因，且已经解决。** 顺带暴露了 NET-02（错误日志无节流）。

## 后半段（22:36 之后至今不传）：**根因在代码里找到了，不是网络**

家中 agent 的结论「手机没发起备份」正确。它推测的三条原因里第 ② 条方向对了
——我用代码确认，并且能精确到行。

`TriggerPolicy.kt:66` 的三档约束：

```kotlin
BackupTier.MANUAL -> BackupConstraintsSpec(
    requiresBatteryNotLow = false,
    requiresUnmetered = false,          // ← 唯一零约束的一档
)
BackupTier.USER_PRESENT -> BackupConstraintsSpec(
    requiresBatteryNotLow = false,
    requiresUnmetered = settings.wifiOnly,
)
BackupTier.BACKGROUND -> BackupConstraintsSpec(
    requiresBatteryNotLow = true,
    requiresUnmetered = settings.wifiOnly,
)
```

而 `BackupSettings.kt:17`：

```kotlin
val wifiOnly: Boolean = true,          // ← 默认开
```

**验收人 8/27 在外网 5G 上。`requiresUnmetered = true` 在移动网络下不满足
→ WorkManager 把所有自动通道的 work 挂在 ENQUEUED 等约束，永不执行。**

只有 `MANUAL` 档零约束能穿透。而验收人原话：「**我们没有主动触发上传的
按钮**」——这就是第二个缺陷（UX-15）：界面状态是 `Idle`/`AllSafe` 时
`heroActionOf` 返回 `null`，按钮**不渲染**。

于是形成一个闭环死结：

```
5G 网络 + wifiOnly=true  →  自动通道全部被约束挡住（设计如此，正确）
                          ↓
界面不说「在等 Wi-Fi」，显示成正常/已完成    ← UX-15，缺陷①
                          ↓
英雄区按钮因此不渲染 → 唯一能穿透约束的 MANUAL 档没有入口  ← 缺陷②
                          ↓
        用户：连上了、状态正常、就是不传，且无处可点
```

**「仅 Wi-Fi 时在移动网络下不自动备份」本身是正确设计**，不改。缺陷是
**它没有被说出来**，而且此时恰好剥夺了用户唯一的手动出路。

## 判决实验（一步，验收人自己就能做）

**连上任意 Wi-Fi**，然后看手机界面。

- **开始传了** → 后半段完全由 `wifiOnly` 约束解释，代码层无传输缺陷，
  待修的是 UX-15（把等待说出来 + 保留手动出路）
- **仍然不传** → `wifiOnly` 不是全部解释，回到 H2（`Result.retry()` 退避
  吞掉触发），需要手机侧 `dumpsys jobscheduler` 才能继续

⚠️ 8/26 22:36 之后那一夜他**在家里 Wi-Fi 上**，理论上约束是满足的，却也没
跑（周期兜底 5h，22:36 + 5h = 8/27 03:36 该跑一次）。所以**后半段可能是两个
原因叠加**：那一夜是 H2，白天在 5G 是约束。这个未知只能靠手机侧日志分辨。

## 待办产出

- 新卡 **NET-02**：relay 握手失败 73MB stderr 无节流
- **UX-15 建议提级 L1**（原为 backlog）：现在有了完整真机证据链——它不只是
  「没提示」，它在 5G 场景下**堵死了用户唯一的出路**
- 需要验收人回答一个问题：8/26 22:36 之后到 8/27 早上，手机是在家里 Wi-Fi
  上还是已经切到移动网络？这决定「那一夜没跑」算约束还是算 H2
