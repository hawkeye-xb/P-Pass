# IOS-03（#332）背景上传扩展 spike：模拟器部分

一次性最小 App + `PHBackgroundResourceUploadExtension` 扩展，不进主 App。只回答模拟器能回答的部分；八问里其余各问与真机验证见文末。

环境：Xcode 26.6（SDK 26.5），iOS 26.4 模拟器（专用 `BgUploadSpike-Test`，iPhone 17），2026-10-13。复现：`tools/run-sim.sh [等待分钟]`（建模拟器、灌 9 张素材、构建安装、授权、起 `tools/recv_server.py`、抓日志）。

证据等级：E2 = 模拟器实测；E1 = 仅读系统二进制字符串推断；未验证 = 明确标注。模拟器结论一律不得当作真机结论。

## 结论

| # | 问题 | 结论 | 等级 |
|---|---|---|---|
| ① | 带 `com.apple.photos.background-upload` 扩展点的扩展能否编译、安装 | 能。扩展类型 `extensionkit-extension`，Info.plist 写 `EXAppExtensionAttributes.EXExtensionPointIdentifier`，`@main struct : PHBackgroundResourceUploadExtension`。ad-hoc 签名即可 `simctl install`；系统识别到扩展：assetsd 读到 `BackgroundUploadURLBase`（扩展 Info.plist 键）。安装坑：缺 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` 时 `IXErrorDomain 2`「Failed to create app extension placeholder」 | E2 |
| ② | `setUploadJobExtensionEnabled` 前提与返回 | 需要相册授权为 `.authorized`（完整读写）。`.limited`(4) 与 `.denied`(2) 均抛 `PHPhotosErrorDomain 3311`（enable/disable 都一样）；完整授权下 `enable` 成功且 `uploadJobExtensionEnabled` 变 true，`disable` 成功变 false；已启用时再 enable 抛 `3202`。`jobLimit` 读到 200（第 6 问的一半，仅类属性值，非系统调度实测） | E2 |
| ③ | `process()` 是否被系统调度 | **模拟器上未调度**。观察 20 分钟（含强制触发手段）+ 15 分钟（仅 enable、不预建 job），共约 35 分钟，扩展进程从未启动（无 `ext init`、无 `process()`）。真机待验 | E2（负面结果） |
| ④ | job 目的地 `http://127.0.0.1:<port>` 请求是否到达、body 形状、方法/头 | **未验证**：process() 未被调度，主 App 里直接建的 job（`--create-in-app`，performChangesAndWait 返回成功）在 20 分钟内也没有任何请求到达本地接收端。body 形状、方法/请求头自定义、`responseHeaderFields` 均真机待验 | 未验证 |

## 过程证据（原始日志摘录）

### ② 授权与启用

```
SPIKE app start args=--enable --dump readWrite=3 extensionEnabled=false jobLimit=200 assets=9
SPIKE app setUploadJobExtensionEnabled(true) ok; now enabled=true
...
SPIKE app setUploadJobExtensionEnabled(true) failed domain=PHPhotosErrorDomain code=3202   # 已启用再 enable
start args=--enable readWrite=4(limited) -> failed PHPhotosErrorDomain code=3311
start args=--enable readWrite=2(denied)  -> failed PHPhotosErrorDomain code=3311
start args=--enable readWrite=3(authorized) -> ok; now enabled=true
```

### ③ 触发手段与系统侧日志

尝试过的触发：主 App 退到后台（启动 Settings）；`simctl status_bar override --batteryState charging --batteryLevel 100`（充电假象，只改状态栏，对系统未必有效）；`notifyutil -p com.apple.photos.simulateBackgroundResourceUploaderLaunchEvent`（系统二进制里的模拟入口）；强制重启 App；等待。

模拟入口被 assetsd 收到并处理，但只是为 App 的 bundle 建了后台 URLSession，没有拉起扩展：

```
10:36:56.350 assetsd [BackgroundAssetResourceUpload] Received simulated background resource uploader launch event
10:36:56.351 assetsd [BackgroundAssetResourceUpload] handleLaunchEvent: initializing sessions for 1 bundle IDs
10:36:56.410 assetsd [BackgroundAssetResourceUpload] Created background URLSession for com.hawkeyexb.ppass.bgspike with configuration ID: com.apple.photos.background-resource-uploader.com.hawkeyexb.ppass.bgspike.bg
10:36:56.438 assetsd [BackgroundAssetResourceUpload] Handled background resource uploader launch event
```

调度侧 BackgroundJobService 每次 enable/建 job 后都检查并判定无活：

```
assetsd [BackgroundJobService] Checked workers of library ... for pending jobs. Result: NO
assetsd [BackgroundJobService] Checked all submitted library bundles. Result: NO
assetsd [BackgroundJobService] No work to do at any criteria. Removing all bundles from processing set.
```

注：此前主 App 里已存在 pending job 时，系统二进制里有「Skipping configuration ... due to unprocessed pending/registered jobs」字符串（E1），所以第二轮改为只 enable、不建 job 再等 15 分钟，仍无任何扩展拉起日志。

### 系统二进制里读到的相关线索（E1，仅线索）

`PLBackgroundJobResourceUploadExtensionRunnerWorker` 负责拉扩展，配置有 EventMonitor/Processing/PostProcessing 状态，有「Extension timer limit reached」超时、失败后 dynamic backoff delay、max attempt count 等字符串，说明真实调度受 DAS/充电/闲置等条件与失败退避约束；这些条件在模拟器上没有可用的触发手段（未发现扩展对应的 simulate 入口，只有上面那个 URLSession 级的）。

## 未回答、必须真机验（本 spike 不覆盖）

- ③ 的真机版：`process()` 实际触发频率与前置条件（第 6 问）；`jobLimit` 在真机调度下的表现。**出结论前，任何「滞后 N 天」的用户可见表达都不许写。**
- ④ 与第 2 问：同网段 `http://192.168.x.x:port` 明文、自签 HTTPS 是否放行；ATS 由谁裁决；本地网络权限是否约束系统上传器。模拟器无法代表（走回环，且本轮请求根本未发出）。
- 第 3、4 问：本地网络授权弹窗；强杀主 App 后扩展是否还跑。
- 第 5、7 问：body 形状（裸 body / multipart）、Content-Type 谁定、方法与头能否自定义、分块与续传、`responseHeaderFields` 回传 64 hex 凭据。接收端 `tools/recv_server.py` 已就绪（记录方法/头/body 形状并回 `X-PPass-Receipt`）。
- 第 8 问：3105 token 过期人工构造（与本扩展无关，走 PPassMedia 水位侧，未在此验）。

## 对 #332 的含义

模拟器不能替代真机：扩展能编译安装、前提条件清楚（完整授权），但调度链路在模拟器上没有被走通，所以「同网段直连到底通不通」仍是未知数，#332 的核心问题保持开放，需要真机（#310 G0）继续。
