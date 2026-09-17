# NET-14：同 WiFi 推送优先交付 真机冒烟（2026-09-16）

**关联卡**：[NET-14](../../cards/NET-14-desktop-completion-must-push-not-poll-local-transfer-is-ground-truth.md)
**范围**：只验证「同网络（家庭 WiFi）+ 小文件」这一最简路径；不是本卡验收标准
里要求的三星热点大视频跨 relay / 拔线断网 / NET-12 长期后台存活。这三项
**仍未验证**，见文末「未完成」。

## 工件与运行态先验（按 AGENTS.md §0 要求核实,不是只看编译）

1. `cargo build --release -p daemon` 用当前 `main`（含 30e1dc7）重建，
   `target/release/daemon` mtime `Sep 16 12:37`（晚于该 commit 12:15:57）。
2. 旧 launchd agent `com.p-pass.daemon`（指向 9/15 旧 daemon 二进制）先
   `launchctl bootout` 清除，避免新装 App 内置 daemon 被旧常驻进程抢注册。
3. `tools/bundle-macos.sh` + 手动 `tauri build --no-bundle` / `tauri bundle`
   （官方 `bundle-desktop-macos.sh` 在无本地签名私钥时于 updater artifact
   签名步骤失败，这是预期行为——按 AGENTS.md 凭据纪律，本地无
   `TAURI_SIGNING_PRIVATE_KEY`；.app 本体已在失败前产出，手动补做脚本
   剩余的「嵌入 lib/ + ad-hoc 签名」两步，`codesign --verify --deep --strict`
   通过）覆盖安装到 `/Applications/P-Pass.app`。
4. Android：`ANDROID_NDK_HOME` 指向本机 29.0.14206865（此前默认未设置，
   `just android-test` 报 `ANDROID_NDK_HOME must be set` 而非真的绿；这是
   本轮新发现的本机环境问题，非代码问题）。`assembleDebug --rerun-tasks`
   强制重编 `libtransport.so`（此前一次 build 的 `.so` mtime 早于
   `android_blobs.rs` 最后一次源码改动，说明增量构建把 NET-14 的 native
   改动漏掉了——同样是本机构建缓存问题，不是代码回归）。
5. `adb install -r` 覆盖安装，`lastUpdateTime=2026-09-16 12:41:03`；
   `am force-stop` + `am start` 冷启动确认新进程 PID。
6. daemon 侧确认运行的是家庭照片库实例（`NodeId` 与手机侧已配对的
   `NodeId` 一致，非隔离测试库）。

## 已跑验证（代码侧，先于真机）

- `just ci`：fmt / clippy / nextest / arch-check / queue-check / md-check /
  token-check 全绿。
- Android JVM：**395 tests / 0 failures / 0 errors / 4 skipped**（79 个
  XML 时间戳核对为本次生成，含 `NET14PushFirstDeliveryTest` 17/17）。

## 真机步骤与结果

1. 在已选择范围内新增 `Screenshots` 相册（此前未勾选，本轮新出现,
   新建 3 张 `NET14-test-e-{0,1,2}.png`，内容互不相同,避免去重误判）,
   MediaStore 扫描后在选择备份相册界面看到「3 张」。
2. 勾选该相册,总数从 37 张变为 40 张,点击「开始备份」。
3. **约 1-2 秒内**主页汇总从「37/37 已回家」变为「40/40 张已回家，
   最近成功 刚刚」——这是**同 WiFi 局域网**下推送优先路径的预期表现
   （非跨 relay/热点场景,不能外推为大文件或弱网下的延迟数字）。
4. `logcat`（按 App 进程 PID 过滤）只见 3 条 `PPassFlow: Flow epoch
   preflight` 日志（每个 item 一条,发起阶段的日志),**没有任何**
   `Flow status reports cancelled` / native 层异常 / 权限重试类日志——
   即没有观察到回退到 `status()` 轮询分支的证据。
5. 桌面库 `index.sqlite` 直接查询实锤三个文件确已落盘且账本状态正确：

   ```text
   originals/.../2026/09/NET14-test-e-0.png  added_at=1789533782476
   originals/.../2026/09/NET14-test-e-1.png  added_at=1789533783156
   originals/.../2026/09/NET14-test-e-2.png  added_at=1789533783305
   ```

   `flow_delivery` 表三行全部 `state=completed`,各有唯一 `receipt_id`
   （`7c7398c8...` / `27105da1...` / `db278db8...`),与 `content_hash`
   一一对应,证明这不是「UI 显示成功但账本没写」的假阳性。

## 结论

同 WiFi、小文件、正常网络路径下：新代码可编译、可安装、可运行，
真实设备端到端交付成功，账本一致，没有观察到轮询兜底分支被触发的
副作用日志。这证明 NET-14 的「推送优先」路径在最简单场景下没有
引入回归。

**这不构成 NET-14 验收标准里「真机回归」那一条的完整通过**——卡内
明确要求的是「三星热点 288MB 视频跨 relay，全程无固定间隔轮询、完成
延迟接近推送到达时间」,本轮完全没有触碰热点/relay/大文件/弱网路径,
本地信号「空闲超过 30s 阈值才兜底问一次」的分支也完全没有被触发过
（局域网传输太快,根本不会进入这个分支）。

## 未完成（下一步真机窗口）

1. 三星切换蜂窝热点、Mac 主机通过该热点连接（或反向：Mac 保持家庭
   WiFi、手机走蜂窝数据）,制造跨 relay 路径,用一个 ≥100MB 的大文件
   验证：完成时机接近推送到达而非任何轮询周期、且能在 daemon/Android
   两侧日志分别看到 relay 路径证据（复用 NET-04/NET-05 已验证的
   `transport=debug,iroh=debug` 排障手法）。
2. 传输中途人为断开手机网络/杀 daemon 进程,验证本地信号从
   `InProgress{connected:true}` 转为 `idle_for` 超过 30s 阈值后触发
   兜底 `status()`,且只问一次、不回到持续轮询。
3. NET-12 前台服务保护下,长时间（数十分钟量级）保持推送订阅连接的
   稳定性,不在本卡验收范围内重复验证,但需要一次跨卡联合真机窗口。

## 环境清理

- 手机测试源 `NET14-test-e-{0,1,2}.png` 已通过 `adb shell rm` 删除并
  重新触发媒体扫描（这是本次新建的测试文件本身，非用户原始照片，
  按 AGENTS.md 授权范围内清理）。
- 桌面库对应资产作为证据留存（已确认落盘的测试副本,不是隔离脏数据,
  与 NET-04 证据记录同例）。
