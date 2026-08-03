# NEXT — 卡 4（REL-test3）验收结果与下一步（2026-08-03 21:04 定时验收）

> 本文件是交接件：验收人（Claude，主会话）按 AGENT_PROTOCOL §C.3 抽检后留档。
> 执行完下面的事项后本文件可删或归档进 PROGRESS。

## 一、卡 4 验收结果：✅ PASS（一项 pending 见下）

Release run `v0.2.0-test.3`（run 30810656495）：

| 验收项 | 结果 | 证据 |
|---|---|---|
| ① 三个 job 全绿 | ✅ | Windows x64 / macOS arm64 / Release 草稿 全部 success；关键 step（Build、Pack self-contained zip、Create draft、Upload release assets）全部 success |
| ② draft 6 资产 | ✅（构造性证明） | Upload release assets step 成功=6 个指定文件全部上传（任一 basename 冲突该 step 会 422 失败——T-071b 修复点，test.2 就是这么炸的）。draft 对匿名 API 不可见，资产清单的直接截图待有权限者补（1 分钟，见三-2） |
| ③ zip 自包含实测 | ⏳ pending | 需登录态下载 draft 里的 ppass-macos-arm64.zip → 解压确认 `P-Pass/lib/` 存在且 `./P-Pass/daemon --help` 能起（见三-2） |
| Windows flaky 判定 | ✅ 是 flaky | test.2 一败一成 + test.3 一次通过，同一 workflow 无改动——vcpkg 源码编译偶发，非代码 bug。若未来连续两次同处失败再立卡 |

**结论：T-071b 端到端验收达成，发布流水线可信。H-10c 解锁。**

## 二、下一步卡：H-10c（可直接转发给云端 agent）

```
## H-10c 面向人类的 release 资产  级别 L2
**目标**：release 产出普通人能用的三平台资产——P-Pass.app（+dmg）与 Android APK
  进 release 资产，与现有 daemon 层资产并存。
**范围**：.github/workflows/release.yml（新增 job 或扩展现有 job）、
  必要的打包脚本（tools/ 下新增可以）；apps/desktop、apps/android 的构建配置
  只许为打包所需的最小改动。
**不准动**：现有 6 个资产的产出路径与命名（向后兼容）；tools/bundle-macos.sh
  的现有行为（复用它，不重写）。
**前置事实**：
  - desktop 是独立 workspace（apps/desktop），tauri v2 + Svelte5；macOS 打包
    需要 bundle-macos.sh 产的自包含 daemon 作为 sidecar（binaries/ppf-daemon-<triple>）
  - Android：`./gradlew :app:assembleRelease`；无签名配置时产物是
    app-release-unsigned.apk——先发未签名版（狗粮机安装允许"未知来源"），
    正式签名归 T-071 后续
  - ad-hoc/无证书路径必须能走通（签名门控沿用 release.yml 现有模式）
**可执行验收**：
  - 打 tag v0.2.0-test.4 → Release run 全绿
  - draft 资产在原 6 个之外新增：P-Pass-macos-arm64.dmg（或 .app.zip）、
    ppass-android.apk（命名可调但必须与 notes 一致）
  - 下载实测各一：dmg 挂载/解压出 P-Pass.app；apk 用 `unzip -l` 确认
    AndroidManifest.xml 存在（真机安装归 H-10b）
  - 反证：故意把 sidecar 文件名改错重跑打包 step → 必须红（贴输出后还原）
**证据要求**：run 链接 + 资产清单 + 下载实测输出。CI 绿不是唯一证据。
**跨卡声明禁令**：不许声称 H-10a/H-10b 状态。
**收尾**：just 全绿 + ROADMAP + PROGRESS 各一行。走 PR 等 review。
```

派发顺序：H-10c 合并出 test.4 全绿后 → 重派 H-10a（quickstart 对着真实资产改写）→
H-10b（用户本人当无脑用户实测）→ 全家狗粮周（M2 gate）。

## 三、到家后的操作顺序（用户本人，三件事）

1. **转发上面的 H-10c 卡**给云端 agent（原文粘贴即可）。
2. **一分钟补证**（需要你的 GitHub 登录态）：打开 v0.2.0-test.3 的 draft release
   页面截图资产清单（应恰好 6 个）；顺手下载 ppass-macos-arm64.zip 解压跑
   `./P-Pass/daemon --help` 确认自包含（把结果丢给主会话，卡 4 的 pending 即闭）。
3. **点一次 Actions → "Linux Artifacts" → Run workflow**（workflow_dispatch）：
   bin-win-x64 分支的 win-smoke.ps1 还是旧软判据版（该分支设计上只走手动触发，
   不随 push 自动更新）——点一次即同步 H-09b 修复版，防止下次 Windows 复验的人
   拿到旧脚本假绿。

## 四、场上其余状态（无需行动，仅同步）

- main = ea3bbf4 起点，9/10 评审卡合入，193/193 测试绿；H-09 整卡收官（真机 1 绿 2 红反证）。
- 押后：H-10a（等 H-10c 产物）；挂账：T-070b disk_full CI 反证（并入下张云端小卡）、
  H-07 relay 正式试点（T-063b 已铺路）、Apple 签名证书导出（H-02，要用户钥匙串授权）。
