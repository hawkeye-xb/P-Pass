# Windows Desktop 任务规划与独立验证门禁（2026-08-26）

> Base：`main@24b02ed5f3b18db6103a8a301982fe93d2abf500`（开工前必须重新 fetch；验证前再确认 HEAD）。  
> 执行边界：Kimi 在远端 Linux 沙箱/GitHub 侧做代码、脚本、文档、CI 触发与判据；Windows 真机 L3 验证由本机执行并回贴原始输出。  
> 明确跳过：SmartScreen / 杀软信誉建设暂不纳入验收，只记录状态，不作为通过条件。  
> 纪律：不基于旧 `bin-*` 分支；不把 CI 绿当真机绿；不把计划写成已完成事实；平台 `cfg` 仍只许进 `crates/platform/`；桌面壳保持零业务逻辑。

## 一、目标与非目标

**目标**：Windows 桌面端达到“内部可装、可配对、可备份、可浏览、可诊断”的状态。  
**非目标**：不重写配对/备份/索引/传输核心；不改 macOS LaunchAgent 语义；不做发布级签名与 SmartScreen 信誉建设；不在桌面壳堆业务逻辑。

## 二、三类环境分工

| 环境 | 作用 | 能证明 | 不能证明 |
|---|---|---|---|
| 远端 Linux 沙箱 | 写代码、跑通用测试、生成脚本/文档、看 diff | 代码风格、跨平台纯逻辑、部分 Rust 测试、文档一致性 | Windows 安装、自启、托盘、命名管道真机行为 |
| GitHub Actions `windows-latest` | 构建 Windows 产物、跑 CI/Release Windows job | 能否出 `daemon.exe/testclient.exe/NSIS`、构建是否可复现 | 真实用户机器安装体验、权限、杀软、硬件差异 |
| Windows 本机 | L3 验收 | 真安装、真自启、真配对、真备份、真断网恢复、真吊销 | 由远端代跑；必须本机执行并回贴原始输出 |

## 三、工作分解与优先级

### W0｜基线冻结与环境对比（最先做）
**产品结论要回答**：这台 Win 本缺什么，能不能稳定构建出 Windows 包。

交付：
- `tools/windows/env-check.ps1`：ASCII 输出，避开 PS 5.1 中文编码坑；检查 OS/PS、执行策略、Git、Rust、Node 22、pnpm 11、Tauri CLI、vcpkg/libheif、WebView2、长路径、TEMP 可写、磁盘空间。
- `docs/windows-dev-baseline.md`：GitHub Actions `windows-latest` 基线 vs 本地 Win 本差异表；标出“阻塞构建”与“只影响发布体验”的缺口。
- CI 操作说明：`release.yml` 用 `workflow_dispatch platforms=windows` 单独出 Windows 产物。

Gate G0（通过才进 W1）：
- Win 本跑 `env-check.ps1`，回贴完整输出。
- CI `platforms=windows` 出包成功，或明确失败原因。
- 产物哈希与构建信息一致；不接受“应该能装”。

### W1｜最小可用 Windows 桌面闭环（高优先）
**产品结论要回答**：用户在 Windows 上能装 P-Pass，走完向导，手机扫码，把照片视频备份进来，并在桌面看到。

范围：NSIS 安装/卸载/覆盖安装；首次向导；Android 扫码配对与 owner 确认；备份 20/50 个混合文件；桌面浏览缩略图与播视频；外部删除对账；断网 30s 恢复；吊销后拒连。

Gate G1：
- 按 `docs/windows-desktop-smoke.md` 逐步跑，回贴每步原始输出/截图清单。
- 吊销后仍放行 = 不通过（安全语义 hard-fail）。
- 任一步失败即停在 W1，不进 W2。

### W2｜Windows 常驻、日志与诊断导出（需先拍板服务模型）
**产品结论要回答**：后台服务不能“看着在跑，其实死了没人知道”；出问题能导出真正有用的日志。

必须先决策：
- A. 继续注册表 Run key：简单、免管理员；崩溃不自动复活，stdout/stderr 无天然落点。
- B. Run key + 轻量 watchdog：更接近 macOS KeepAlive；要处理重复拉起、升级互斥、误杀。
- C. 计划任务/Windows 服务：更正式；权限、安装卸载、企业策略敏感度更高。

交付：决策记录；Windows 日志落点方案；`daemon_logs` 平台化最小改造（macOS 仍读 LaunchAgent plist；Windows 按选定模型读对应来源；不为未选模型预埋大抽象）。

Gate G2：
- 杀进程后按选定模型观察复活行为；回贴 PID、`status.version`、日志路径。
- daemon 正常与挂掉两种状态都能导出诊断包；包里不出现用户名、不出现全长 NodeId。

### W3｜更新闭环（W1/W2 稳定后再做）
**产品结论要回答**：不是只装一次，而是能从旧版升到新版，且后台服务也跟着换。

前置：W1 安装主路径稳定；W2 常驻/日志可控。  
范围：Windows updater artifact 与 `manifest.json` 平台条目；壳更新后旧 daemon 替换；失败明示，不许假成功。

Gate G3：旧版 → 新版后，壳版本变、daemon `status.version` 变、库不损坏；破坏 sidecar/安装路径时必须报错。

### W4｜回归与收口
**产品结论要回答**：Windows 没把 macOS/Android 带坏，文档和事实一致。

Gate G4：产品一页纸写清 Windows 现在能做什么、不能做什么、下一步唯一阻塞是什么。

## 四、关键节点汇报模板

每个大任务结束只报五条：

1. **结论**：能 / 不能 / 有条件能。
2. **用户可见结果**：装上会怎样，失败会怎样。
3. **证据**：CI run、本机命令输出、哈希、截图/日志文件名。
4. **风险与边界**：没验证什么，不能宣称什么。
5. **下一步唯一动作**：需要拍板 / 需要跑哪条命令 / 继续改哪张卡。

## 五、开工顺序

串行执行，不并行铺摊子：

`W0 → Win 本跑 env-check → 修环境缺口 → CI windows 出包 → W1 安装闭环 → W2 服务模型拍板后实施 → W3 更新 → W4 收口`

下一动作：先做 W0，基于 `main@24b02ed5` 开 `feat/win-desk-01-baseline`；Win 本随后跑 `env-check.ps1` 并回贴原始输出。
