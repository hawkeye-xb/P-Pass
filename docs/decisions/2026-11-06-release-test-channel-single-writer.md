# test-channel：写入与收敛分权，收敛单点跑一次、失败只告警

- 状态：已采纳
- 日期：2026-11-06
- 采纳：产品负责人 2026-11-06 在 #1546 拍板「选改法二（结构改法）」并给出 4 条不变量：
  <https://github.com/hawkeye-xb/P-Pass/issues/1546#issuecomment-6685431350>
- 关联：#1546（实现）、#1537（事故后核对：四端清单其实都指向 `v0.11.1-test.1`，包可用）、
  #872 / #852（`test-channel` 与分端清单的既有设计）

## 结论（必须守住的不变量）

1. **`test-channel` 是一个共享可写资源。** 同一轮发布里，每个端 job 只写自己那份清单与安装包，
   不做任何全局清理。写入是「只增自己的东西」，不删别人的东西。
2. **收敛（GC）在所有写入完成之后只跑一次，单点、串行、幂等。** 收敛只做两件事：
   删掉没有任何清单指向的旧安装包；删掉过期且无人引用的 test 草稿（连同 tag）。它不写清单、不传包。
3. **收敛失败不等于包没出。** 收敛失败时资产已上传、清单已指向，客户端能下载；收敛只影响占盘。
   因此收敛段失败降级为 `::warning::`，不让整轮 Release 判红。
4. **各端 job 与收敛 job 的故障互不掩盖。** 任一上传 / 指向失败仍然让整轮红（fail-closed 不变）；
   上传失败时收敛 job 不跑（跳过），不会用一次「成功的清理」把失败盖过去。

## 背景

2026-11-06 出 `v0.11.1-test.1` 时，run 42210867452 的 job「上传 Android + 更新 manifest」红在步骤
「Point test-channel at the Android manifest (#852)」，日志末行是 `no assets match the file pattern`。
清单其实已经写对了，红在之后的清理段。

根因：`tools/release/point-test-channel.sh` 的第 4、5 步各自先枚举共享 `test-channel` 的资产、再删除；
同一轮里「上传 Android」「上传 macOS」「上传 Windows」「组装桌面更新 manifest」等写入 job 并行调用它，
互相删到对方刚枚举出来的东西，`gh` 报 `no assets match the file pattern`，脚本 `set -e` 直接退出。
整轮于是被判「包没发出来」，白重跑一遍；而实际上四端清单都已指向 `v0.11.1-test.1`，客户端可以下载。

这不是「删除要幂等」的问题，而是**职责放错了地方**：一个每个端都调用的脚本，却在做需要全局视野的清理。
并发只是把错误暴露出来的方式；即使串行，每个端 job 在写入过程中清理也会误删：
它看不到别的端即将上传、尚未写清单的安装包。

## 决定

### 1. 拆职责：`point-test-channel.sh` 只上传、指向、不回拨

`tools/release/point-test-channel.sh` 保留：

1. 重跑旧 tag 时不许把指针往回拨（同名清单已是更新版本 ⇒ 什么都不做）；
2. 先传安装包，再核对清单里每个下载链接都已在 `test-channel`；
3. 覆盖本端清单。

删除原第 4、5 步。脚本里不再出现 `release delete-asset` / `release delete`，也没有任何全局清理。
它仍然可以并行地被各端 job 调用：各写各的，互不删除。

### 2. 新增单点收敛入口 `tools/release/cleanup-test-channel.sh`

把原第 4、5 步原样搬进新脚本，语义不变：

- 被任一清单指向的版本才保留安装包（按「被引用的版本」判，dmg 这类不进清单但与当前版本配套的包留得住；
  不带版本号的文件不动）；
- `manifest-ios.json` 只把版本里写进 `KEEP_DRAFTS`（iOS 包在 TestFlight），不保留该版本的 Android /
  macOS / Windows 安装包；
- 删掉比被指向的最新版本还旧、且没被指向的 test 草稿（连同 tag）；比最新被指向版本新的不动；
- 非 test tag 直接退出 0（没有 test-channel 要收敛）；
- `test-channel` 不存在时退出 0（没有可收敛的东西）；
- 读不到任何清单时不删任何东西（拿不准就保留）：避免一次瞬时的清单缺失把整条通道清空；
- 重复运行结果相同（每次重新枚举当前资产与清单，已删的东西不会再被算进去），失败后重跑可继续收敛。

选**新脚本**而不是同脚本 `--cleanup-only`：两者职责、调用点、失败语义都不同。新脚本可以被单独执行、
单独测试、单独在 workflow 里标成「失败只告警」；`point-test-channel.sh` 的失败必须红。用一个入口加开关
会让「哪条路径会删东西」变得难看清，也让测试很难证明「写路径不清理」。

### 3. `release.yml` 新增唯一的收敛 job

新增 job `cleanup-test-channel`：

- `name: "收敛 test-channel（清理旧包与旧草稿）"`——写死的中文名，和其它 job 一致；不加 `matrix` 变量。
- `needs: [create-draft, upload-android, finalize-manifest, finalize-manifest-windows, finalize-ios]`。
  这四张 job 是**全部**会写 `test-channel` 的地方：
  `upload-android`（Android，两份清单）、`finalize-manifest`（macOS + 收口 Android 清单）、
  `finalize-manifest-windows`（Windows）、`finalize-ios`（iOS 基线清单）。
  `upload-macos` 只往 tag 自己的 release 传包，不写 `test-channel`，不需要等。
- `if:` 只在没有任何写入失败、且草稿已建成时执行：
  `!cancelled() && needs.create-draft.result == 'success' && <四个 writer> != 'failure'`。
  用逐项 `!= 'failure'` 而不是 `!failure()`：被 `plan-builds` 判 skip 的端（#852）是正常的，
  不能因此让收敛整段不跑；任一 writer 真失败时收敛跳过，整轮仍因那个 job 红。
- `timeout-minutes: 10`（与其它上传 / 收口 job 同档，`tools/test-release-timeouts.sh` 会检查）。
- `permissions: contents: write`；`env.TAG` 取 `needs.create-draft.outputs.tag`。
- job 级 `continue-on-error: true` 兜住 checkout / runner 等基础设施失败；脚本失败本身由步骤捕获，
  打 `::warning::` 后以 0 退出。两层都指向同一条语义：**收敛段不判红**。

### 4. 失败语义（写死在 workflow 里）

| 情况 | 结果 |
|---|---|
| 任一上传 / 指向 job 失败 | 该 job 红；收敛 job 跳过；整轮 Release 红 |
| 收敛脚本失败 | 打 `::warning::`，步骤退出 0；整轮 Release 不因它红 |
| 收敛 job 的基础设施失败（checkout / runner） | job 级 `continue-on-error: true`，整轮不因它红 |
| 非 test tag | 收敛 job 可以跑，脚本自己退出 0，不碰任何资产 |
| `test-channel` 不存在 | 脚本退出 0（没有可收敛的东西） |

### 5. 测试带反证

新增 `tools/test-release-channel.sh`，接进 `ci-docs.yml` 的 `release-plan` job：

- 用 stub `gh` 真跑两个脚本：写路径只上传 / 写清单、不删除；上传失败 ⇒ 非 0；清单指向不存在的资产 ⇒ 拒绝写；
  收敛脚本删对东西、留对东西、跑两遍结果相同、非 test tag 直接退出。
- 从 `release.yml` 抽收敛 job 的 run 块，用「一定失败」的假收敛脚本执行：必须退出 0 且出现 `::warning::`。
- 结构断言：全仓只有一个 job 调用收敛脚本；各端 writer job 不许调用它、不许 `continue-on-error`；
  `point-test-channel.sh` 里不许出现删除命令。
- 反证（实测，见实现 PR）：把收敛放回任一端 job ⇒ 红；让收敛失败判红 ⇒ 红；让上传失败不红 ⇒ 红。

### 6. 文档同步

`docs/RELEASING.md`（中英文两段 test 通道说明）与 `docs/runbook/ci-lanes.md` 改成：写路径只上传 / 指向，
收敛由唯一的 job 在最后跑一次，失败只告警；上传 / 指向失败仍然红。

## 理由

第一性原理：**谁拥有全局信息，谁做全局动作。**

- 清理需要知道「所有端此刻被指向的版本」。一个端 job 在并行写入过程中只知道自己这一端，天然没有这个信息；
  让它清理，等于让每个 writer 猜别的 writer 的状态，再用删除去修正猜测。并发只是让这个错误必现。
- 把清理挪到所有写入之后、只由一个地方执行，全局信息就完整了：读全部清单、算 KEEP、一次删除。
  单点串行也让它天然幂等：重跑时重新枚举，结果收敛到同一个状态。
- 失败语义也要按「这件事失败意味着什么」分层：写失败意味着客户端拿不到新包，必须红；清理失败只意味着
  旧包多留一会儿、多占一点盘，不能把「已经能下载」的发布判成失败。

为什么不是「删除幂等」补丁（`gh release delete-asset ... || true`、删前重查、加锁重试）：

- 它只让并发删除不报错，仍然让每个 writer 承担全局清理；`|| true` 还会把真正该暴露的删除失败吞掉。
- 它解决不了「A 刚上传、B 在 A 写清单前清理」的误删——这不是「删已删」的竞态，而是「删还没被引用」的竞态，
  幂等删除补丁覆盖不到。
- 它把失败语义留在 writer 里：清理失败仍会让某个端的 job 红，整轮仍被误判为「包没发出来」。
- 加 `concurrency` 串行也只能让四个 writer 排队，清理仍被重复执行四次，且最后一个 writer 的清理可能删掉
  另一个 writer 正在用的资产；治标不治本。

## 后果

- 四端上传 / 指向 job 不再删除任何东西，可以安全并行；`no assets match the file pattern` 这一类
  「互删」失败从根上消失。
- 收敛晚于所有写入，旧包与旧草稿会多留几十秒；失败时可能多留到下一次 test 发布，占盘是可接受的代价。
- 收敛失败只出现在 job 的 warning 注解与日志里，不会让 Release 结论红；需要看占盘时看该 job。
- 上传 / 指向失败仍然红，且收敛 job 会跳过，不会掩盖失败。
- 正式 tag 上收敛 job 会跑但脚本立即退出，不产生任何 `test-channel` API 调用。

## 备选

- **只给删除加幂等 / 吞错**：不选，理由见上；解决不了误删未引用资产，也改不了失败语义。
- **同脚本 `--cleanup-only`**：不选，职责与失败语义混在一个入口，测试难证明写路径不清理。
- **`concurrency` 串行化四个 writer，清理仍留在每个 writer 里**：不选，仍是四次全局清理、
  仍由 writer 承担全局动作，且最后一个 writer 可能删掉别人刚上传的东西。
- **把所有上传合并进一个 job，再在里面清理**：不选，失去按端并行与故障隔离（Android 不用等 Windows），
  也把「写」与「清理」的失败语义绑在一起。
