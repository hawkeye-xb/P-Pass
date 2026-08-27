# DESK-02 桌面走查修复三项　级别 L1（2026-08-12 用户真机走查）

## ① 更新通道选项删除——环境由构建推导

用户裁决：通道选择 UI 不要（丑且多余）。构建期 PPF_BUILD_VERSION 已
注入完整 tag：**版本含 `-test.` → test 通道，否则 stable**，零 UI。
页脚版本号显示完整版本串 **并加显式环境徽标**：prerelease 构建 = `0.3.2-test.1 · 测试版`（琥珀小徽标），正式构建只显示版本号——环境必须在 UI 上一眼可辨（用户明令），不是靠用户读懂 -test 后缀。
Android 端同规则同步处理（设置页通道行一并删除，推导逻辑单测）。
stable URL 红线不变。

## ② 家人与设备：已移除设备不再展示

被移除/吊销的设备还挂在列表里。审计流已有 device.revoked/unpaired
记录（历史可查），列表只展示在用设备。修在 daemon 侧：devices.list
默认过滤 revoked（加 include_revoked 参数默认 false，语义单测），
桌面零改动或只删兜底。

## ③ 二维码弹窗不让路 → 移交 IPC-02

用户裁决：不要轮询打补丁——授权请求到达时应当**事件驱动**地关 QR。
本项移交 IPC-02（事件订阅通道），本卡不做临时快轮询。

## 可执行验收

1. ①：test 构建页脚显示 `x.y.z-test.N` 且自动走 test 通道；正式构建走
   stable（推导函数单测两分支）；通道 UI 在两端 grep 无残留。
2. ②：集成测试——吊销一台后 devices.list 默认不含它，include_revoked
   =true 时含（反证：过滤去掉 → 测试必红）。
4. 全量测试绿 + vite build 绿。

## 收尾
CI 绿；PROGRESS/NEXT 一行；卡移 done/。

---

## ✅ 验收记录（2026-08-10 巡检轮 + 2026-08-11 agent 收尾）

- 实现：`2c4feba`（8/10 20:46 推 main）。①通道零 UI 由版本推导 +
  环境徽标（prerelease 琥珀「测试版」徽标，页脚完整版本串）；②
  devices.list 默认过滤 revoked + include_revoked 参数 + 语义单测；
  ③正确移交 IPC-02 未越权（本卡不做临时轮询）。
- 巡检轮抽检（f12cfd8）：✅ **内容 PASS**。nit：徽标文案写死组件
  未走 i18n，归 T-042 收编债（记录在案，不阻塞本卡）。
- ⚠️ 纪律记录：直推前没跑 fmt → main 红 Format check（8/7 同款），
  验收人 `5ec6ea6` 一键修复（纯格式零逻辑）。push 前
  `cargo fmt --check` 已写入 CLAUDE.md（这是第二次）。
- 测试：巡检轮本地复验 Rust 233/233 + Android 126/126 + arch-check ✅。
